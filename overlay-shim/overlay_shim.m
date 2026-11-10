// Shim for the Steam overlay. This was deeply unpleasant to make,
// fixes HDR stuff and Metal 4.
//
// Metal 4 notes: D3DMetal 4 commits a frame on MTL4CommandQueue and the
// drawable goes to [drawable present], but Valve's overlay swizzles only the
// Metal 3 present family. Bridge signalDrawable: to a Metal 3 presentDrawable:
// on a shared event so the overlay's own hooks see the frame, fixing the
// issue...

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <objc/message.h>
#import <os/lock.h>
#import <objc/runtime.h>
#import <sys/mman.h>
#import <stdarg.h>
#import <stdatomic.h>
#import <stdio.h>
#include <stdlib.h>
#include <string.h>
#import <unistd.h>

__attribute__((format(printf, 1, 2)))
static void shim_log(const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fflush(stderr);
}

// MTLPixelFormat values the overlay handles, plus the one it doesn't
enum {
	format_bgra8_unorm = 80,
	format_bgra8_unorm_srgb = 81,
	format_rgb10a2_unorm = 90,
	format_bgr10a2_unorm = 94,
	format_rgba16_float = 115,
};

#define max_variants 4

struct variant {
	NSUInteger format;
	id state;
	int logged;
};

struct pipeline_entry {
	MTLRenderPipelineDescriptor *descriptor;
	id<MTLDevice> device;
	NSUInteger base_format;
	struct variant variants[max_variants];
	int variant_count;
	int unmarked_logged;
};

static const char pipeline_cache_key;
static const char command_pipelines_key;

// the cache dies with original pipeline
@interface NPOverlayPipelineCache : NSObject {
@public
	struct pipeline_entry entry;
}
@end

@implementation NPOverlayPipelineCache
- (void)dealloc
{
	for (int i = 0; i < entry.variant_count; i++)
		[entry.variants[i].state release];
	[entry.descriptor release];
	[entry.device release];
	[super dealloc];
}
@end

#define max_encoders 32

struct encoder_slot {
	id encoder;
	id<MTLCommandBuffer> buffer;
	NSUInteger format;
};

static struct encoder_slot overlay_encoders[max_encoders];

static os_unfair_lock encoder_lock = OS_UNFAIR_LOCK_INIT;
static int encoder_table_full_logged;

static const char *format_name(NSUInteger format)
{
	switch (format) {
	case 70:
		return "RGBA8Unorm";
	case 71:
		return "RGBA8Unorm_sRGB";
	case format_bgra8_unorm:
		return "BGRA8Unorm";
	case format_bgra8_unorm_srgb:
		return "BGRA8Unorm_sRGB";
	case format_rgb10a2_unorm:
		return "RGB10A2Unorm";
	case format_bgr10a2_unorm:
		return "BGR10A2Unorm";
	case format_rgba16_float:
		return "RGBA16Float";
	default:
		return "other";
	}
}

static int overlay_has_pipeline(NSUInteger format)
{
	return format == format_bgra8_unorm || format == format_bgra8_unorm_srgb ||
	       format == format_bgr10a2_unorm || format == format_rgba16_float;
}

static const void *overlay_text_begin;
static const void *overlay_text_end;
static const struct mach_header *overlay_header;

static _Atomic int cursor_rebinding;
static void rebind_cursor(const struct mach_header *header, intptr_t slide);

static void image_added(const struct mach_header *header, intptr_t slide)
{
	if (atomic_load(&cursor_rebinding))
		rebind_cursor(header, slide);

	if (overlay_text_end != NULL)
		return;

	Dl_info info;
	if (dladdr(header, &info) == 0 || info.dli_fname == NULL)
		return;

	const char *slash = strrchr(info.dli_fname, '/');
	if (strcmp(slash != NULL ? slash + 1 : info.dli_fname, "gameoverlayrenderer.dylib") != 0)
		return;

	unsigned long size = 0;
	uint8_t *text = getsegmentdata((const struct mach_header_64 *)header, "__TEXT", &size);
	if (text == NULL || size == 0)
		return;

	overlay_header = header;
	overlay_text_begin = text;
	overlay_text_end = text + size;
	shim_log("overlay_shim image_added: overlay text %p-%p\n", overlay_text_begin,
	        overlay_text_end);
}

static int from_overlay(const void *address)
{
	return overlay_text_end != NULL && address >= overlay_text_begin &&
	       address < overlay_text_end;
}

typedef void (*set_pixel_format_fn)(id, SEL, NSUInteger);
typedef void (*set_colorspace_fn)(id, SEL, CGColorSpaceRef);
typedef void (*set_device_fn)(id, SEL, id);
typedef id (*new_pipeline_fn)(id, SEL, MTLRenderPipelineDescriptor *, NSError **);
typedef id (*new_queue_fn)(id, SEL);
typedef id (*new_queue_count_fn)(id, SEL, NSUInteger);
typedef id (*command_buffer_fn)(id, SEL);
typedef id (*render_encoder_fn)(id, SEL, MTLRenderPassDescriptor *);
typedef void (*set_pipeline_state_fn)(id, SEL, id);
typedef void (*end_encoding_fn)(id, SEL);
typedef id (*new_mtl4_queue_fn)(id, SEL);
typedef void (*signal_drawable_fn)(id, SEL, id);
typedef void (*drawable_present_fn)(id, SEL);
typedef void (*drawable_present_after_fn)(id, SEL, CFTimeInterval);

