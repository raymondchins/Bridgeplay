#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import <crt_externs.h>
#import <dlfcn.h>
#import <spawn.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>

#import "check.h"

// Frame generation: inert without NOTPROTON_FRAMEGEN, and with it the
// interpolated frame puts a moving square where it belongs between its two
// positions, keeps a static HUD pixel-exact, gives up on a jump the search
// cannot follow, and the 3x and adaptive modes make two frames per pair.

typedef void (*probe_fn)(int *, int *, int *, int *, int *, int *);
typedef int (*interpolate_fn)(id, id, id, id, int, double *);
typedef int (*interpolate_opts_fn)(id, id, id, id, int, int, int, int, double, double *, int *);

static interpolate_opts_fn interpolate_opts;
typedef void (*probe_display_fn)(int *, int *, double *, double *, int *);
static probe_display_fn probe_display;
static _Atomic int delayed_drawable;
static id (*next_drawable)(id, SEL);

static id slow_cover_drawable(id layer, SEL selector)
{
	static double released;
	id drawable = next_drawable(layer, selector);
	if (atomic_load(&delayed_drawable) && [(CALayer *)layer superlayer] != nil) {
		double now = CACurrentMediaTime();
		double wait = released + 1.0 / 60 - now;
		if (wait > 0)
			usleep((useconds_t)(wait * 1e6));
		released = wait > 0 ? released + 1.0 / 60 : now;
	}
	return drawable;
}

static void *load_shim(const char *path, probe_fn *probe, interpolate_fn *interpolate)
{
	void *shim = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (shim == NULL)
		return NULL;

	void (*install)(void) = (void (*)(void))dlsym(shim, "np_overlay_shim_install");
	*probe = (probe_fn)dlsym(shim, "np_framegen_probe");
	*interpolate = (interpolate_fn)dlsym(shim, "np_framegen_interpolate_sync");
	interpolate_opts = (interpolate_opts_fn)dlsym(shim, "np_framegen_interpolate_opts");
	if (install != NULL)
		install();
	return shim;
}

// Drives the present path the way a game would, offscreen, one frame every
// spacing_us from the start (not after the previous one, so the rate holds)
static int present_frames(id<MTLDevice> device, CAMetalLayer *layer, int frames, int spacing_us)
{
	static id<MTLCommandQueue> queue;
	double start = CACurrentMediaTime();

	if (queue == nil)
		queue = [device newCommandQueue];

	for (int i = 0; i < frames; i++) {
		@autoreleasepool {
			id<CAMetalDrawable> drawable = [layer nextDrawable];
			if (drawable == nil)
				return 0;
			id<MTLCommandBuffer> buffer = [queue commandBuffer];
			MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
			pass.colorAttachments[0].texture = drawable.texture;
			pass.colorAttachments[0].loadAction = MTLLoadActionClear;
			pass.colorAttachments[0].storeAction = MTLStoreActionStore;
			id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
			[encoder endEncoding];
			[buffer presentDrawable:drawable];
			[buffer commit];
			[buffer waitUntilCompleted];
			double wait = start + (i + 1) * spacing_us * 1e-6 - CACurrentMediaTime();
			if (wait > 0)
				usleep((useconds_t)(wait * 1e6));
		}
	}
	return 1;
}

static CAMetalLayer *game_layer(id<MTLDevice> device)
{
	CAMetalLayer *layer = [CAMetalLayer layer];
	layer.device = device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.drawableSize = CGSizeMake(256, 256);
	return layer;
}

static int inert_without_env(const char *path)
{
	probe_fn probe = NULL;
	interpolate_fn interpolate = NULL;

	CHECK(getenv("NOTPROTON_FRAMEGEN") == NULL, "NOTPROTON_FRAMEGEN is set in the parent");
	CHECK(load_shim(path, &probe, &interpolate) != NULL, "%s does not load: %s", path, dlerror());
	CHECK(probe != NULL, "%s exports no np_framegen_probe", path);
	CHECK(interpolate != NULL, "%s exports no np_framegen_interpolate_sync", path);
	CHECK(interpolate_opts != NULL, "%s exports no np_framegen_interpolate_opts", path);

	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	SKIP_IF(device == nil, "no Metal device on this machine");
	CHECK(present_frames(device, game_layer(device), 3, 20000), "offscreen layer vends no drawable");

	int enabled = -1, hooks = -1, mode = -1, objects = -1, generated = -1, copies = -1;
	probe(&enabled, &hooks, &mode, &objects, &generated, &copies);
	CHECK(enabled == 0, "framegen enabled without NOTPROTON_FRAMEGEN");
	CHECK(hooks == 0, "framegen installed %d hooks while off", hooks);
	CHECK(mode == 0, "framegen mode %d while off", mode);
	CHECK(objects == 0, "framegen created %d objects while off", objects);
	printf("%-14s %s\n", "framegen off", "no hooks, no objects");
	return 0;
}

