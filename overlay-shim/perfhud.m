// Bridgeplay's performance overlay: NOTPROTON_PERF_OVERLAY (BRIDGEPLAY_PERF_OVERLAY in launch
// options and confs) = fps | summary | detailed. Included by overlay_shim.m after framegen.m.
//
// Frame times come from the game's own nextDrawable calls (framegen's internal ones are left
// out, so this is the rate the game renders at). Every value is read from the Mac while the
// game runs: CPU from host_processor_info, GPU utilisation and memory from the AGX
// accelerator's PerformanceStatistics, memory from the VM statistics, battery from IOKit's
// power sources, power from the battery's telemetry. A value the Mac does not give (no
// battery on a desktop, a key a future macOS drops) is left off, never guessed.
//
// The overlay is a plain CALayer above the game's CAMetalLayer, redrawn twice a second
// off the render thread, so nothing is added to the game's own frames. The Metal HUD
// (MTL_HUD_ENABLED) wins when both are on: one overlay, not two.

#import <CoreText/CoreText.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPSKeys.h>
#import <IOKit/ps/IOPowerSources.h>
#import <sys/resource.h>
#import <sys/sysctl.h>

// Geist (OFL, see NOTICE), the typeface of Bridgeplay's app and site, so the overlay does not
// depend on the app being where it was installed.
#ifndef NP_GEIST_PATH
#define NP_GEIST_PATH "app/Sources/BridgeplayUI/Resources/Fonts/geist.woff2"
#endif
__asm__(".section __TEXT,__const\n"
        ".p2align 4\n"
        ".private_extern _np_geist_font\n"
        "_np_geist_font:\n"
        ".incbin \"" NP_GEIST_PATH "\"\n"
        ".private_extern _np_geist_font_end\n"
        "_np_geist_font_end:\n");
extern const unsigned char np_geist_font[];
extern const unsigned char np_geist_font_end[];

enum { ph_off, ph_fps, ph_summary, ph_detailed };
static const char *const ph_level_names[] = { "off", "fps", "summary", "detailed" };

#define ph_ring 120

// Changed at run time by the quick settings sidebar, read on the render and sampler threads
static _Atomic int ph_level;
// Set when the game started with Apple's Metal HUD, which then stays the only overlay
static int ph_hud_locked;
static os_unfair_lock ph_lock = OS_UNFAIR_LOCK_INIT;
// Under ph_lock, written on the render thread
static float ph_intervals[ph_ring]; // ms between the game's frames
static unsigned ph_written;
static uint64_t ph_frames;
static double ph_last_frame;
static id ph_host; // the CAMetalLayer the overlay sits on, retained
static int ph_started;

// The sampler's own, on ph_queue
static dispatch_queue_t ph_queue;
static dispatch_source_t ph_timer;
static uint64_t ph_tick_frames;
static double ph_tick_time;
static unsigned ph_tick_written;
static unsigned ph_ticks;

// Set on the main thread, read by the sampler
static _Atomic double ph_scale = 2.0;
static _Atomic int ph_refresh_hz;
static CALayer *ph_layer; // main thread only

// What the last tick measured; -1 when the Mac does not say
struct ph_sample {
	double fps, ft_avg, ft_min, ft_max;
	int cpu, gpu, battery, on_ac, charging, minutes_left, hz;
	double game_cpu, ram_used, ram_total, game_mem, gpu_mem, watts;
	double cap; // frame rate limit in force; 0 not known yet, -1 none
	int idle;
};

static struct ph_sample ph_last;
static _Atomic int ph_attached;

static void perfhud_start(void);
static double framelimit_cap(void); // framelimit.m
static const char *scalefilter_state(double *scale); // scalefilter.m

static void perfhud_note_frame(id layer)
{
	if (ph_level == ph_off || fg_internal || layer == nil)
		return;

	double now = CACurrentMediaTime();
	id dropped = nil;
	int start = 0;

	os_unfair_lock_lock(&ph_lock);
	if (layer != ph_host) {
		// Another layer takes the overlay once the one it is on has gone quiet: a launcher
		// window that closed, the game's real window replacing a splash
		if (ph_host != nil && now - ph_last_frame < 1.0) {
			os_unfair_lock_unlock(&ph_lock);
			return;
		}
		dropped = ph_host;
		ph_host = [layer retain];
		ph_last_frame = 0;
	}
	if (ph_last_frame > 0) {
		double ms = (now - ph_last_frame) * 1000.0;
		if (ms < 1000.0)
			ph_intervals[ph_written++ % ph_ring] = (float)ms;
	}
	ph_last_frame = now;
	ph_frames++;
	if (!ph_started)
		start = ph_started = 1;
	os_unfair_lock_unlock(&ph_lock);

	// A layer is the main thread's to let go of
	if (dropped != nil)
		dispatch_async(dispatch_get_main_queue(), ^{
			[dropped release];
		});
	if (start)
		perfhud_start();
}

// MARK: Measuring

static host_t ph_host_port;

static int ph_cpu_percent(void)
{
	static uint64_t last_busy, last_total;
	natural_t count = 0;
	processor_info_array_t info = NULL;
	mach_msg_type_number_t info_count = 0;

	if (host_processor_info(ph_host_port, PROCESSOR_CPU_LOAD_INFO, &count, &info, &info_count) !=
	    KERN_SUCCESS)
		return -1;

	uint64_t busy = 0, total = 0;
	processor_cpu_load_info_t load = (processor_cpu_load_info_t)info;
	for (natural_t i = 0; i < count; i++) {
		uint64_t b = (uint64_t)load[i].cpu_ticks[CPU_STATE_USER] + load[i].cpu_ticks[CPU_STATE_SYSTEM] +
		             load[i].cpu_ticks[CPU_STATE_NICE];
		busy += b;
		total += b + load[i].cpu_ticks[CPU_STATE_IDLE];
	}
	vm_deallocate(mach_task_self(), (vm_address_t)info, info_count * sizeof(integer_t));

	int percent = -1;
	if (last_total != 0 && total > last_total)
		percent = (int)((busy - last_busy) * 100 / (total - last_total));
	last_busy = busy;
	last_total = total;
	return percent;
}