static set_pixel_format_fn next_set_pixel_format;
static set_colorspace_fn next_set_colorspace;
static set_device_fn next_set_device;
static void (*next_set_display_sync)(id, SEL, BOOL);
// NOTPROTON_VSYNC=1 (gamefix VSYNC): the layer always waits for the display, whatever the
// game asks D3DMetal for. The driver-level vsync of Windows, for games that lock their own
// vsync off while frame generation is on and tear past the refresh rate.
static int force_vsync;
static new_pipeline_fn next_new_pipeline;
static new_queue_fn next_new_queue;
static new_queue_count_fn next_new_queue_count;
static command_buffer_fn next_command_buffer;
static command_buffer_fn next_command_buffer_unretained;
static render_encoder_fn next_render_encoder;
static set_pipeline_state_fn next_set_pipeline_state;
static end_encoding_fn next_end_encoding;
static new_mtl4_queue_fn next_new_mtl4_queue;
static signal_drawable_fn next_signal_drawable;
static drawable_present_fn next_drawable_present;
static drawable_present_after_fn next_drawable_present_after;

// The Metal 3 queue and event used to order an overlay after a Metal 4
// frame.
static id<MTLCommandQueue> sync_queue;
static id<MTLEvent> frame_ready;
static uint64_t frame_ready_value;

// The drawable D3DMetal signalled, hooks see it
// Held without a reference because D3DMetal signals and then
// presents the same drawable in one call, on one thread.
static id signalled_drawable;
static uint64_t signalled_value;
static int mtl4_sync_logged;

static void queue_signal_event(id queue, id event, uint64_t value)
{
	typedef void (*signal_event_fn)(id, SEL, id, uint64_t);

	((signal_event_fn)objc_msgSend)(queue, sel_registerName("signalEvent:value:"), event, value);
}

static id object_device(id object)
{
	typedef id (*device_fn)(id, SEL);

	return ((device_fn)objc_msgSend)(object, sel_registerName("device"));
}

static int interpose(Class target, const char *selector_name, IMP replacement, IMP *previous)
{
	if (target == Nil)
		return 0;

	Method method = class_getInstanceMethod(target, sel_registerName(selector_name));
	if (method == NULL)
		return 0;

	*previous = method_getImplementation(method);
	method_setImplementation(method, replacement);
	return 1;
}

// The overlay swizzles by renaming the original to steamoverlay_<selector>, so the
// renamed method is what says its hook survived. Scans the method lists rather
// than asking class_getInstanceMethod: a lookup that misses runs the class's
// +resolveInstanceMethod:, and on CALayer that leaves AppKit's CALayer categories
// (NS_setView: and friends) unattached if AppKit loads afterwards, which crashes
// the first layer-backed NSView. Seen with the harness; a game that loads AppKit
// after the shim installs would hit the same.
static int class_has_method(Class target, const char *selector_name)
{
	SEL selector = sel_registerName(selector_name);

	for (Class c = target; c != Nil; c = class_getSuperclass(c)) {
		unsigned count = 0;
		Method *methods = class_copyMethodList(c, &count);
		int found = 0;
		for (unsigned i = 0; i < count && !found; i++)
			found = method_getName(methods[i]) == selector;
		free(methods);
		if (found)
			return 1;
	}
	return 0;
}

static Class device_class;
static Class queue_class;
static Class command_buffer_class;
static Class encoder_class;
static Class drawable_class;
static Class mtl4_queue_class;

static int stage_claimed(Class seen, Class *held, const char *stage)
{
	if (*held == seen)
		return 0;

	if (*held != Nil) {
		shim_log("overlay_shim stage_claimed: second %s class %s, first was %s\n",
		        stage, class_getName(seen), class_getName(*held));
		return 0;
	}

	*held = seen;
	return 1;
}

// Frame generation (NOTPROTON_FRAMEGEN=1), one translation unit with the shim
#include "framegen.m"
#include "quitkey.m"
#include "perfhud.m"
#include "framelimit.m"
#include "scalefilter.m"
#include "cursor.m"
#include "sidebar.m"

static void encoder_mark(id encoder, NSUInteger format, id<MTLCommandBuffer> buffer)
{
	os_unfair_lock_lock(&encoder_lock);
	for (int i = 0; i < max_encoders; i++) {
		if (overlay_encoders[i].encoder != encoder && overlay_encoders[i].encoder != nil)
			continue;

		overlay_encoders[i].encoder = encoder;
		overlay_encoders[i].buffer = buffer;
		overlay_encoders[i].format = format;
		os_unfair_lock_unlock(&encoder_lock);
		return;
	}
	os_unfair_lock_unlock(&encoder_lock);

	if (!encoder_table_full_logged) {
		encoder_table_full_logged = 1;
		shim_log("overlay_shim encoder_mark: table full, a pass is uncorrected\n");
	}
}