// ---------------------------------------------------------------------------
// Synthetic frames: an aperiodic multi-scale noise background (so block matching
// has texture at every pyramid level and no false repeats), a white square, and
// optionally a striped red HUD rectangle drawn on top.

static uint32_t hash32(uint32_t x)
{
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}

static unsigned noise_level(int x, int y, int cell)
{
	if (x < 0)
		x -= cell - 1;
	if (y < 0)
		y -= cell - 1;
	return hash32((uint32_t)(x / cell) * 73856093u ^ (uint32_t)(y / cell) * 19349663u ^ (uint32_t)cell) & 0xff;
}

struct scene {
	int square_x, square_y, square_size; // size 0: no square
	int bg_dx; // background shifted right by this many pixels
	int hud_x, hud_y, hud_w, hud_h; // hud_w 0: no HUD
};

static uint32_t hud_pixel(int x, int y)
{
	return ((x / 3 + y / 3) & 1) ? 0xffff3030u : 0xff400000u;
}

static id<MTLTexture> scene_frame(id<MTLDevice> device, NSUInteger width, NSUInteger height,
                                  const struct scene *scene)
{
	MTLTextureDescriptor *descriptor =
	        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                                           width:width
	                                                          height:height
	                                                       mipmapped:NO];
	descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	descriptor.storageMode = MTLStorageModeShared;
	id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];

	uint32_t *pixels = calloc(width * height, 4);
	for (NSUInteger y = 0; y < height; y++) {
		for (NSUInteger x = 0; x < width; x++) {
			int sx = (int)x - scene->bg_dx, sy = (int)y;
			unsigned g = (noise_level(sx, sy, 64) * 5 + noise_level(sx, sy, 16) * 3 +
			              noise_level(sx, sy, 4) * 2) / 10;
			g = g * 0x7f / 0xff; // below the bright threshold
			uint32_t p = 0xff000000u | (g << 16) | (g << 8) | g;
			if ((int)x >= scene->square_x && (int)x < scene->square_x + scene->square_size &&
			    (int)y >= scene->square_y && (int)y < scene->square_y + scene->square_size)
				p = 0xffffffffu;
			if (scene->hud_w > 0 && (int)x >= scene->hud_x && (int)x < scene->hud_x + scene->hud_w &&
			    (int)y >= scene->hud_y && (int)y < scene->hud_y + scene->hud_h)
				p = hud_pixel((int)x, (int)y);
			pixels[y * width + x] = p;
		}
	}
	[texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
	           mipmapLevel:0
	             withBytes:pixels
	           bytesPerRow:width * 4];
	free(pixels);
	return texture;
}

static id<MTLTexture> square_frame(id<MTLDevice> device, NSUInteger width, NSUInteger height, int x0,
                                   int y0, int size)
{
	struct scene scene = { x0, y0, size, 0, 0, 0, 0, 0 };
	return scene_frame(device, width, height, &scene);
}

// Bright pixels in rows y0..y0+rows: how many and where their centre is
static void bright_pixels(id<MTLTexture> texture, int y0, int rows, int *count, double *centre)
{
	NSUInteger width = texture.width;
	uint32_t *pixels = malloc(width * 4 * (size_t)rows);
	[texture getBytes:pixels
	      bytesPerRow:width * 4
	       fromRegion:MTLRegionMake2D(0, y0, width, rows)
	      mipmapLevel:0];
	double sum = 0;
	int n = 0;
	for (int y = 0; y < rows; y++) {
		for (NSUInteger x = 0; x < width; x++) {
			uint32_t p = pixels[y * width + x];
			if (((p >> 16) & 0xff) > 180 && ((p >> 8) & 0xff) > 180 && (p & 0xff) > 180) {
				sum += x;
				n++;
			}
		}
	}
	free(pixels);
	*count = n;
	*centre = n > 0 ? sum / n : -1;
}