// The game process's CPU time against wall time, Activity Monitor's way (100% is one core)
static double ph_game_cpu(double now)
{
	static double last_cpu, last_now;
	struct rusage usage;

	if (getrusage(RUSAGE_SELF, &usage) != 0)
		return -1;
	double cpu = usage.ru_utime.tv_sec + usage.ru_utime.tv_usec * 1e-6 + usage.ru_stime.tv_sec +
	             usage.ru_stime.tv_usec * 1e-6;
	double percent = -1;
	if (last_now > 0 && now > last_now)
		percent = (cpu - last_cpu) / (now - last_now) * 100.0;
	last_cpu = cpu;
	last_now = now;
	return percent;
}

// Activity Monitor's Memory Used: app memory, wired and compressed. Pages are the host's
// (16 KiB), also under Rosetta, where vm_page_size says 4 KiB.
static void ph_memory(struct ph_sample *s)
{
	vm_statistics64_data_t vm;
	mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
	vm_size_t page = 0;
	uint64_t total = 0;
	size_t length = sizeof(total);

	if (host_statistics64(ph_host_port, HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS &&
	    host_page_size(ph_host_port, &page) == KERN_SUCCESS && page > 0) {
		uint64_t pages = (uint64_t)vm.internal_page_count - vm.purgeable_count + vm.wire_count +
		                 vm.compressor_page_count;
		s->ram_used = (double)pages * page;
	}
	if (sysctlbyname("hw.memsize", &total, &length, NULL, 0) == 0)
		s->ram_total = (double)total;

	task_vm_info_data_t task;
	mach_msg_type_number_t task_count = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&task, &task_count) == KERN_SUCCESS)
		s->game_mem = (double)task.phys_footprint;
}

static double ph_number(CFDictionaryRef dict, CFStringRef key)
{
	CFTypeRef value = dict != NULL ? CFDictionaryGetValue(dict, key) : NULL;
	double out = -1;
	if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID() ||
	    !CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &out))
		return -1;
	return out;
}

static io_registry_entry_t ph_gpu_entry;