static void encoder_clear(id encoder)
{
	os_unfair_lock_lock(&encoder_lock);
	for (int i = 0; i < max_encoders; i++) {
		if (overlay_encoders[i].encoder == encoder) {
			overlay_encoders[i].encoder = nil;
			overlay_encoders[i].buffer = nil;
			break;
		}
	}
	os_unfair_lock_unlock(&encoder_lock);
}

static int encoder_format(id encoder, NSUInteger *format, id<MTLCommandBuffer> *buffer)
{
	int found = 0;

	os_unfair_lock_lock(&encoder_lock);
	for (int i = 0; i < max_encoders; i++) {
		if (overlay_encoders[i].encoder == encoder) {
			*format = overlay_encoders[i].format;
			*buffer = overlay_encoders[i].buffer;
			found = 1;
			break;
		}
	}
	os_unfair_lock_unlock(&encoder_lock);
	return found;
}

static struct variant *variant_for(struct pipeline_entry *entry, NSUInteger format)
{
	for (int i = 0; i < entry->variant_count; i++) {
		if (entry->variants[i].format == format)
			return &entry->variants[i];
	}

	if (entry->variant_count == max_variants)
		return NULL;

	// The descriptor is a private copy, but the copy depth of a color
	// attachment array is unspecified, so the base format is retained
	entry->descriptor.colorAttachments[0].pixelFormat = (MTLPixelFormat)format;
	NSError *error = nil;
	id state = [entry->device newRenderPipelineStateWithDescriptor:entry->descriptor
	                                                         error:&error];
	entry->descriptor.colorAttachments[0].pixelFormat = (MTLPixelFormat)entry->base_format;

	if (state == nil) {
		shim_log("overlay_shim variant_for: format %lu (%s) failed: %s\n",
		        (unsigned long)format, format_name(format),
		        error != nil ? [[error localizedDescription] UTF8String] : "no reason given");
		return NULL;
	}

	struct variant *slot = &entry->variants[entry->variant_count];
	slot->format = format;
	slot->state = state;
	slot->logged = 0;
	entry->variant_count++;

	shim_log("overlay_shim variant_for: built %s pipeline for base %s\n",
	        format_name(format), format_name(entry->base_format));
	return slot;
}

static void record_overlay_pipeline(id<MTLDevice> device, MTLRenderPipelineDescriptor *descriptor,
                                    id state)
{
	if (objc_getAssociatedObject(state, &pipeline_cache_key) != nil)
		return;

	NPOverlayPipelineCache *cache = [[NPOverlayPipelineCache alloc] init];
	struct pipeline_entry *entry = &cache->entry;
	entry->descriptor = [descriptor copy];
	entry->device = [device retain];
	entry->base_format = descriptor.colorAttachments[0].pixelFormat;
	entry->variant_count = 0;
	entry->unmarked_logged = 0;

	shim_log("overlay_shim record_overlay_pipeline: overlay pipeline %p format %s\n",
	        (void *)state, format_name(entry->base_format));
	objc_setAssociatedObject(state, &pipeline_cache_key, cache, OBJC_ASSOCIATION_RETAIN);
	[cache release];
}

// Metal won't retain these for an unretained command buffer.
static void hold_pipeline(id<MTLCommandBuffer> buffer, id state)
{
	if (buffer == nil || buffer.retainedReferences)
		return;

	@synchronized(buffer) {
		NSMutableSet *states = objc_getAssociatedObject(buffer, &command_pipelines_key);
		if (states == nil) {
			states = [[NSMutableSet alloc] init];
			objc_setAssociatedObject(buffer, &command_pipelines_key, states, OBJC_ASSOCIATION_RETAIN);
			[buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
				(void)completed;
				@synchronized(states) {
					[states removeAllObjects];
				}
			}];
			[states release];
		}
		@synchronized(states) {
			[states addObject:state];
		}
	}
}

static void ensure_encoder_hooks(id encoder);
static void ensure_command_buffer_hooks(id buffer);
static void ensure_queue_hooks(id queue);
static void ensure_device_hooks(id device);
static void ensure_drawable_hooks(id drawable);
static void ensure_mtl4_queue_hooks(id queue);

static void hook_set_pixel_format(id layer, SEL selector, NSUInteger format)
{
	static NSUInteger last = (NSUInteger)-1;

	if (format != last) {
		last = format;
		shim_log(
		        "overlay_shim hook_set_pixel_format: layer=%s format=%lu (%s) overlay_pipeline=%s\n",
		        class_getName(object_getClass(layer)), (unsigned long)format,
		        format_name(format), overlay_has_pipeline(format) ? "present" : "missing");
	}

	next_set_pixel_format(layer, selector, format);
	ensure_device_hooks([(CAMetalLayer *)layer device]);
}