// Pixels of a region that differ between two textures
static int differing_pixels(id<MTLTexture> p, id<MTLTexture> q, int x0, int y0, int w, int h)
{
	uint32_t *a = malloc((size_t)w * h * 4), *b = malloc((size_t)w * h * 4);
	MTLRegion region = MTLRegionMake2D(x0, y0, w, h);
	[p getBytes:a bytesPerRow:(NSUInteger)w * 4 fromRegion:region mipmapLevel:0];
	[q getBytes:b bytesPerRow:(NSUInteger)w * 4 fromRegion:region mipmapLevel:0];
	int n = 0;
	for (int i = 0; i < w * h; i++)
		n += a[i] != b[i];
	free(a);
	free(b);
	return n;
}

static const char *const quality_names[] = { "performance", "balanced", "quality" };

// A square moving 80 px must land at t between its two positions
static int square_at(id<MTLDevice> device, int engine, int quality, double t, const char *name)
{
	const NSUInteger width = 1024, height = 768;
	const int size = 120, y0 = 300, xa = 300, xb = 380;

	id<MTLTexture> a = square_frame(device, width, height, xa, y0, size);
	id<MTLTexture> b = square_frame(device, width, height, xb, y0, size);
	id<MTLTexture> out = square_frame(device, width, height, 0, 0, 0);
	double gpu_ms = 0;
	int fell_back = -1;
	int used = interpolate_opts(device, a, b, out, engine, quality, 1, 1, t, &gpu_ms, &fell_back);
	if (used == 0 && engine == 2) {
		printf("%-14s %s\n", name, "skipped: MetalFX frame interpolation unavailable here");
		return 0;
	}
	CHECK(used == engine, "engine %s did not run (got %d)", name, used);
	CHECK(fell_back == 0, "%s: the fast-motion fallback fired on an 80 px move", name);

	int count = 0;
	double centre = -1;
	bright_pixels(out, y0, size, &count, &centre);
	double expected = xa + (xb - xa) * t + size / 2.0;
	printf("%-14s t=%.2f square centre %.1f (expected %.1f), %d bright pixels (square %d), %.2f ms GPU\n",
	       name, t, centre, expected, count, size * size, gpu_ms);
	CHECK(count > size * size * 6 / 10 && count < size * size * 14 / 10,
	      "%s: %d bright pixels, a crossfade or a smear rather than a moved square", name, count);
	CHECK(centre > expected - 12 && centre < expected + 12,
	      "%s: square centre %.1f is not near %.1f", name, centre, expected);
	return 0;
}

// A striped HUD identical in both frames over the moving square: with UI
// protection the HUD comes out pixel-exact and the square still moves
static int hud_protect(id<MTLDevice> device, int engine, const char *name)
{
	const NSUInteger width = 1024, height = 768;
	const int size = 120, y0 = 300, xa = 300, xb = 380;
	struct scene sa = { xa, y0, size, 0, 280, y0, 240, 40 };
	struct scene sb = { xb, y0, size, 0, 280, y0, 240, 40 };

	id<MTLTexture> a = scene_frame(device, width, height, &sa);
	id<MTLTexture> b = scene_frame(device, width, height, &sb);
	id<MTLTexture> out = square_frame(device, width, height, 0, 0, 0);
	int results[2] = { -1, -1 };
	for (int ui = 1; ui >= 0; ui--) {
		int used = interpolate_opts(device, a, b, out, engine, 1, ui, 1, 0.5, NULL, NULL);
		if (used == 0 && engine == 2) {
			printf("%-14s %s\n", name, "skipped: MetalFX frame interpolation unavailable here");
			return 0;
		}
		CHECK(used == engine, "engine %s did not run (got %d)", name, used);
		results[ui] = differing_pixels(out, b, sa.hud_x, sa.hud_y, sa.hud_w, sa.hud_h);
		int count = 0;
		double centre = -1;
		bright_pixels(out, y0 + sa.hud_h, size - sa.hud_h, &count, &centre);
		double expected = (xa + xb) / 2.0 + size / 2.0;
		printf("%-14s ui=%d HUD pixels differing from the real frame: %d of %d; square centre %.1f "
		       "(expected %.1f), %d bright pixels (square %d)\n",
		       name, ui, results[ui], sa.hud_w * sa.hud_h, centre, expected, count,
		       size * (size - sa.hud_h));
		if (ui) {
			CHECK(results[ui] == 0, "%s: %d HUD pixels changed with UI protection on", name, results[ui]);
			CHECK(centre > expected - 12 && centre < expected + 12,
			      "%s: square centre %.1f is not near the midpoint %.1f with UI protection", name,
			      centre, expected);
			CHECK(count > size * (size - sa.hud_h) * 6 / 10,
			      "%s: UI protection froze the moving square (%d bright pixels)", name, count);
		}
	}
	return 0;
}