static void ph_gpu(struct ph_sample *s)
{
	static int looked;

	if (!looked) {
		looked = 1;
		io_iterator_t it = 0;
		if (IOServiceGetMatchingServices(0, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS) {
			io_object_t entry;
			while ((entry = IOIteratorNext(it)) != 0) {
				CFTypeRef stats = IORegistryEntryCreateCFProperty(entry, CFSTR("PerformanceStatistics"),
				                                                  kCFAllocatorDefault, 0);
				int usable = stats != NULL && CFGetTypeID(stats) == CFDictionaryGetTypeID() &&
				             ph_number(stats, CFSTR("Device Utilization %")) >= 0;
				if (stats != NULL)
					CFRelease(stats);
				if (usable && ph_gpu_entry == 0)
					ph_gpu_entry = entry;
				else
					IOObjectRelease(entry);
			}
			IOObjectRelease(it);
		}
		shim_log("overlay_shim perfhud: GPU statistics %s\n", ph_gpu_entry ? "found" : "unavailable");
	}
	if (ph_gpu_entry == 0)
		return;

	CFTypeRef stats = IORegistryEntryCreateCFProperty(ph_gpu_entry, CFSTR("PerformanceStatistics"),
	                                                  kCFAllocatorDefault, 0);
	if (stats == NULL)
		return;
	if (CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
		double util = ph_number(stats, CFSTR("Device Utilization %"));
		double mem = ph_number(stats, CFSTR("In use system memory"));
		s->gpu = util >= 0 ? (int)util : -1;
		s->gpu_mem = mem;
	}
	CFRelease(stats);
}

// The internal battery's charge and state, -1 for what the Mac does not report. Goes through
// powerd, so callers ask every few seconds. Keeps no state: the sidebar calls it on the main
// thread while the overlay's sampler does on its own.
static void ph_read_battery(int *battery_out, int *on_ac_out, int *charging_out, int *minutes_out)
{
	int battery = -1, on_ac = -1, charging = -1, minutes = -1;
	{
		CFTypeRef info = IOPSCopyPowerSourcesInfo();
		CFArrayRef list = info != NULL ? IOPSCopyPowerSourcesList(info) : NULL;
		for (CFIndex i = 0; list != NULL && i < CFArrayGetCount(list); i++) {
			CFDictionaryRef ps = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
			CFTypeRef type = ps != NULL ? CFDictionaryGetValue(ps, CFSTR(kIOPSTypeKey)) : NULL;
			if (type == NULL || CFGetTypeID(type) != CFStringGetTypeID() ||
			    !CFEqual(type, CFSTR(kIOPSInternalBatteryType)))
				continue;
			double now = ph_number(ps, CFSTR(kIOPSCurrentCapacityKey));
			double max = ph_number(ps, CFSTR(kIOPSMaxCapacityKey));
			if (now >= 0 && max > 0)
				battery = (int)(now * 100.0 / max + 0.5);
			CFTypeRef state = CFDictionaryGetValue(ps, CFSTR(kIOPSPowerSourceStateKey));
			if (state != NULL && CFGetTypeID(state) == CFStringGetTypeID())
				on_ac = CFEqual(state, CFSTR(kIOPSACPowerValue)) ? 1 : 0;
			CFTypeRef is_charging = CFDictionaryGetValue(ps, CFSTR(kIOPSIsChargingKey));
			if (is_charging != NULL && CFGetTypeID(is_charging) == CFBooleanGetTypeID())
				charging = CFBooleanGetValue(is_charging) ? 1 : 0;
			// 0 while macOS is still working it out
			double left = ph_number(ps, CFSTR(kIOPSTimeToEmptyKey));
			minutes = left > 0 ? (int)left : -1;
			break;
		}
		if (list != NULL)
			CFRelease(list);
		if (info != NULL)
			CFRelease(info);
	}
	*battery_out = battery;
	*on_ac_out = on_ac;
	*charging_out = charging;
	*minutes_out = minutes;
}

static void ph_battery(struct ph_sample *s)
{
	static int battery = -1, on_ac = -1, charging = -1, minutes = -1;

	if (ph_ticks % 10 == 0)
		ph_read_battery(&battery, &on_ac, &charging, &minutes);
	s->battery = battery;
	s->on_ac = on_ac;
	s->charging = charging;
	s->minutes_left = on_ac == 1 ? -1 : minutes;
}

// What the whole Mac draws, in watts: the battery gauge's SystemLoad (mW), on battery and on
// AC alike. Without it, the battery's own discharge while on battery.
static double ph_power(void)
{
	static io_registry_entry_t battery;
	static dispatch_once_t looked;

	dispatch_once(&looked, ^{
		battery = IOServiceGetMatchingService(0, IOServiceMatching("AppleSmartBattery"));
	});
	if (battery == 0)
		return -1;

	double watts = -1;
	CFTypeRef telemetry = IORegistryEntryCreateCFProperty(battery, CFSTR("PowerTelemetryData"),
	                                                      kCFAllocatorDefault, 0);
	if (telemetry != NULL) {
		if (CFGetTypeID(telemetry) == CFDictionaryGetTypeID()) {
			double load = ph_number(telemetry, CFSTR("SystemLoad"));
			if (load > 0 && load < 1e6)
				watts = load / 1000.0;
		}
		CFRelease(telemetry);
	}
	if (watts < 0) {
		CFTypeRef amps = IORegistryEntryCreateCFProperty(battery, CFSTR("InstantAmperage"), kCFAllocatorDefault, 0);
		CFTypeRef volts = IORegistryEntryCreateCFProperty(battery, CFSTR("Voltage"), kCFAllocatorDefault, 0);
		int64_t ma = 0, mv = 0;
		if (amps != NULL && volts != NULL && CFGetTypeID(amps) == CFNumberGetTypeID() &&
		    CFGetTypeID(volts) == CFNumberGetTypeID() &&
		    CFNumberGetValue((CFNumberRef)amps, kCFNumberSInt64Type, &ma) &&
		    CFNumberGetValue((CFNumberRef)volts, kCFNumberSInt64Type, &mv) && ma < 0 && mv > 0)
			watts = (double)(-ma) * (double)mv / 1e6;
		if (amps != NULL)
			CFRelease(amps);
		if (volts != NULL)
			CFRelease(volts);
	}
	return watts;
}

// MARK: Drawing

static CTFontDescriptorRef ph_base_font;

static CTFontRef ph_font(double size, double weight)
{
	static int looked;

	if (!looked) {
		looked = 1;
		CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, np_geist_font,
		                                             np_geist_font_end - np_geist_font, kCFAllocatorNull);
		ph_base_font = data != NULL ? CTFontManagerCreateFontDescriptorFromData(data) : NULL;
		if (data != NULL)
			CFRelease(data);
		shim_log("overlay_shim perfhud: Geist %s\n", ph_base_font != NULL ? "loaded" : "unavailable, system font");
	}

	// Tabular figures, so numbers that change twice a second do not shift sideways
	int spacing = kNumberSpacingType, mono = kMonospacedNumbersSelector;
	CFNumberRef type = CFNumberCreate(NULL, kCFNumberIntType, &spacing);
	CFNumberRef selector = CFNumberCreate(NULL, kCFNumberIntType, &mono);
	const void *feature_keys[] = { kCTFontFeatureTypeIdentifierKey, kCTFontFeatureSelectorIdentifierKey };
	const void *feature_values[] = { type, selector };
	CFDictionaryRef feature = CFDictionaryCreate(NULL, feature_keys, feature_values, 2,
	                                             &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFArrayRef features = CFArrayCreate(NULL, (const void **)&feature, 1, &kCFTypeArrayCallBacks);

	int axis = 'wght';
	CFNumberRef axis_id = CFNumberCreate(NULL, kCFNumberIntType, &axis);
	CFNumberRef axis_value = CFNumberCreate(NULL, kCFNumberDoubleType, &weight);
	CFDictionaryRef variation = CFDictionaryCreate(NULL, (const void **)&axis_id, (const void **)&axis_value, 1,
	                                               &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	const void *keys[] = { kCTFontFeatureSettingsAttribute, kCTFontVariationAttribute };
	const void *values[] = { features, variation };
	CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, ph_base_font != NULL ? 2 : 1,
	                                                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

	CTFontRef font;
	if (ph_base_font != NULL) {
		CTFontDescriptorRef desc = CTFontDescriptorCreateCopyWithAttributes(ph_base_font, attributes);
		font = CTFontCreateWithFontDescriptor(desc, size, NULL);
		CFRelease(desc);
	} else {
		CTFontRef system = CTFontCreateUIFontForLanguage(weight >= 550 ? kCTFontUIFontEmphasizedSystem :
		                                                                 kCTFontUIFontSystem, size, NULL);
		CTFontDescriptorRef desc = CTFontDescriptorCreateWithAttributes(attributes);
		font = CTFontCreateCopyWithAttributes(system, size, NULL, desc);
		CFRelease(desc);
		CFRelease(system);
	}

	CFRelease(attributes);
	CFRelease(variation);
	CFRelease(axis_value);
	CFRelease(axis_id);
	CFRelease(features);
	CFRelease(feature);
	CFRelease(selector);
	CFRelease(type);
	return font;
}

// The brand's colours (BridgeplayTheme.swift): off-white and secondary grey type, near-black
// raised surface, hairline borders, the violet-blue-pink gradient for a value's extent (a slider's
// fill, the frame-time line), and amber only for a warning (a frame well over budget).
#define PH_RGB(hex, a) (((hex) >> 16) & 0xff) / 255.0, (((hex) >> 8) & 0xff) / 255.0, ((hex) & 0xff) / 255.0, (a)

struct ph_style {
	CTFontRef value, value_big, label, small;
	CGColorRef fg, fg2, fg3, line;
};

static struct ph_style ph_style;

// The sampler's queue (the overlay) and the main thread (the sidebar, its hint) both draw, so the
// style is made once, before either reads a font.
static void ph_style_make(void *unused)
{
	(void)unused;
	CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGFloat fg[] = { PH_RGB(0xF5F5F7, 1) }, fg2[] = { PH_RGB(0xA1A1A6, 1) },
	        fg3[] = { PH_RGB(0x86868B, 1) }, line[] = { 1, 1, 1, 0.10 };
	ph_style.fg = CGColorCreate(srgb, fg);
	ph_style.fg2 = CGColorCreate(srgb, fg2);
	ph_style.fg3 = CGColorCreate(srgb, fg3);
	ph_style.line = CGColorCreate(srgb, line);
	CGColorSpaceRelease(srgb);
	ph_style.value = ph_font(13, 600);
	ph_style.value_big = ph_font(22, 600);
	// 10.5 and 11 pt: the smallest that stay readable over a game on a Retina window
	ph_style.label = ph_font(10.5, 500);
	ph_style.small = ph_font(11, 400);
}

static void ph_style_load(void)
{
	static dispatch_once_t once;
	dispatch_once_f(&once, NULL, ph_style_make);
}

// The baseline that centres a font's capitals on the line at y: how a label and the value
// beside it share an optical centre even at different sizes.
static double ph_centred(double y, CTFontRef font)
{
	return y + CTFontGetCapHeight(font) / 2;
}

static CTLineRef ph_line(const char *text, CTFontRef font, CGColorRef color, double tracking)
{
	CFStringRef string = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
	CFNumberRef kern = CFNumberCreate(NULL, kCFNumberDoubleType, &tracking);
	const void *keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName, kCTKernAttributeName };
	const void *values[] = { font, color, kern };
	CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 3, &kCFTypeDictionaryKeyCallBacks,
	                                                &kCFTypeDictionaryValueCallBacks);
	CFAttributedStringRef attributed = CFAttributedStringCreate(NULL, string, attributes);
	CTLineRef line = CTLineCreateWithAttributedString(attributed);
	CFRelease(attributed);
	CFRelease(attributes);
	CFRelease(kern);
	CFRelease(string);
	return line;
}