static void hook_set_colorspace(id layer, SEL selector, CGColorSpaceRef colorspace)
{
	static CGColorSpaceRef last = (CGColorSpaceRef)-1;

	if (colorspace != last) {
		last = colorspace;

		char name[128];
		name[0] = '\0';
		if (colorspace != NULL) {
			CFStringRef copied = CGColorSpaceCopyName(colorspace);
			if (copied != NULL) {
				CFStringGetCString(copied, name, sizeof(name), kCFStringEncodingUTF8);
				CFRelease(copied);
			}
		}
		shim_log("overlay_shim hook_set_colorspace: layer=%s colorspace=%s\n",
		        class_getName(object_getClass(layer)), name[0] != '\0' ? name : "none");
	}

	next_set_colorspace(layer, selector, colorspace);
}

static int framelimit_active(void); // framelimit.m
// What the game last asked for; a frame rate limit or VSYNC=1 turns it on over that
static _Atomic int game_display_sync = 1;

static void hook_set_display_sync(id layer, SEL selector, BOOL enabled)
{
	static int last = -1;

	atomic_store(&game_display_sync, enabled ? 1 : 0);
	int effective = enabled || force_vsync || framelimit_active();
	if ((int)enabled != last) {
		last = enabled;
		shim_log("overlay_shim hook_set_display_sync: game asks %d, layer gets %d\n", enabled,
		        effective);
	}
	next_set_display_sync(layer, selector, effective);
}

// After the quick settings change the limit: the game's own choice again, or display sync,
// on the game layer and framegen's covering layer, which shows the frames while it is on.
// Main thread.
static void framelimit_sync_layer(id layer)
{
	if (next_set_display_sync == NULL || layer == nil)
		return;
	SEL selector = sel_registerName("setDisplaySyncEnabled:");
	BOOL sync = atomic_load(&game_display_sync) || force_vsync || framelimit_active();
	next_set_display_sync(layer, selector, sync);
	for (CALayer *sub in ((CALayer *)layer).sublayers)
		if ([sub isKindOfClass:[CAMetalLayer class]])
			next_set_display_sync(sub, selector, sync);
}

static void hook_set_device(id layer, SEL selector, id device)
{
	next_set_device(layer, selector, device);
	ensure_device_hooks(device);
}

static id hook_new_pipeline(id self, SEL selector, MTLRenderPipelineDescriptor *descriptor,
                            NSError **error)
{
	id state = next_new_pipeline(self, selector, descriptor, error);

	if (state != nil && descriptor != nil && from_overlay(__builtin_return_address(0)))
		record_overlay_pipeline(self, descriptor, state);

	return state;
}

static id hook_new_queue(id self, SEL selector)
{
	id queue = next_new_queue(self, selector);
	ensure_queue_hooks(queue);
	return queue;
}

static id hook_new_queue_count(id self, SEL selector, NSUInteger count)
{
	id queue = next_new_queue_count(self, selector, count);
	ensure_queue_hooks(queue);
	return queue;
}

static id hook_command_buffer(id self, SEL selector)
{
	id buffer = next_command_buffer(self, selector);
	ensure_command_buffer_hooks(buffer);
	return buffer;
}

static id hook_command_buffer_unretained(id self, SEL selector)
{
	id buffer = next_command_buffer_unretained(self, selector);
	ensure_command_buffer_hooks(buffer);
	return buffer;
}

static id hook_render_encoder(id self, SEL selector, MTLRenderPassDescriptor *descriptor)
{
	id<MTLTexture> attachment = descriptor != nil ? descriptor.colorAttachments[0].texture : nil;
	id encoder = next_render_encoder(self, selector, descriptor);

	if (encoder == nil)
		return encoder;

	ensure_encoder_hooks(encoder);

	if (attachment == nil)
		return encoder;

	NSUInteger format = attachment.pixelFormat;

	encoder_mark(encoder, format, self);
	framegen_note_render_pass(self, attachment);

	return encoder;
}
static void hook_set_pipeline_state(id self, SEL selector, id state)
{
	NPOverlayPipelineCache *cache = objc_getAssociatedObject(state, &pipeline_cache_key);
	if (cache != nil) {
		@synchronized(cache) {
			struct pipeline_entry *entry = &cache->entry;
			NSUInteger format = 0;
			id<MTLCommandBuffer> buffer = nil;
			if (!encoder_format(self, &format, &buffer)) {
				if (!entry->unmarked_logged) {
					entry->unmarked_logged = 1;
					shim_log(
					        "overlay_shim hook_set_pipeline_state: pipeline %p %s bound on an "
					        "unmarked pass, left alone\n",
					        (void *)state, format_name(entry->base_format));
				}
			} else if (format != entry->base_format) {
				struct variant *slot = variant_for(entry, format);
				if (slot != NULL) {
					if (!slot->logged) {
						slot->logged = 1;
						shim_log(
						        "overlay_shim hook_set_pipeline_state: pipeline %p %s bound to %s "
						        "attachment, substituted\n",
						        (void *)state, format_name(entry->base_format), format_name(format));
					}
					state = slot->state;
					hold_pipeline(buffer, state);
				}
			}
		}
	}

	next_set_pipeline_state(self, selector, state);
}