// The fallback: a background jump the search cannot follow, not an ordinary move
static int fast_motion(id<MTLDevice> device, int engine, const char *name)
{
	const NSUInteger width = 1024, height = 768;
	struct scene still = { 0, 0, 0, 0, 0, 0, 0, 0 };
	struct scene jump = { 0, 0, 0, 400, 0, 0, 0, 0 };
	struct scene pan = { 0, 0, 0, 60, 0, 0, 0, 0 };

	id<MTLTexture> a = scene_frame(device, width, height, &still);
	id<MTLTexture> b_jump = scene_frame(device, width, height, &jump);
	id<MTLTexture> b_pan = scene_frame(device, width, height, &pan);
	id<MTLTexture> out = square_frame(device, width, height, 0, 0, 0);

	int fell_back = -1;
	int used = interpolate_opts(device, a, b_jump, out, engine, 1, 1, 1, 0.5, NULL, &fell_back);
	if (used == 0 && engine == 2) {
		printf("%-14s %s\n", name, "skipped: MetalFX frame interpolation unavailable here");
		return 0;
	}
	CHECK(used == engine, "engine %s did not run (got %d)", name, used);
	int copied = differing_pixels(out, b_jump, 0, 0, (int)width, (int)height) == 0;
	printf("%-14s 400 px jump: fallback=%d, output %s the newer real frame\n", name, fell_back,
	       copied ? "is" : "is not");
	CHECK(fell_back == 1, "%s: no fast-motion fallback on a 400 px jump", name);
	CHECK(copied, "%s: fallback fired but the output is not the newer real frame", name);

	used = interpolate_opts(device, a, b_jump, out, engine, 1, 1, 0, 0.5, NULL, &fell_back);
	CHECK(used == engine && fell_back == 0, "%s: fallback reported with NOTPROTON_FRAMEGEN_FALLBACK=0", name);

	used = interpolate_opts(device, a, b_pan, out, engine, 1, 1, 1, 0.5, NULL, &fell_back);
	CHECK(used == engine, "engine %s did not run (got %d)", name, used);
	printf("%-14s 60 px pan: fallback=%d\n", name, fell_back);
	CHECK(fell_back == 0, "%s: fast-motion fallback fired on a 60 px pan", name);
	return 0;
}

static int full_frame_cost(id<MTLDevice> device, int engine, int quality, const char *name)
{
	const NSUInteger width = 3024, height = 1964;
	id<MTLTexture> a = square_frame(device, width, height, 1000, 800, 200);
	id<MTLTexture> b = square_frame(device, width, height, 1100, 800, 200);
	id<MTLTexture> out = square_frame(device, width, height, 0, 0, 0);
	double gpu_ms = 0;
	int used = interpolate_opts(device, a, b, out, engine, quality, 1, 1, 0.5, &gpu_ms, NULL);
	if (used != engine)
		return 0;
	printf("%-14s %-11s %lux%lu: %.2f ms GPU per pair (flow + one frame)\n", name, quality_names[quality],
	       (unsigned long)width, (unsigned long)height, gpu_ms);
	return 0;
}

static int hud_hidden_on(CAMetalLayer *layer)
{
	SEL get = sel_registerName("developerHUDProperties");
	if (![layer respondsToSelector:get])
		return -1;
	id props = ((id (*)(id, SEL))objc_msgSend)(layer, get);
	if (props == nil)
		return 0;
	id mode = ((id (*)(id, SEL, id))objc_msgSend)(props, sel_registerName("objectForKey:"), @"mode");
	return mode == nil;
}

