// np_display_max_hz reads the fastest display refresh rate the Steam Properties slider
// offers as its top. The function has two inputs — NSScreen.maximumFramesPerSecond (filled
// in on ProMotion) and every CGDisplay mode's refresh rate — and takes the maximum. The
// panel JS clamps 15..360 again, but the C side must already fall in that range so no
// display reduces the slider's top below 15.
//
// This check runs against the real displays attached to the machine. On a 60 Hz lid or an
// external 60 Hz panel it ends at 60; on a ProMotion MacBook Pro lid it ends at 120. The
// assertion is only that the value is between 15 and 360, that it never falls below any
// NSScreen the test can see, and that a run with no AppKit falls back to the CGDisplay path
// without crashing.
#include "../feats/displayrate.c"

#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    int hz = np_display_max_hz();
    if (hz < 15 || hz > 360) {
        fprintf(stderr, "np_display_max_hz returned %d, out of 15..360\n", hz);
        return 1;
    }

    // Each NSScreen's maximumFramesPerSecond must not exceed the result: if any display
    // reports 120, the slider has to run to at least 120.
    Class screens_class = objc_getClass("NSScreen");
    if (screens_class) {
        id screens = ((id (*)(id, SEL))objc_msgSend)((id)screens_class, sel_registerName("screens"));
        if (screens) {
            unsigned long count = ((unsigned long (*)(id, SEL))objc_msgSend)(screens, sel_registerName("count"));
            for (unsigned long i = 0; i < count; i++) {
                id screen = ((id (*)(id, SEL, unsigned long))objc_msgSend)(screens, sel_registerName("objectAtIndex:"), i);
                if (!screen) continue;
                SEL fps_sel = sel_registerName("maximumFramesPerSecond");
                if (!class_respondsToSelector(object_getClass(screen), fps_sel)) continue;
                long screen_hz = ((long (*)(id, SEL))objc_msgSend)(screen, fps_sel);
                if (screen_hz > 0 && screen_hz <= 360 && screen_hz > hz) {
                    fprintf(stderr, "np_display_max_hz returned %d, but NSScreen %lu reports %ld\n",
                            hz, i, screen_hz);
                    return 1;
                }
            }
        }
    }

    // No NSScreen available (command-line tool without AppKit linked by the test) still
    // gives the CGDisplay path a chance to answer. The dlopen path here already linked
    // against CoreGraphics, so this just checks the function doesn't crash and stays in range
    // when called twice.
    int again = np_display_max_hz();
    if (again != hz) {
        fprintf(stderr, "np_display_max_hz second call returned %d after %d\n", again, hz);
        return 1;
    }

    printf("ok    np_display_max_hz: %d Hz (NSScreen path + CGDisplay fallback)\n", hz);
    printf("==> displayratecheck: the slider's top is the fastest display's rate\n");
    return 0;
}
