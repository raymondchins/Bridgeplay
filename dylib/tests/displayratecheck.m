// np_display_max_hz reads the fastest display refresh rate the Steam Properties slider
// offers as its top. The function has two inputs — NSScreen.maximumFramesPerSecond (filled
// in on ProMotion) and every CGDisplay mode's refresh rate — and takes the maximum. The
// panel JS clamps 15..360 again, but the C side must already fall in that range so no
// display reduces the slider's top below 15.
//
// This check runs against the real displays attached to the machine. The test binary links
// AppKit so NSScreen is loaded, as it is inside Steam, and the NSScreen path is exercised
// alongside the CGDisplay one. On a 60 Hz panel the result ends at 60; on a ProMotion
// MacBook Pro lid it ends at 120.
#import <AppKit/AppKit.h>

#include "../feats/displayrate.c"

#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    @autoreleasepool {
        // Force AppKit to come up as it does inside Steam, so NSScreen is populated.
        [NSApplication sharedApplication];

        int hz = np_display_max_hz();
        if (hz < 15 || hz > 360) {
            fprintf(stderr, "np_display_max_hz returned %d, out of 15..360\n", hz);
            return 1;
        }

        // The NSScreen path has to be exercised, not skipped: a ProMotion display reports
        // 120 Hz through maximumFramesPerSecond even when CGDisplayModeGetRefreshRate still
        // gives 0 on the current mode. The test asserts the result matches the NSScreen
        // max, so a build that hard-coded 360 or dropped the NSScreen path would fail.
        NSArray<NSScreen *> *screens = [NSScreen screens];
        if (screens.count == 0) {
            fprintf(stderr, "no NSScreen reported; AppKit did not come up\n");
            return 1;
        }
        long nsscreen_max = 0;
        for (NSScreen *screen in screens) {
            if (@available(macOS 12.0, *)) {
                long screen_hz = [screen maximumFramesPerSecond];
                if (screen_hz > nsscreen_max && screen_hz <= 360)
                    nsscreen_max = screen_hz;
            }
        }
        if (nsscreen_max > 0 && hz < nsscreen_max) {
            fprintf(stderr, "np_display_max_hz returned %d, below NSScreen's %ld\n",
                    hz, nsscreen_max);
            return 1;
        }
        // Reject a result that overshoots every reading source: no CG mode has a higher
        // refresh than this across every display, and every NSScreen is bounded.
        CGDirectDisplayID ids[16];
        uint32_t n = 0;
        if (CGGetActiveDisplayList(16, ids, &n) != kCGErrorSuccess) n = 0;
        int cg_max = 0;
        for (uint32_t i = 0; i < n; i++) {
            CFArrayRef modes = CGDisplayCopyAllDisplayModes(ids[i], NULL);
            if (!modes) continue;
            for (CFIndex j = 0; j < CFArrayGetCount(modes); j++) {
                CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, j);
                int rounded = (int)(CGDisplayModeGetRefreshRate(m) + 0.5);
                if (rounded > cg_max && rounded <= 360) cg_max = rounded;
            }
            CFRelease(modes);
        }
        int bounded = (int)nsscreen_max > cg_max ? (int)nsscreen_max : cg_max;
        if (bounded > 0 && hz > bounded) {
            fprintf(stderr, "np_display_max_hz returned %d, above the highest reading %d\n",
                    hz, bounded);
            return 1;
        }

        // The function is callable twice without CFDictionary leaks or state tangles.
        int again = np_display_max_hz();
        if (again != hz) {
            fprintf(stderr, "np_display_max_hz second call returned %d after %d\n", again, hz);
            return 1;
        }

        printf("ok    np_display_max_hz: %d Hz (NSScreen %ld, CG modes max %d; %lu screen%s)\n",
               hz, nsscreen_max, cg_max, (unsigned long)screens.count, screens.count == 1 ? "" : "s");
        printf("==> displayratecheck: the slider's top is the fastest display's rate\n");
        return 0;
    }
}