// The live path, in a child with the environment set: the worker builds, the
// mode engages at 40 fps after a second of slow frames, and generates
// `per_pair` frames for each real one. The game layer's own Metal HUD is
// switched off while the covering layer shows and restored afterwards.
static int live_path(probe_fn probe, id<MTLDevice> device, const char *label, double per_pair, int burst)
{
	int enabled = 0, hooks = 0, mode = 0, objects = 0, generated = 0, copies = 0;
	probe(&enabled, &hooks, &mode, &objects, &generated, &copies);
	CHECK(enabled == 1, "NOTPROTON_FRAMEGEN did not enable framegen");

	// The present path must survive with framegen on, offscreen
	CAMetalLayer *layer = game_layer(device);
	CHECK(present_frames(device, layer, 8, 20000), "offscreen layer vends no drawable");
	probe(&enabled, &hooks, &mode, &objects, &generated, &copies);
	CHECK(hooks >= 4, "framegen installed %d hooks, expected the present family and commit", hooks);
	printf("%-14s hooks=%d mode=%d objects=%d\n", label, hooks, mode, objects);

	// Let the worker finish building, then run slow enough that it engages
	for (int i = 0; i < 100 && mode == 1; i++) {
		usleep(50000);
		probe(&enabled, &hooks, &mode, &objects, &generated, &copies);
	}
	CHECK(mode == 3, "framegen mode %d after setup, expected pass-through", mode);
	CHECK(hud_hidden_on(layer) <= 0, "game layer HUD hidden before framegen engaged");
	CHECK(present_frames(device, layer, 110, 25000), "offscreen layer vends no drawable");
	usleep(200000);
	probe(&enabled, &hooks, &mode, &objects, &generated, &copies);
	CHECK(mode == 2, "framegen mode %d after 110 frames at 40 fps, expected active", mode);
	CHECK(hud_hidden_on(layer) != 0, "game layer HUD not hidden while the covering layer shows");
	CHECK(copies > 0, "no real frame copy presented while active");
	CHECK(generated > 0, "no frame generated while active");
	double ratio = (double)generated / copies;
	printf("%-14s %d real copies, %d generated at 40 fps (%.2f per pair, expected ~%.0f)\n", label, copies,
	       generated, ratio, per_pair);
	CHECK(ratio > per_pair - 0.5 && ratio < per_pair + 0.6, "%s: %.2f generated frames per pair, expected ~%.0f",
	      label, ratio, per_pair);
	if (!burst)
		return 0;
	// A short burst of fast frames must not drop out of active mode; a sustained one must
	int changes_before = 0, changes_after = 0;
	probe_display(NULL, NULL, NULL, NULL, &changes_before);
	double burst_start = CACurrentMediaTime();
	CHECK(present_frames(device, layer, 40, 0), "offscreen layer vends no drawable");
	double burst_ms = (CACurrentMediaTime() - burst_start) * 1000.0;
	probe(&enabled, &hooks, &mode, &objects, &generated, &copies);
	CHECK(mode == 2, "framegen mode %d after a short fast burst (40 frames in %.1f ms), expected still active",
	      mode, burst_ms);
	CHECK(present_frames(device, layer, 20, 25000), "offscreen layer vends no drawable");
	int fast_frames = 0;
	burst_start = CACurrentMediaTime();
	while (CACurrentMediaTime() - burst_start < 2.2) {
		CHECK(present_frames(device, layer, 10, 0), "offscreen layer vends no drawable");
		fast_frames += 10;
	}
	burst_ms = (CACurrentMediaTime() - burst_start) * 1000.0;
	probe(&enabled, &hooks, &mode, &objects, &generated, &copies);
	probe_display(NULL, NULL, NULL, NULL, &changes_after);
	CHECK(mode == 3, "framegen mode %d after a sustained fast burst (%d frames in %.0f ms), expected pass-through",
	      mode, fast_frames, burst_ms);
	CHECK(changes_after - changes_before == 1, "%d state changes across a short and a sustained burst, expected 1",
	      changes_after - changes_before);
	CHECK(hud_hidden_on(layer) <= 0, "game layer HUD still hidden after pass-through");
	printf("%-14s short burst (40 frames in %.0f ms) stays active; %d fast frames in %.0f ms drop to pass-through\n",
	       "framegen fast", 40 * burst_ms / fast_frames, fast_frames, burst_ms);
	return 0;
}


// The game as TEKKEN 8 under D3DMetal presents it: a 10-bit PQ layer, frames
// rendered on a Metal 4 queue, signalDrawable: then [drawable present]. Or the
// same layer on the Metal 3 present family when metal4 is 0. The frames are a
// mid-grey clear, so a black copy or a black generated frame shows as luma 0.
static int pq_path_layer(probe_fn probe, id<MTLDevice> device, int metal4, CAMetalLayer *layer,
                         const char *label, int slow);

static int pq_path(probe_fn probe, id<MTLDevice> device, int metal4, int slow)
{
	CAMetalLayer *layer = [CAMetalLayer layer];
	layer.device = device;
	layer.pixelFormat = MTLPixelFormatRGB10A2Unorm;
	layer.drawableSize = CGSizeMake(1024, 768);
	return pq_path_layer(probe, device, metal4, layer, metal4 ? "pq metal4" : "pq metal3", slow);
}