static double ph_width(const char *text, CTFontRef font, double tracking)
{
	CTLineRef line = ph_line(text, font, ph_style.fg, tracking);
	double w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
	CFRelease(line);
	return w;
}

// Draws text with its baseline at y (points from the top of a box h tall); returns the width.
static double ph_text(CGContextRef ctx, double h, double x, double y, const char *text, CTFontRef font,
                      CGColorRef color, double tracking)
{
	if (ctx == NULL)
		return ph_width(text, font, tracking);
	CTLineRef line = ph_line(text, font, color, tracking);
	CGContextSetTextPosition(ctx, x, h - y);
	CTLineDraw(line, ctx);
	double w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
	CFRelease(line);
	return w;
}

static void ph_gradient(CGContextRef ctx, CGPoint from, CGPoint to)
{
	CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGFloat stops[] = { PH_RGB(0x8B7BFF, 1), PH_RGB(0x4FB3FF, 1), PH_RGB(0xFF7AC6, 1) };
	CGFloat at[] = { 0, 0.5, 1 };
	CGGradientRef gradient = CGGradientCreateWithColorComponents(srgb, stops, at, 3);
	CGContextDrawLinearGradient(ctx, gradient, from, to,
	                            kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
	CGGradientRelease(gradient);
	CGColorSpaceRelease(srgb);
}

static void ph_surface(CGContextRef ctx, double w, double h)
{
	CGRect box = CGRectMake(0.5, 0.5, w - 1, h - 1);
	CGPathRef path = CGPathCreateWithRoundedRect(box, 8, 8, NULL);
	CGContextAddPath(ctx, path);
	CGContextSetRGBFillColor(ctx, PH_RGB(0x0D0D0F, 0.86));
	CGContextFillPath(ctx);
	CGContextAddPath(ctx, path);
	CGContextSetStrokeColorWithColor(ctx, ph_style.line);
	CGContextSetLineWidth(ctx, 1);
	CGContextStrokePath(ctx);
	CGPathRelease(path);
}

static void ph_format_gb(char *out, size_t size, double bytes)
{
	snprintf(out, size, "%.1f GB", bytes / 1073741824.0);
}

// One "LABEL value" pair centred on the line at mid; returns the advance.
static double ph_pair(CGContextRef ctx, double h, double x, double mid, const char *label, const char *value)
{
	double w = ph_text(ctx, h, x, ph_centred(mid, ph_style.label), label, ph_style.label, ph_style.fg2, 0.5);
	return w + 5 + ph_text(ctx, h, x + w + 5, ph_centred(mid, ph_style.value), value, ph_style.value, ph_style.fg, 0);
}

static void ph_divider(CGContextRef ctx, double h, double x)
{
	if (ctx == NULL)
		return;
	CGContextSetFillColorWithColor(ctx, ph_style.line);
	CGContextFillRect(ctx, CGRectMake(x, (h - 12) / 2, 1, 12));
}

static void ph_fps_text(char *out, size_t size, const struct ph_sample *s)
{
	if (s->idle || s->fps < 0)
		snprintf(out, size, "–");
	else
		snprintf(out, size, "%d", (int)(s->fps + 0.5));
}

static void ph_battery_text(char *out, size_t size, const struct ph_sample *s, int full)
{
	char watts[24] = "";
	if (!full && s->watts > 0)
		snprintf(watts, sizeof(watts), " · %.1f W", s->watts);
	if (!full) {
		snprintf(out, size, "%d%%%s", s->battery, watts);
	} else if (s->on_ac == 1) {
		snprintf(out, size, "%d%% · %s", s->battery, s->charging == 1 ? "charging" : "on power");
	} else if (s->minutes_left > 0) {
		snprintf(out, size, "%d%% · %d:%02d left", s->battery, s->minutes_left / 60, s->minutes_left % 60);
	} else {
		snprintf(out, size, "%d%%", s->battery);
	}
}

// Lays out (ctx NULL) or draws one level; returns the size in points.
static CGSize ph_draw_compact(CGContextRef ctx, const struct ph_sample *s, double h_box)
{
	const double h = 28, mid = h / 2, pad = 12;
	char fps[16];
	ph_fps_text(fps, sizeof(fps), s);
	double x = pad;
	x += ph_text(ctx, h_box, x, ph_centred(mid, ph_style.value), fps, ph_style.value, ph_style.fg, 0);
	x += 4;
	x += ph_text(ctx, h_box, x, ph_centred(mid, ph_style.label), "FPS", ph_style.label, ph_style.fg2, 0.5);
	return CGSizeMake(x + pad, h);
}

static CGSize ph_draw_summary(CGContextRef ctx, const struct ph_sample *s, double h_box)
{
	const double h = 28, mid = h / 2, gap = 10;
	const double base = ph_centred(mid, ph_style.value);
	char text[48];
	double x = 12;

	ph_fps_text(text, sizeof(text), s);
	x += ph_text(ctx, h_box, x, base, text, ph_style.value, ph_style.fg, 0);
	x += 4;
	x += ph_text(ctx, h_box, x, ph_centred(mid, ph_style.label), "FPS", ph_style.label, ph_style.fg2, 0.5);
	if (!s->idle && s->ft_avg > 0) {
		snprintf(text, sizeof(text), "%.1f", s->ft_avg);
		x += 8;
		x += ph_text(ctx, h_box, x, base, text, ph_style.value, ph_style.fg, 0);
		x += 3;
		// A lowercase unit stays on its number's baseline
		x += ph_text(ctx, h_box, x, base, "ms", ph_style.label, ph_style.fg2, 0.2);
	}
	if (s->cap > 0) {
		snprintf(text, sizeof(text), "%.0f", s->cap);
		x += gap;
		ph_divider(ctx, h, x);
		x += 1 + gap;
		x += ph_pair(ctx, h_box, x, mid, "CAP", text);
	}

	struct { const char *label; char value[32]; int shown; } parts[4] = {
		{ "CPU", "", s->cpu >= 0 }, { "GPU", "", s->gpu >= 0 }, { "RAM", "", s->ram_used > 0 },
		{ "BAT", "", s->battery >= 0 },
	};
	snprintf(parts[0].value, sizeof(parts[0].value), "%d%%", s->cpu);
	snprintf(parts[1].value, sizeof(parts[1].value), "%d%%", s->gpu);
	ph_format_gb(parts[2].value, sizeof(parts[2].value), s->ram_used);
	ph_battery_text(parts[3].value, sizeof(parts[3].value), s, 0);
	for (int i = 0; i < 4; i++) {
		if (!parts[i].shown)
			continue;
		x += gap;
		ph_divider(ctx, h, x);
		x += 1 + gap;
		x += ph_pair(ctx, h_box, x, mid, parts[i].label, parts[i].value);
	}
	// On a desktop Mac the power figure has no battery to sit with
	if (s->battery < 0 && s->watts > 0) {
		snprintf(text, sizeof(text), "%.1f W", s->watts);
		x += gap;
		ph_divider(ctx, h, x);
		x += 1 + gap;
		x += ph_pair(ctx, h_box, x, mid, "PWR", text);
	}
	return CGSizeMake(x + 12, h);
}

static int ph_graph(float *out, int max)
{
	os_unfair_lock_lock(&ph_lock);
	unsigned written = ph_written;
	int n = written < (unsigned)max ? (int)written : max;
	for (int i = 0; i < n; i++)
		out[i] = ph_intervals[(written - n + i) % ph_ring];
	os_unfair_lock_unlock(&ph_lock);
	return n;
}

static CGSize ph_draw_detailed(CGContextRef ctx, const struct ph_sample *s, double h_box)
{
	// Every text line is centred in its own slot by cap height, so the padding reads the same
	// above the first line and below the last
	const double w = 240, left = 14, right = w - 14, row = 20, pad = 10, bottom = 12;
	char text[64], label_ms[48];
	double y = pad;

	// FPS and frame time, centred together on one line
	const double head = 32, head_mid = y + head / 2;
	ph_fps_text(text, sizeof(text), s);
	double x = left;
	x += ph_text(ctx, h_box, x, ph_centred(head_mid, ph_style.value_big), text, ph_style.value_big, ph_style.fg, -0.3);
	ph_text(ctx, h_box, x + 5, ph_centred(head_mid, ph_style.label), "FPS", ph_style.label, ph_style.fg2, 0.5);
	if (!s->idle && s->ft_avg > 0) {
		snprintf(text, sizeof(text), "%.1f", s->ft_avg);
		double unit = ph_width("ms", ph_style.label, 0.2);
		double value = ph_width(text, ph_style.value, 0);
		double base = ph_centred(head_mid, ph_style.value);
		ph_text(ctx, h_box, right - unit - 3 - value, base, text, ph_style.value, ph_style.fg, 0);
		ph_text(ctx, h_box, right - unit, base, "ms", ph_style.label, ph_style.fg2, 0.2);
	}
	y += head + 6;

	// Frame time graph: the last ph_ring frames in one stroke of the brand gradient, amber where a
	// frame ran well over its budget. The budget is the limit's frame time, or the display's without a limit,
	// and is drawn as the line the frames should sit on.
	const double gx = left, gw = right - left, gh = 38;
	double budget = s->cap > 0 ? 1000.0 / s->cap : s->hz > 0 ? 1000.0 / s->hz : 0;
	if (ctx != NULL) {
		CGRect area = CGRectMake(gx, h_box - y - gh, gw, gh);
		CGPathRef bg = CGPathCreateWithRoundedRect(area, 4, 4, NULL);
		CGContextAddPath(ctx, bg);
		CGContextSetRGBFillColor(ctx, 1, 1, 1, 0.03);
		CGContextFillPath(ctx);
		CGPathRelease(bg);

		float frames[ph_ring];
		int n = ph_graph(frames, ph_ring);
		double top = 1000.0 / 30.0;
		for (int i = 0; i < n; i++)
			if (frames[i] * 1.15 > top)
				top = frames[i] * 1.15;
		if (budget > 0 && budget * 1.15 > top)
			top = budget * 1.15;
		if (budget > 0) {
			double ty = area.origin.y + 3 + budget / top * (gh - 6);
			CGContextSetRGBFillColor(ctx, 1, 1, 1, 0.16);
			CGContextFillRect(ctx, CGRectMake(gx + 4, ty, gw - 8, 1));
		}
		if (n > 1) {
			double px[ph_ring], py[ph_ring];
			CGMutablePathRef path = CGPathCreateMutable(), over = CGPathCreateMutable();
			for (int i = 0; i < n; i++) {
				px[i] = gx + 4 + (gw - 8) * (i + ph_ring - n) / (double)(ph_ring - 1);
				py[i] = area.origin.y + 3 + (frames[i] / top) * (gh - 6);
				if (i == 0)
					CGPathMoveToPoint(path, NULL, px[i], py[i]);
				else
					CGPathAddLineToPoint(path, NULL, px[i], py[i]);
				// A frame half again over budget: the stretch into and out of it
				if (i > 0 && budget > 0 && (frames[i] > budget * 1.5 || frames[i - 1] > budget * 1.5)) {
					CGPathMoveToPoint(over, NULL, px[i - 1], py[i - 1]);
					CGPathAddLineToPoint(over, NULL, px[i], py[i]);
				}
			}
			CGContextSetLineWidth(ctx, 1.5);
			CGContextSetLineJoin(ctx, kCGLineJoinRound);
			CGContextSetLineCap(ctx, kCGLineCapRound);
			CGContextSaveGState(ctx);
			CGContextAddPath(ctx, path);
			CGContextReplacePathWithStrokedPath(ctx);
			CGContextClip(ctx);
			ph_gradient(ctx, CGPointMake(gx, 0), CGPointMake(gx + gw, 0));
			CGContextRestoreGState(ctx);
			CGContextAddPath(ctx, over);
			CGContextSetRGBStrokeColor(ctx, PH_RGB(0xFF9F0A, 1));
			CGContextStrokePath(ctx);
			CGPathRelease(path);
			CGPathRelease(over);
		}
	}
	y += gh;
	// Kept close to the graph it describes, then a wider gap before the readings
	if (!s->idle && s->ft_min > 0) {
		if (budget > 0)
			snprintf(label_ms, sizeof(label_ms), "min %.1f · max %.1f · line %.1f ms", s->ft_min, s->ft_max, budget);
		else
			snprintf(label_ms, sizeof(label_ms), "min %.1f · max %.1f ms", s->ft_min, s->ft_max);
		ph_text(ctx, h_box, left, ph_centred(y + 4 + 9, ph_style.small), label_ms, ph_style.small, ph_style.fg3, 0);
		y += 4 + 18;
	}
	y += 6;

	// The rest, a label and a value per row, only what this Mac reports
	double scale = 0;
	const char *filter = scalefilter_state(&scale);
	struct { const char *label; char value[40]; int shown; } rows[11] = {
		{ "Frame limit", "", s->cap > 0 },
		{ "Scaling", "", filter != NULL },
		{ "CPU", "", s->cpu >= 0 },
		{ "Game CPU", "", s->game_cpu >= 0 },
		{ "GPU", "", s->gpu >= 0 },
		{ "GPU memory", "", s->gpu_mem > 0 },
		{ "Memory", "", s->ram_used > 0 && s->ram_total > 0 },
		{ "Game memory", "", s->game_mem > 0 },
		{ "Battery", "", s->battery >= 0 },
		{ "Power", "", s->watts > 0 },
		{ "Display", "", s->hz > 0 },
	};
	snprintf(rows[0].value, sizeof(rows[0].value), "%.0f FPS", s->cap);
	// The filter in use and the scale it draws at: 1.0x means nothing is scaled
	if (filter != NULL)
		snprintf(rows[1].value, sizeof(rows[1].value), "%s · %.1fx", filter, scale);
	snprintf(rows[2].value, sizeof(rows[2].value), "%d%%", s->cpu);
	snprintf(rows[3].value, sizeof(rows[3].value), "%.0f%%", s->game_cpu);
	snprintf(rows[4].value, sizeof(rows[4].value), "%d%%", s->gpu);
	ph_format_gb(rows[5].value, sizeof(rows[5].value), s->gpu_mem);
	snprintf(rows[6].value, sizeof(rows[6].value), "%.1f / %.0f GB", s->ram_used / 1073741824.0,
	         s->ram_total / 1073741824.0);
	ph_format_gb(rows[7].value, sizeof(rows[7].value), s->game_mem);
	ph_battery_text(rows[8].value, sizeof(rows[8].value), s, 1);
	snprintf(rows[9].value, sizeof(rows[9].value), "%.1f W", s->watts);
	snprintf(rows[10].value, sizeof(rows[10].value), "%d Hz", s->hz);

	for (int i = 0; i < 11; i++) {
		if (!rows[i].shown)
			continue;
		double mid = y + row / 2;
		ph_text(ctx, h_box, left, ph_centred(mid, ph_style.small), rows[i].label, ph_style.small, ph_style.fg2, 0);
		double vw = ph_width(rows[i].value, ph_style.value, 0);
		ph_text(ctx, h_box, right - vw, ph_centred(mid, ph_style.value), rows[i].value, ph_style.value, ph_style.fg, 0);
		y += row;
	}
	return CGSizeMake(w, y + bottom);
}

static CGSize ph_draw(CGContextRef ctx, const struct ph_sample *s, double h_box)
{
	switch (ph_level) {
	case ph_summary:
		return ph_draw_summary(ctx, s, h_box);
	case ph_detailed:
		return ph_draw_detailed(ctx, s, h_box);
	default:
		return ph_draw_compact(ctx, s, h_box);
	}
}

static CGImageRef ph_render(const struct ph_sample *s, double scale, CGSize *size_out)
{
	ph_style_load();
	CGSize size = ph_draw(NULL, s, 0);
	size.width = ceil(size.width);
	size.height = ceil(size.height);
	size_t pw = (size_t)ceil(size.width * scale), phh = (size_t)ceil(size.height * scale);
	CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef ctx = CGBitmapContextCreate(NULL, pw, phh, 8, 0, srgb,
	                                         kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
	CGColorSpaceRelease(srgb);
	if (ctx == NULL)
		return NULL;
	CGContextScaleCTM(ctx, scale, scale);
	CGContextSetShouldSmoothFonts(ctx, false);
	ph_surface(ctx, size.width, size.height);
	ph_draw(ctx, s, size.height);
	CGImageRef image = CGBitmapContextCreateImage(ctx);
	CGContextRelease(ctx);
	*size_out = size;
	return image;
}

// MARK: Placing

static id ph_msg(id target, const char *selector)
{
	SEL sel = sel_registerName(selector);
	if (target == nil || ![target respondsToSelector:sel])
		return nil;
	return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

// The screen the game's window is on: its backing scale, for a sharp overlay at any game
// resolution, and its refresh rate. Main thread, through the runtime: the shim does not
// link AppKit, it only finds it in the game.
static void ph_read_screen(CALayer *host)
{
	Class view_class = objc_getClass("NSView");
	id window = nil;
	for (CALayer *l = host; l != nil && view_class != Nil; l = l.superlayer) {
		id delegate = l.delegate;
		if (delegate != nil && [delegate isKindOfClass:view_class]) {
			window = ph_msg(delegate, "window");
			break;
		}
	}
	id screen = ph_msg(window, "screen");
	if (screen == nil)
		screen = ph_msg((id)objc_getClass("NSScreen"), "mainScreen");
	SEL scale_sel = sel_registerName("backingScaleFactor");
	if (screen != nil && [screen respondsToSelector:scale_sel]) {
		double scale = ((double (*)(id, SEL))objc_msgSend)(screen, scale_sel);
		if (scale >= 1 && scale <= 4)
			atomic_store(&ph_scale, scale);
	} else if (host.contentsScale >= 1) {
		atomic_store(&ph_scale, host.contentsScale);
	}
	SEL fps_sel = sel_registerName("maximumFramesPerSecond");
	if (screen != nil && [screen respondsToSelector:fps_sel]) {
		NSInteger hz = ((NSInteger (*)(id, SEL))objc_msgSend)(screen, fps_sel);
		if (hz > 0 && hz < 1000)
			atomic_store(&ph_refresh_hz, (int)hz);
	}
}

// Main queue only, unlike fg_on_main's inline fallback: AppKit and the window's layer tree
// belong to the main thread, and a busy one only delays the overlay. One update at a time,
// so a stalled main thread does not pile them up.
static _Atomic int ph_place_pending;

static void ph_place(id host, CGImageRef image, CGSize size, double scale)
{
	if (atomic_exchange(&ph_place_pending, 1)) {
		CGImageRelease(image);
		[host release]; // ph_host still holds the layer
		return;
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		ph_read_screen(host);
		fg_ca_begin();
		if (ph_layer == nil) {
			ph_layer = [[CALayer alloc] init];
			ph_layer.anchorPoint = CGPointZero;
			ph_layer.zPosition = 2000; // over framegen's covering layer (1000)
			ph_layer.contentsGravity = kCAGravityResize;
		}
		if (ph_layer.superlayer != host) {
			[ph_layer removeFromSuperlayer];
			[(CALayer *)host addSublayer:ph_layer];
			atomic_store(&ph_attached, 1);
		}
		// The host's sublayers measure y down from its top when an odd number of layers up
		// the tree flip their geometry (a flipped NSView's layer does)
		int flipped = 0;
		for (CALayer *l = host; l != nil; l = l.superlayer)
			flipped ^= l.geometryFlipped ? 1 : 0;
		CGRect bounds = ((CALayer *)host).bounds;
		const double inset = 12;
		double y = flipped ? bounds.origin.y + inset : bounds.origin.y + bounds.size.height - inset - size.height;
		ph_layer.bounds = CGRectMake(0, 0, size.width, size.height);
		ph_layer.position = CGPointMake(bounds.origin.x + inset, y);
		ph_layer.contentsScale = scale;
		// Core Animation shows CGImage contents upright in a flipped tree too
		ph_layer.contents = (id)image;
		ph_layer.hidden = atomic_load(&ph_level) == ph_off;
		fg_ca_end();
		CGImageRelease(image);
		[host release];
		atomic_store(&ph_place_pending, 0);
	});
}

static void perfhud_tick(void)
{
	double now = CACurrentMediaTime();
	struct ph_sample s = { .fps = -1, .ft_avg = -1, .ft_min = -1, .ft_max = -1, .cpu = -1, .gpu = -1,
	                       .battery = -1, .on_ac = -1, .charging = -1, .minutes_left = -1, .hz = -1,
	                       .game_cpu = -1, .ram_used = -1, .ram_total = -1, .game_mem = -1,
	                       .gpu_mem = -1, .watts = -1, .cap = -1 };

	os_unfair_lock_lock(&ph_lock);
	uint64_t frames = ph_frames;
	unsigned written = ph_written;
	double last_frame = ph_last_frame;
	id host = [ph_host retain];
	float window[ph_ring];
	unsigned fresh = written - ph_tick_written;
	if (fresh > ph_ring)
		fresh = ph_ring;
	for (unsigned i = 0; i < fresh; i++)
		window[i] = ph_intervals[(written - fresh + i) % ph_ring];
	os_unfair_lock_unlock(&ph_lock);

	if (ph_tick_time > 0 && now > ph_tick_time)
		s.fps = (double)(frames - ph_tick_frames) / (now - ph_tick_time);
	s.idle = last_frame <= 0 || now - last_frame > 2.0;
	if (fresh > 0) {
		double sum = 0, lo = 1e9, hi = 0;
		for (unsigned i = 0; i < fresh; i++) {
			sum += window[i];
			lo = window[i] < lo ? window[i] : lo;
			hi = window[i] > hi ? window[i] : hi;
		}
		s.ft_avg = sum / fresh;
		s.ft_min = lo;
		s.ft_max = hi;
	}
	ph_tick_frames = frames;
	ph_tick_time = now;
	ph_tick_written = written;
	// Turned off from the quick settings: the counts above stay current for when it comes back
	if (atomic_load(&ph_level) == ph_off) {
		[host release];
		dispatch_async(dispatch_get_main_queue(), ^{
			ph_layer.hidden = YES;
		});
		return;
	}

	s.cpu = ph_cpu_percent();
	s.game_cpu = ph_game_cpu(now);
	ph_memory(&s);
	ph_gpu(&s);
	ph_battery(&s);
	s.watts = ph_power();
	s.cap = framelimit_cap();
	s.hz = atomic_load(&ph_refresh_hz) > 0 ? atomic_load(&ph_refresh_hz) : -1;
	ph_ticks++;
	ph_last = s;

	if (host == nil)
		return;
	double scale = atomic_load(&ph_scale);
	CGSize size;
	CGImageRef image = ph_render(&s, scale, &size);
	if (image == NULL) {
		[host release];
		return;
	}
	ph_place(host, image, size, scale); // takes image and host
}

static void perfhud_start(void)
{
	dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
	                                                                     QOS_CLASS_UTILITY, 0);
	ph_queue = dispatch_queue_create("com.notproton.perfhud", attr);
	ph_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, ph_queue);
	dispatch_source_set_timer(ph_timer, dispatch_time(DISPATCH_TIME_NOW, 0), 500 * NSEC_PER_MSEC,
	                          50 * NSEC_PER_MSEC);
	dispatch_source_set_event_handler(ph_timer, ^{
		@autoreleasepool {
			perfhud_tick();
		}
	});
	dispatch_resume(ph_timer);
	shim_log("overlay_shim perfhud: first frame, overlay running (%s)\n", ph_level_names[ph_level]);
}

