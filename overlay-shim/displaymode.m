#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/graphics/IOGraphicsTypes.h>
#include <math.h>

static BOOL (*wine_set_mode)(id, SEL, CGDisplayModeRef, CGDirectDisplayID);

static bool keep_display_refresh(CGDisplayModeRef current, CGDisplayModeRef requested)
{
	if (!current || !requested)
		return false;
	double current_hz = CGDisplayModeGetRefreshRate(current);
	double requested_hz = CGDisplayModeGetRefreshRate(requested);
	// Wine reports an unspecified refresh as 60 Hz.
	bool fixed_60 = fabs(requested_hz - 60) <= 0.1;
	if (!fixed_60 && requested_hz != 0)
		return false;
	if (!(current_hz > 60.1 || (current_hz == 0 && fixed_60)))
		return false;
	if (CGDisplayModeGetWidth(current) != CGDisplayModeGetWidth(requested) ||
	    CGDisplayModeGetHeight(current) != CGDisplayModeGetHeight(requested) ||
	    CGDisplayModeGetPixelWidth(current) != CGDisplayModeGetPixelWidth(requested) ||
	    CGDisplayModeGetPixelHeight(current) != CGDisplayModeGetPixelHeight(requested))
		return false;
	// Match the mode format checks in WineCX's cocoa_app.m.
	const uint32_t format_flags = kDisplayModeValidFlag | kDisplayModeSafeFlag |
	        kDisplayModeStretchedFlag | kDisplayModeInterlacedFlag | kDisplayModeTelevisionFlag;
	if ((CGDisplayModeGetIOFlags(current) ^ CGDisplayModeGetIOFlags(requested)) & format_flags)
		return false;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	CFStringRef a = CGDisplayModeCopyPixelEncoding(current);
	CFStringRef b = CGDisplayModeCopyPixelEncoding(requested);
#pragma clang diagnostic pop
	bool same = a && b && CFEqual(a, b);
	if (a) CFRelease(a);
	if (b) CFRelease(b);
	return same;
}

static BOOL shim_set_mode(id controller, SEL cmd, CGDisplayModeRef requested, CGDirectDisplayID display)
{
	CGDisplayModeRef current = CGDisplayCopyDisplayMode(display);
	bool keep = keep_display_refresh(current, requested);
	BOOL result = wine_set_mode(controller, cmd, keep ? current : requested, display);
	if (keep && result)
		shim_log("overlay_shim display %u: kept current mode (%.2f Hz, requested %.2f Hz)\n", display,
		         CGDisplayModeGetRefreshRate(current), CGDisplayModeGetRefreshRate(requested));
	if (current)
		CGDisplayModeRelease(current);
	return result;
}

static void displaymode_install(void)
{
	Class controller = objc_lookUpClass("WineApplicationController");
	if (controller) {
		static dispatch_once_t once;
		dispatch_once(&once, ^{
			Method method = class_getInstanceMethod(controller, sel_registerName("setMode:forDisplay:"));
			if (method) {
				wine_set_mode = (typeof(wine_set_mode))method_getImplementation(method);
				method_setImplementation(method, (IMP)shim_set_mode);
			}
		});
	}
}

// Wine enumerates modes before choosing one. Its ObjC classes are registered by then.
static CFArrayRef shim_copy_modes(CGDirectDisplayID display, CFDictionaryRef options)
{
	displaymode_install();
	return CGDisplayCopyAllDisplayModes(display, options);
}