static void hook_end_encoding(id self, SEL selector)
{
	encoder_clear(self);
	next_end_encoding(self, selector);
}
static void hook_signal_drawable(id self, SEL selector, id drawable)
{
	next_signal_drawable(self, selector, drawable);

	signalled_drawable = nil;

	// Without the overlay the bridge has no reader, unless framegen wants the frame
	if ((overlay_text_end == NULL && !framegen_enabled) || drawable == nil)
		return;

	id device = object_device(self);
	if (device == nil)
		return;

	if (sync_queue == nil) {
		sync_queue = [(id<MTLDevice>)device newCommandQueue];
		frame_ready = [(id<MTLDevice>)device newEvent];

		shim_log("overlay_shim hook_signal_drawable: queue=%s event=%s\n",
		        sync_queue != nil ? "created" : "unavailable",
		        frame_ready != nil ? "created" : "unavailable");
	}

	if (sync_queue == nil || frame_ready == nil || object_device(sync_queue) != device)
		return;

	signalled_value = ++frame_ready_value;
	queue_signal_event(self, frame_ready, signalled_value);
	signalled_drawable = drawable;
	ensure_drawable_hooks(drawable);
}

// presentDrawable: is the selector the overlay swizzles, so this
// is where the dark magic happens.
static int present_composited(id drawable, CFTimeInterval duration, int timed)
{
	if (drawable == nil || drawable != signalled_drawable || sync_queue == nil ||
	    frame_ready == nil)
		return 0;

	signalled_drawable = nil;

	id<MTLCommandBuffer> buffer = [sync_queue commandBuffer];
	if (buffer == nil)
		return 0;

	[buffer encodeWaitForEvent:frame_ready value:signalled_value];

	if (timed)
		[buffer presentDrawable:(id<CAMetalDrawable>)drawable afterMinimumDuration:duration];
	else
		[buffer presentDrawable:(id<CAMetalDrawable>)drawable];

	[buffer commit];

	if (!mtl4_sync_logged) {
		mtl4_sync_logged = 1;
		shim_log("overlay_shim present_composited: Metal 4 frame presented through a "
		        "Metal 3 buffer waiting on the frame event, overlay composites in order\n");
	}

	return 1;
}

static void hook_drawable_present(id self, SEL selector)
{
	if (present_composited(self, 0.0, 0))
		return;
	if (framegen_divert_plain_present(self, 0))
		return;

	next_drawable_present(self, selector);
}

static void hook_drawable_present_after(id self, SEL selector, CFTimeInterval duration)
{
	if (present_composited(self, duration, 1))
		return;
	if (framegen_divert_plain_present(self, duration))
		return;

	next_drawable_present_after(self, selector, duration);
}

static id hook_new_mtl4_queue(id self, SEL selector)
{
	id queue = next_new_mtl4_queue(self, selector);

	ensure_mtl4_queue_hooks(queue);
	return queue;
}

static void ensure_encoder_hooks(id encoder)
{
	if (encoder == nil || !stage_claimed(object_getClass(encoder), &encoder_class, "encoder"))
		return;

	int hooked = interpose(encoder_class, "setRenderPipelineState:", (IMP)hook_set_pipeline_state,
	                       (IMP *)&next_set_pipeline_state);
	hooked += interpose(encoder_class, "endEncoding", (IMP)hook_end_encoding,
	                    (IMP *)&next_end_encoding);

	shim_log("overlay_shim ensure_encoder_hooks: %s hooks=%d\n",
	        class_getName(encoder_class), hooked);
}

static void ensure_command_buffer_hooks(id buffer)
{
	if (buffer == nil ||
	    !stage_claimed(object_getClass(buffer), &command_buffer_class, "command buffer"))
		return;

	int hooked = interpose(command_buffer_class, "renderCommandEncoderWithDescriptor:",
	                       (IMP)hook_render_encoder, (IMP *)&next_render_encoder);

	shim_log("overlay_shim ensure_command_buffer_hooks: %s hooks=%d overlay_commit=%s\n",
	        class_getName(command_buffer_class), hooked,
	        class_has_method(command_buffer_class, "steamoverlay_commit") ? "present" : "missing");

	framegen_install_command_buffer_hooks(command_buffer_class);
}

static void ensure_queue_hooks(id queue)
{
	if (queue == nil || !stage_claimed(object_getClass(queue), &queue_class, "queue"))
		return;

	int hooked = interpose(queue_class, "commandBuffer", (IMP)hook_command_buffer,
	                       (IMP *)&next_command_buffer);
	hooked += interpose(queue_class, "commandBufferWithUnretainedReferences",
	                    (IMP)hook_command_buffer_unretained,
	                    (IMP *)&next_command_buffer_unretained);

	shim_log("overlay_shim ensure_queue_hooks: %s hooks=%d\n", class_getName(queue_class),
	        hooked);
}