static int pq_path_layer(probe_fn probe, id<MTLDevice> device, int metal4, CAMetalLayer *layer,
                         const char *label, int slow)
{
	// CoreGraphics is not linked by the test flags; QuartzCore has it loaded
	CGColorSpaceRef (*create_space)(CFStringRef) = dlsym(RTLD_DEFAULT, "CGColorSpaceCreateWithName");
	CFStringRef *pq_name = dlsym(RTLD_DEFAULT, "kCGColorSpaceITUR_2100_PQ");
	CHECK(create_space != NULL && pq_name != NULL, "CoreGraphics colorspace symbols missing");
	CGColorSpaceRef pq = create_space(*pq_name);
	layer.colorspace = pq;
	if ([layer respondsToSelector:@selector(setWantsExtendedDynamicRangeContent:)])
		layer.wantsExtendedDynamicRangeContent = YES;

	id<MTLCommandQueue> queue = nil;
	id queue4 = nil, allocator = nil;
	if (metal4) {
		if (@available(macOS 26.0, *)) {
			queue4 = [device newMTL4CommandQueue];
			allocator = [device newCommandAllocator];
			if (queue4 != nil && layer.residencySet != nil)
				[(id<MTL4CommandQueue>)queue4 addResidencySet:layer.residencySet];
		}
		SKIP_IF(queue4 == nil || allocator == nil, "no Metal 4 command queue on this machine");
	} else {
		queue = [device newCommandQueue];
	}

	int enabled = 0, hooks = 0, mode = 0, objects = 0, generated = 0, copies = 0;
	double start = CACurrentMediaTime();
	int changes = 0, before_real = 0, pressure_copies = 0;
	for (int i = 0; i < (slow ? 420 : 180); i++) {
		if (slow && (i == 180 || i == 300)) {
			probe(NULL, NULL, &mode, NULL, NULL, &copies);
			CHECK(mode == 2, "slow pool: mode %d at frame %d", mode, i);
			if (i == 180)
				probe_display(NULL, NULL, NULL, NULL, &changes);
			else {
				pressure_copies = copies - before_real;
				CHECK(pressure_copies >= 95, "slow pool: only %d real frames", pressure_copies);
			}
			before_real = copies;
			atomic_store(&delayed_drawable, i == 180);
		}
		@autoreleasepool {
			id<CAMetalDrawable> drawable = [layer nextDrawable];
			CHECK(drawable != nil, "%s: layer vends no drawable at frame %d", label, i);
			double grey = 0.55 + 0.1 * ((i / 30) & 1);
			if (metal4) {
				if (@available(macOS 26.0, *)) {
					id<MTL4CommandBuffer> buffer = [device newCommandBuffer];
					[buffer beginCommandBufferWithAllocator:allocator];
					MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
					pass.colorAttachments[0].texture = drawable.texture;
					pass.colorAttachments[0].loadAction = MTLLoadActionClear;
					pass.colorAttachments[0].storeAction = MTLStoreActionStore;
					pass.colorAttachments[0].clearColor = MTLClearColorMake(grey, grey, grey, 1.0);
					id<MTL4RenderCommandEncoder> encoder =
					        [buffer renderCommandEncoderWithDescriptor:pass];
					[encoder endEncoding];
					[buffer endCommandBuffer];
					id<MTL4CommandQueue> q4 = queue4;
					[q4 waitForDrawable:drawable];
					[q4 commit:&buffer count:1];
					[q4 signalDrawable:drawable];
					[drawable present];
					[pass release];
					[buffer release];
				}
			} else {
				id<MTLCommandBuffer> buffer = [queue commandBuffer];
				MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
				pass.colorAttachments[0].texture = drawable.texture;
				pass.colorAttachments[0].loadAction = MTLLoadActionClear;
				pass.colorAttachments[0].storeAction = MTLStoreActionStore;
				pass.colorAttachments[0].clearColor = MTLClearColorMake(grey, grey, grey, 1.0);
				id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
				[encoder endEncoding];
				[buffer presentDrawable:drawable];
				[buffer commit];
			}
			double wait = start + (i + 1) / 60.0 - CACurrentMediaTime();
			if (wait > 0)
				usleep((useconds_t)(wait * 1e6));
		}
	}
	usleep(300000);
	probe(&enabled, &hooks, &mode, &objects, &generated, &copies);
	int presented = -1, dropped = -1;
	double luma_real = -1, luma_generated = -1;
	probe_display(&presented, &dropped, &luma_real, &luma_generated, NULL);
	if (slow) {
		int after = 0;
		probe_display(NULL, NULL, NULL, NULL, &after);
		CHECK(after == changes && copies - before_real >= 95,
		      "slow pool: %d mode transitions, %d real copies after recovery", after - changes, copies - before_real);
		printf("slow pool: %d real copies under pressure, %d after recovery, %d mode transitions\n",
		       pressure_copies, copies - before_real, after - changes);
	}
	printf("%-14s mode=%d copies=%d generated=%d presented=%d dropped=%d luma real=%.3f generated=%.3f\n",
	       label, mode, copies, generated, presented, dropped, luma_real, luma_generated);
	CHECK(mode == 2, "%s: framegen mode %d after 180 frames at 60 fps on 120 Hz, expected active", label,
	      mode);
	CHECK(generated > 0 && copies > 0, "%s: nothing generated or copied", label);
	CHECK(luma_real > 0.3, "%s: the real frame copy is dark (luma %.3f), the copy read an unrendered "
	      "drawable", label, luma_real);
	CHECK(luma_generated > 0.3, "%s: the generated frame is dark (luma %.3f)", label, luma_generated);
	return 0;
}