// Reads the setting; returns whether the overlay is on for this process.
static int perfhud_init(void)
{
	// The quick settings can turn the overlay on later, so the sampler's port is always ready
	ph_host_port = mach_host_self();
	const char *hud = getenv("MTL_HUD_ENABLED");
	ph_hud_locked = hud != NULL && hud[0] != '\0' && strcmp(hud, "0") != 0;
	const char *value = getenv("NOTPROTON_PERF_OVERLAY");
	if (value == NULL || value[0] == '\0' || strcmp(value, "0") == 0 || strcasecmp(value, "off") == 0)
		return 0;

	if (strcasecmp(value, "fps") == 0 || strcmp(value, "1") == 0)
		ph_level = ph_fps;
	else if (strcasecmp(value, "summary") == 0)
		ph_level = ph_summary;
	else if (strcasecmp(value, "detailed") == 0)
		ph_level = ph_detailed;
	else {
		shim_log("overlay_shim perfhud: BRIDGEPLAY_PERF_OVERLAY=%s not understood (fps|summary|detailed), off\n",
		         value);
		return 0;
	}

	if (ph_hud_locked) {
		shim_log("overlay_shim perfhud: the Metal HUD is on, it shows instead of the %s overlay\n",
		         ph_level_names[ph_level]);
		ph_level = ph_off;
		return 0;
	}

	shim_log("overlay_shim perfhud: %s overlay on, waiting for the game's first frame\n",
	         ph_level_names[ph_level]);
	return 1;
}

// The quick settings' level; returns 0 when the Metal HUD owns the overlay. Main thread.
static int perfhud_set_level(int level)
{
	if (ph_hud_locked || level < ph_off || level > ph_detailed)
		return 0;
	atomic_store(&ph_level, level);
	if (level == ph_off && ph_layer != nil) {
		fg_ca_begin();
		ph_layer.hidden = YES;
		fg_ca_end();
	}
	shim_log("overlay_shim perfhud: %s from the quick settings\n", ph_level_names[level]);
	return 1;
}

// Test entry: what the overlay has done so far
__attribute__((visibility("default"))) void np_perfhud_probe(int *level, int *frames, int *attached,
                                                             double *fps, int *cpu, int *gpu)
{
	if (level != NULL)
		*level = ph_level;
	if (frames != NULL) {
		os_unfair_lock_lock(&ph_lock);
		*frames = (int)ph_frames;
		os_unfair_lock_unlock(&ph_lock);
	}
	if (attached != NULL)
		*attached = atomic_load(&ph_attached);
	if (fps != NULL)
		*fps = ph_last.fps;
	if (cpu != NULL)
		*cpu = ph_last.cpu;
	if (gpu != NULL)
		*gpu = ph_last.gpu;
}