static void ensure_drawable_hooks(id drawable)
{
	if (drawable == nil || !stage_claimed(object_getClass(drawable), &drawable_class, "drawable"))
		return;

	int hooked = interpose(drawable_class, "present", (IMP)hook_drawable_present,
	                       (IMP *)&next_drawable_present);
	hooked += interpose(drawable_class, "presentAfterMinimumDuration:",
	                    (IMP)hook_drawable_present_after, (IMP *)&next_drawable_present_after);

	shim_log("overlay_shim ensure_drawable_hooks: %s hooks=%d\n",
	        class_getName(drawable_class), hooked);
}

static void ensure_mtl4_queue_hooks(id queue)
{
	if (queue == nil || !stage_claimed(object_getClass(queue), &mtl4_queue_class, "mtl4 queue"))
		return;

	int hooked = interpose(mtl4_queue_class, "signalDrawable:", (IMP)hook_signal_drawable,
	                       (IMP *)&next_signal_drawable);

	shim_log("overlay_shim ensure_mtl4_queue_hooks: %s hooks=%d\n",
	        class_getName(mtl4_queue_class), hooked);
}

static void ensure_device_hooks(id device)
{
	if (device == nil || !stage_claimed(object_getClass(device), &device_class, "device"))
		return;

	int hooked = interpose(device_class, "newRenderPipelineStateWithDescriptor:error:",
	                       (IMP)hook_new_pipeline, (IMP *)&next_new_pipeline);
	hooked += interpose(device_class, "newCommandQueue", (IMP)hook_new_queue,
	                    (IMP *)&next_new_queue);
	hooked += interpose(device_class, "newCommandQueueWithMaxCommandBufferCount:",
	                    (IMP)hook_new_queue_count, (IMP *)&next_new_queue_count);
	hooked += interpose(device_class, "newMTL4CommandQueue", (IMP)hook_new_mtl4_queue,
	                    (IMP *)&next_new_mtl4_queue);

	shim_log("overlay_shim ensure_device_hooks: %s hooks=%d\n", class_getName(device_class),
	        hooked);
}

// Device hooks have to be in place before D3DMetal builds its command queues,
// which D3DMCommandQueue does at CreateCommandQueue
static id shim_MTLCreateSystemDefaultDevice(void)
{
	id device = MTLCreateSystemDefaultDevice();

	ensure_device_hooks(device);
	return device;
}

static NSArray<id<MTLDevice>> *shim_MTLCopyAllDevices(void)
{
	NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();

	for (id device in devices)
		ensure_device_hooks(device);

	return devices;
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
	const void *replacement;
	const void *original;
} device_interposes[] = {
	{ (const void *)shim_MTLCreateSystemDefaultDevice,
	  (const void *)MTLCreateSystemDefaultDevice },
	{ (const void *)shim_MTLCopyAllDevices, (const void *)MTLCopyAllDevices },
};

struct interpose_pair {
	const void *replacement;
	const void *replacee;
};

// The protection a mapped page has now. dyld leaves __DATA_CONST and the GOT read-only
// once it has bound them.
static int page_protection(void *page, vm_prot_t *protection)
{
	vm_address_t address = (vm_address_t)page;
	vm_size_t size = 0;
	vm_region_basic_info_data_64_t info;
	mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
	mach_port_t object = MACH_PORT_NULL;

	if (vm_region_64(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
	                 (vm_region_info_t)&info, &count, &object) != KERN_SUCCESS)
		return 0;
	if (address > (vm_address_t)page)
		return 0;
	*protection = info.protection;
	return 1;
}

// Images can be added from several threads at once; one thread restoring a page's
// protection must not land between another's mprotect and its store.
static os_unfair_lock store_lock = OS_UNFAIR_LOCK_INIT;

// Writes one pointer slot, then puts the page back to the protection it had, so a
// read-only GOT does not stay writable for the life of the game.
static int store_pointer(const void **slot, const void *value)
{
	long page_size = getpagesize();
	void *page = (void *)((uintptr_t)slot & ~(uintptr_t)(page_size - 1));
	vm_prot_t original;
	int stored = 0;

	os_unfair_lock_lock(&store_lock);
	if (page_protection(page, &original)) {
		int restore = (original & VM_PROT_WRITE) == 0;
		if (!restore || mprotect(page, (size_t)page_size, PROT_READ | PROT_WRITE) == 0) {
			*slot = value;
			stored = 1;
			if (restore)
				mprotect(page, (size_t)page_size,
				         original & (VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE));
		}
	}
	os_unfair_lock_unlock(&store_lock);
	return stored;
}

