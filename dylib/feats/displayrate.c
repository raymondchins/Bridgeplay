// The top of the frame rate limit slider in Steam Properties › Bridgeplay. The game's own
// display is not known until it runs, so the panel offers up to the fastest display, and
// overlay-shim clamps the limit to the display the game is on.
#include "displayrate.h"

#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <objc/message.h>
#include <objc/objc.h>
#include <objc/runtime.h>

// NSScreen.maximumFramesPerSecond is the one API Apple fills in for ProMotion: 120 on an
// M-series MacBook Pro built-in panel. Steam links AppKit, so the class is in the process;
// the test harness without AppKit returns 0 and leaves the CGDisplay path to decide.
static int np_display_hz_via_nsscreen(void) {
    Class screens_class = objc_getClass("NSScreen");
    if (!screens_class)
        return 0;
    SEL screens_sel = sel_registerName("screens");
    if (!class_respondsToSelector(object_getClass((id)screens_class), screens_sel))
        return 0;
    id screens = ((id (*)(id, SEL))objc_msgSend)((id)screens_class, screens_sel);
    if (!screens)
        return 0;
    SEL count_sel = sel_registerName("count");
    SEL at_sel = sel_registerName("objectAtIndex:");
    SEL fps_sel = sel_registerName("maximumFramesPerSecond");
    unsigned long count = ((unsigned long (*)(id, SEL))objc_msgSend)(screens, count_sel);
    int best = 0;
    for (unsigned long i = 0; i < count; i++) {
        id screen = ((id (*)(id, SEL, unsigned long))objc_msgSend)(screens, at_sel, i);
        if (!screen || !class_respondsToSelector(object_getClass(screen), fps_sel))
            continue;
        long hz = ((long (*)(id, SEL))objc_msgSend)(screen, fps_sel);
        if (hz > best && hz <= 360)
            best = (int)hz;
    }
    return best;
}

// CGDisplayCopyDisplayMode's current mode sometimes reports 0 Hz on a built-in ProMotion
// panel. Iterate every mode the display offers instead so a 120 Hz mode in the list is
// found. kCGDisplayShowDuplicateLowResolutionModes brings in the full set on macOS.
static int np_display_hz_via_cg(void) {
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    if (CGGetActiveDisplayList(16, ids, &n) != kCGErrorSuccess)
        return 0;
    int best = 0;
    const void *keys[1] = { kCGDisplayShowDuplicateLowResolutionModes };
    const void *values[1] = { kCFBooleanTrue };
    CFDictionaryRef options = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
                                                 &kCFTypeDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
    for (uint32_t i = 0; i < n; i++) {
        CFArrayRef modes = CGDisplayCopyAllDisplayModes(ids[i], options);
        if (modes) {
            CFIndex cnt = CFArrayGetCount(modes);
            for (CFIndex j = 0; j < cnt; j++) {
                CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, j);
                double hz = CGDisplayModeGetRefreshRate(m);
                int rounded = (int)(hz + 0.5);
                if (rounded > best && rounded <= 360)
                    best = rounded;
            }
            CFRelease(modes);
        }
        // Single-mode displays (some virtual ones) report nothing through the array.
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(ids[i]);
        if (mode) {
            double hz = CGDisplayModeGetRefreshRate(mode);
            int rounded = (int)(hz + 0.5);
            if (rounded > best && rounded <= 360)
                best = rounded;
            CGDisplayModeRelease(mode);
        }
    }
    if (options)
        CFRelease(options);
    return best;
}

int np_display_max_hz(void) {
    int best = np_display_hz_via_nsscreen();
    int cg = np_display_hz_via_cg();
    if (cg > best)
        best = cg;
    return best >= 15 ? best : 60;
}