// A cutscene-like cadence: 8 ms and 25 ms gaps alternating, 60.6 fps on average
// on a 120 Hz refresh. The smoothed rate must engage once and then hold.
static int irregular_cadence(probe_fn probe, id<MTLDevice> device)
{
	int enabled = 0, hooks = 0, mode = 0, objects = 0, generated = 0, copies = 0;
	CAMetalLayer *layer = game_layer(device);
	CHECK(present_frames(device, layer, 8, 20000), "offscreen layer vends no drawable");
	probe(&enabled, &hooks, &mode, &objects, &generated, &copies);
	for (int i = 0; i < 100 && mode == 1; i++) {
		usleep(50000);
		probe(&enabled, &hooks, &mode, &objects, &generated, &copies);
	}
	CHECK(mode == 3, "framegen mode %d after setup, expected pass-through", mode);
	int changes_before = 0, changes_after = 0;
	probe_display(NULL, NULL, NULL, NULL, &changes_before);
	double start = CACurrentMediaTime(), next = start;
	int frames = 0;
	while (CACurrentMediaTime() - start < 3.5) {
		CHECK(present_frames(device, layer, 1, 0), "offscreen layer vends no drawable");
		next += (frames & 1) ? 0.025 : 0.008;
		double wait = next - CACurrentMediaTime();
		if (wait > 0)
			usleep((useconds_t)(wait * 1e6));
		frames++;
	}
	usleep(200000);
	probe(&enabled, &hooks, &mode, &objects, &generated, &copies);
	probe_display(NULL, NULL, NULL, NULL, &changes_after);
	printf("%-14s %d frames in 3.5 s (8/25 ms alternating): mode=%d generated=%d copies=%d state changes=%d\n",
	       "irregular", frames, mode, generated, copies, changes_after - changes_before);
	CHECK(mode == 2, "framegen mode %d on an irregular 60 fps cadence, expected active", mode);
	CHECK(changes_after - changes_before <= 1, "%d state changes on an irregular cadence, expected at most 1",
	      changes_after - changes_before);
	CHECK(generated > 0, "nothing generated on the irregular cadence");
	return 0;
}