static int rebind_image(const struct mach_header *header, intptr_t slide,
                        const struct interpose_pair *pairs, unsigned long count)
{
	if (header == NULL || header->magic != MH_MAGIC_64)
		return 0;

	const struct mach_header_64 *header64 = (const struct mach_header_64 *)header;
	const struct load_command *command = (const struct load_command *)(header64 + 1);
	int rebound = 0;

	for (uint32_t i = 0; i < header64->ncmds; i++) {
		if (command->cmd == LC_SEGMENT_64) {
			const struct segment_command_64 *segment =
			        (const struct segment_command_64 *)command;
			const struct section_64 *section = (const struct section_64 *)(segment + 1);

			for (uint32_t j = 0; j < segment->nsects; j++, section++) {
				uint32_t type = section->flags & SECTION_TYPE;

				if (type != S_LAZY_SYMBOL_POINTERS &&
				    type != S_NON_LAZY_SYMBOL_POINTERS)
					continue;

				const void **slots = (const void **)(section->addr + slide);

				for (uint64_t k = 0; k < section->size / sizeof(*slots); k++) {
					for (unsigned long p = 0; p < count; p++) {
						if (slots[k] != pairs[p].replacee)
							continue;
						if (store_pointer(&slots[k], pairs[p].replacement))
							rebound++;
						break;
					}
				}
			}
		}

		command = (const struct load_command *)((const char *)command + command->cmdsize);
	}

	return rebound;
}

static const void *overlay_replacement(const struct interpose_pair *pairs, unsigned long count,
                                       const char *symbol)
{
	const void *target = dlsym(RTLD_DEFAULT, symbol);

	if (target == NULL)
		return NULL;

	for (unsigned long i = 0; i < count; i++)
		if (pairs[i].replacee == target)
			return pairs[i].replacement;

	return NULL;
}

static void announce_through_wrapper(const struct interpose_pair *pairs, unsigned long count)
{
	typedef int32_t (*run_in_mode)(CFStringRef, CFTimeInterval, Boolean);

	const void *replacement = overlay_replacement(pairs, count, "CFRunLoopRunInMode");

	if (replacement == NULL) {
		shim_log("overlay_shim announce_through_wrapper: no runloop entry in table\n");
		return;
	}

	((run_in_mode)replacement)(CFSTR("com.notproton.overlay.announce"), 0.0, true);
	shim_log("overlay_shim announce_through_wrapper: announced\n");
}

typedef int (*cgl_flush_fn)(void *);

static cgl_flush_fn overlay_cgl_flush;
static void (*next_flush_buffer)(id, SEL);

static void hook_flush_buffer(id context, SEL selector)
{
	typedef void *(*cgl_context_fn)(id, SEL);

	void *cgl = ((cgl_context_fn)objc_msgSend)(context, sel_registerName("CGLContextObj"));

	if (overlay_cgl_flush != NULL && cgl != NULL) {
		overlay_cgl_flush(cgl);
		return;
	}

	next_flush_buffer(context, selector);
}

static void adopt_overlay_gl_present(const struct interpose_pair *pairs, unsigned long count)
{
	overlay_cgl_flush = (cgl_flush_fn)overlay_replacement(pairs, count, "CGLFlushDrawable");

	int hooked = 0;
	if (overlay_cgl_flush != NULL)
		hooked = interpose(objc_getClass("NSOpenGLContext"), "flushBuffer",
		                   (IMP)hook_flush_buffer, (IMP *)&next_flush_buffer);

	shim_log("overlay_shim adopt_overlay_gl_present: replacement=%s flushBuffer=%s\n",
	        overlay_cgl_flush != NULL ? "found" : "missing", hooked ? "hooked" : "missed");
}

static void apply_overlay_interposes(void)
{
	if (overlay_header == NULL)
		return;

	unsigned long size = 0;
	const struct interpose_pair *pairs =
	        (const struct interpose_pair *)getsectiondata(
	                (const struct mach_header_64 *)overlay_header, "__DATA", "__interpose",
	                &size);

	if (pairs == NULL || size < sizeof(*pairs)) {
		shim_log("overlay_shim apply_overlay_interposes: overlay has no table\n");
		return;
	}

	unsigned long count = size / sizeof(*pairs);
	uint32_t images = _dyld_image_count();
	int rebound = 0;

	for (uint32_t i = 0; i < images; i++) {
		const struct mach_header *header = _dyld_get_image_header(i);

		if (header == overlay_header)
			continue;

		rebound += rebind_image(header, _dyld_get_image_vmaddr_slide(i), pairs, count);
	}

	shim_log("overlay_shim apply_overlay_interposes: %lu entries, %d pointers\n", count,
	        rebound);

	announce_through_wrapper(pairs, count);
	adopt_overlay_gl_present(pairs, count);
}

static id stub_init(id self, SEL selector)
{
	(void)selector;
	return self;
}

