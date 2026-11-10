// The top of the frame rate limit slider in Steam Properties › Bridgeplay. The game's own
// display is not known until it runs, so the panel offers up to the fastest display, and
// overlay-shim clamps the limit to the display the game is on.
#include "displayrate.h"

#include <CoreGraphics/CoreGraphics.h>

int np_display_max_hz(void) {
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    int best = 0;
    if (CGGetActiveDisplayList(16, ids, &n) != kCGErrorSuccess)
        n = 0;
    for (uint32_t i = 0; i < n; i++) {
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(ids[i]);
        if (!mode)
            continue;
        // A built-in panel that does not say reports 0; ProMotion reports its top rate
        double hz = CGDisplayModeGetRefreshRate(mode);
        CGDisplayModeRelease(mode);
        int rounded = (int)(hz + 0.5);
        if (rounded > best && rounded <= 360)
            best = rounded;
    }
    return best >= 15 ? best : 60;
}