static int child_with_env(const char *path, const char *which)
{
	probe_fn probe = NULL;
	interpolate_fn interpolate = NULL;

	CHECK(load_shim(path, &probe, &interpolate) != NULL, "%s does not load: %s", path, dlerror());
	CHECK(probe != NULL && interpolate != NULL && interpolate_opts != NULL,
	      "%s exports no framegen entry points", path);

	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	SKIP_IF(device == nil, "no Metal device on this machine");

	probe_display = (probe_display_fn)dlsym(dlopen(path, RTLD_NOW | RTLD_LOCAL), "np_framegen_probe_display");
	CHECK(probe_display != NULL, "%s exports no np_framegen_probe_display", path);
	if (strcmp(which, "metal4") == 0)
		return pq_path(probe, device, 1, 0);
	if (strcmp(which, "slow-pool") == 0) {
		Method m = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
		next_drawable = (void *)method_setImplementation(m, (IMP)slow_cover_drawable);
		return pq_path(probe, device, 0, 1);
	}
	if (strcmp(which, "metal3") == 0)
		return pq_path(probe, device, 0, 0);
	if (strcmp(which, "irregular") == 0)
		return irregular_cadence(probe, device);
	if (strcmp(which, "3") == 0)
		return live_path(probe, device, "framegen 3x", 2, 0);
	if (strcmp(which, "adaptive") == 0)
		return live_path(probe, device, "framegen adapt", 2, 0);

	int rc = live_path(probe, device, "framegen on", 1, 1);
	if (rc != 0)
		return rc;

	// Engines at the midpoint, then the 3x positions
	if ((rc = square_at(device, 1, 1, 0.5, "own engine")) != 0)
		return rc;
	if ((rc = square_at(device, 2, 1, 0.5, "metalfx")) != 0)
		return rc;
	if ((rc = square_at(device, 1, 1, 1.0 / 3.0, "own 3x")) != 0)
		return rc;
	if ((rc = square_at(device, 1, 1, 2.0 / 3.0, "own 3x")) != 0)
		return rc;
	// Each quality level moves the square too
	if ((rc = square_at(device, 1, 0, 0.5, "performance")) != 0)
		return rc;
	if ((rc = square_at(device, 1, 2, 0.5, "quality")) != 0)
		return rc;
	// UI protection and the fallback, on both engines
	if ((rc = hud_protect(device, 1, "own hud")) != 0)
		return rc;
	if ((rc = hud_protect(device, 2, "metalfx hud")) != 0)
		return rc;
	if ((rc = fast_motion(device, 1, "own fallback")) != 0)
		return rc;
	if ((rc = fast_motion(device, 2, "metalfx fb")) != 0)
		return rc;
	for (int quality = 0; quality < 3; quality++)
		full_frame_cost(device, 1, quality, "own engine");
	full_frame_cost(device, 2, 1, "metalfx");
	return 0;
}

static int spawn_child(char *exe, const char *mode, const char *child_name, const char *refresh)
{
	// The shim reads the environment when it loads, so the on cases are children
	char **environ_now = *_NSGetEnviron();
	int count = 0;
	while (environ_now[count] != NULL)
		count++;
	char **env = calloc((size_t)count + 5, sizeof(char *));
	memcpy(env, environ_now, (size_t)count * sizeof(char *));
	char framegen[64], child[64], hz[64];
	snprintf(framegen, sizeof(framegen), "NOTPROTON_FRAMEGEN=%s", mode);
	snprintf(child, sizeof(child), "NP_FRAMEGEN_TEST_CHILD=%s", child_name);
	snprintf(hz, sizeof(hz), "NOTPROTON_FRAMEGEN_REFRESH_HZ=%s", refresh);
	env[count] = framegen;
	env[count + 1] = child;
	env[count + 2] = hz;

	fflush(stdout);
	pid_t pid;
	char *args[] = { exe, NULL };
	CHECK(posix_spawn(&pid, exe, NULL, NULL, args, env) == 0, "cannot spawn %s", exe);
	int status = 0;
	CHECK(waitpid(pid, &status, 0) == pid, "waitpid failed");
	CHECK(WIFEXITED(status), "framegen child %s did not exit cleanly (status %d)", mode, status);
	free(env);
	return WEXITSTATUS(status);
}

int main(int argc, char **argv)
{
	const char *path = getenv("NOTPROTON_OVERLAY_SHIM");
	const char *child = getenv("NP_FRAMEGEN_TEST_CHILD");

	SKIP_IF(path == NULL, "NOTPROTON_OVERLAY_SHIM names the shim to load");
	(void)argc;

	if (child != NULL)
		return child_with_env(path, child);

	int rc = inert_without_env(path);
	if (rc != 0)
		return rc;
	// 2x on a 120 Hz display: the whole suite. 3x and adaptive at a simulated
	// 40 fps on 120 Hz: two generated frames per real one.
	if ((rc = spawn_child(argv[0], "1", "1", "120")) != 0)
		return rc;
	if ((rc = spawn_child(argv[0], "3", "3", "120")) != 0)
		return rc;
	if ((rc = spawn_child(argv[0], "adaptive", "adaptive", "120")) != 0)
		return rc;
	// A 10-bit PQ layer on the Metal 3 and the Metal 4 (signalDrawable) present paths
	if ((rc = spawn_child(argv[0], "1", "metal3", "120")) != 0)
		return rc;
	if ((rc = spawn_child(argv[0], "1", "metal4", "120")) != 0)
		return rc;
	if ((rc = spawn_child(argv[0], "1", "slow-pool", "120")) != 0)
		return rc;
	return spawn_child(argv[0], "1", "irregular", "120");
}