static void kick_renderer_metal_hooks(void)
{
	Class app_class = objc_getClass("NSApplication");
	if (app_class == Nil)
		return;

	Method renamed = class_getInstanceMethod(app_class, sel_registerName("steammetalhook_init"));
	if (renamed == NULL) {
		shim_log("overlay_shim kick_renderer_metal_hooks: init is not swizzled\n");
		return;
	}

	id *app_slot = (id *)dlsym(RTLD_DEFAULT, "NSApp");
	id app = app_slot != NULL ? *app_slot : nil;
	if (app == nil) {
		shim_log("overlay_shim kick_renderer_metal_hooks: no application yet\n");
		return;
	}

	IMP original = method_setImplementation(renamed, (IMP)stub_init);
	((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("init"));
	method_setImplementation(renamed, original);

	shim_log("overlay_shim kick_renderer_metal_hooks: drove init on %s\n",
	        class_getName(object_getClass(app)));
}

static int next_drawable_logged;
static id (*next_layer_drawable)(id, SEL);

static id hook_next_drawable(id layer, SEL selector)
{
	framelimit_wait(layer);
	id drawable = next_layer_drawable(layer, selector);

	if (!next_drawable_logged) {
		next_drawable_logged = 1;
		shim_log("overlay_shim hook_next_drawable: layer=%s drawable=%s\n",
		        class_getName(object_getClass(layer)), drawable != nil ? "yes" : "no");
	}

	if (framegen_enabled) {
		// Framegen needs the drawable present hooks on every path, not only Metal 4
		ensure_drawable_hooks(drawable);
		framegen_note_drawable(layer, drawable);
	}
	if (drawable != nil) {
		perfhud_note_frame(layer);
		scalefilter_note(layer);
		sidebar_note_layer(layer);
	}

	return drawable;
}

// Once only: a second interpose would make the hook its own next
static void hook_layer_drawable(Class layer)
{
	static int hooked;

	if (hooked || layer == Nil)
		return;
	hooked = interpose(layer, "nextDrawable", (IMP)hook_next_drawable, (IMP *)&next_layer_drawable);
}

static void report_renderer_chain(void)
{
	Class layer = objc_getClass("CAMetalLayer");

	shim_log("overlay_shim report_renderer_chain: drawable_swizzle=%s\n",
	        class_has_method(layer, "steamoverlay_nextDrawable") ? "present" : "missing");

	hook_layer_drawable(layer);
}

// Loaded by hand, the shim gets none of its interposes from dyld; the cursor's (cursor.m) go in
// by rebinding every other image, now and as images load
static void rebind_cursor(const struct mach_header *header, intptr_t slide)
{
	Dl_info self;
	if (dladdr((const void *)rebind_cursor, &self) == 0 || header == self.dli_fbase)
		return;
	rebind_image(header, slide, (const struct interpose_pair *)cursor_interposes,
	             sizeof(cursor_interposes) / sizeof(cursor_interposes[0]));
}

static void rebind_cursor_everywhere(void)
{
	if (!sidebar_wanted() || atomic_exchange(&cursor_rebinding, 1))
		return;
	uint32_t images = _dyld_image_count();
	for (uint32_t i = 0; i < images; i++)
		rebind_cursor(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
	shim_log("overlay_shim rebind_cursor_everywhere: %u images\n", images);
}

// FEX specific stuff
__attribute__((visibility("default"))) void np_overlay_shim_install(void)
{
	ensure_device_hooks(MTLCreateSystemDefaultDevice());
	rebind_cursor_everywhere();
	apply_overlay_interposes();
	kick_renderer_metal_hooks();
	report_renderer_chain();
}

__attribute__((constructor)) static void overlay_shim_load(void)
{
	quitkey_init();

	Class layer = objc_getClass("CAMetalLayer");
	if (layer == Nil) {
		shim_log("overlay_shim_load: CAMetalLayer absent, nothing to correct\n");
		return;
	}

	_dyld_register_func_for_add_image(image_added);
	framegen_init();

	int hooked = interpose(layer, "setPixelFormat:", (IMP)hook_set_pixel_format,
	                       (IMP *)&next_set_pixel_format);
	hooked += interpose(layer, "setColorspace:", (IMP)hook_set_colorspace,
	                    (IMP *)&next_set_colorspace);
	hooked += interpose(layer, "setDevice:", (IMP)hook_set_device, (IMP *)&next_set_device);
	const char *vsync = getenv("NOTPROTON_VSYNC");
	// A frame rate limit paces to the display, so it waits for the display as VSYNC does
	int limited = framelimit_init();
	int quick = sidebar_init();
	force_vsync = vsync != NULL && strcmp(vsync, "1") == 0;
	// The quick settings can set a limit while the game runs, so the hook is in place then too
	if (force_vsync || limited || quick)
		hooked += interpose(layer, "setDisplaySyncEnabled:", (IMP)hook_set_display_sync,
		                    (IMP *)&next_set_display_sync);
	framegen_install_layer_hooks(layer);
	// The overlay times frames from nextDrawable, which otherwise waits for lsteamclient's
	// np_overlay_shim_install: a native game or one without the Steam API never calls it
	int filtered = scalefilter_init();
	if (perfhud_init() || limited || filtered || quick)
		hook_layer_drawable(layer);

	shim_log("overlay_shim_load: pid=%d exe=%s layer_hooks=%d overlay=%s\n", getpid(),
	        getprogname(), hooked, overlay_text_end != NULL ? "present" : "absent");
}
