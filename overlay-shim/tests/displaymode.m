#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/graphics/IOGraphicsTypes.h>
#import <objc/runtime.h>
#import "check.h"

// Exercise Wine's setter without changing the host display.
struct test_mode {
	size_t width, height, pixels_wide, pixels_high;
	double hz;
	uint32_t flags;
	CFStringRef encoding;
};
static struct test_mode desktop = {1512, 993, 3024, 1986, 120,
	kDisplayModeValidFlag | kDisplayModeSafeFlag | kDisplayModeDefaultFlag, CFSTR("RGB")};
// Display 3: a desktop set to 60 Hz that the game raises to 120 Hz
static struct test_mode desktop60 = {1512, 993, 3024, 1986, 60,
	kDisplayModeValidFlag | kDisplayModeSafeFlag | kDisplayModeDefaultFlag, CFSTR("RGB")};
static CGDisplayModeRef forwarded;
static CGDirectDisplayID forwarded_display;
static BOOL wine_result = YES;
#define TEST_MODE(m) ((const struct test_mode *)(m))
#define CGDisplayModeGetWidth(m) (TEST_MODE(m)->width)
#define CGDisplayModeGetHeight(m) (TEST_MODE(m)->height)
#define CGDisplayModeGetPixelWidth(m) (TEST_MODE(m)->pixels_wide)
#define CGDisplayModeGetPixelHeight(m) (TEST_MODE(m)->pixels_high)
#define CGDisplayModeGetIOFlags(m) (TEST_MODE(m)->flags)
#define CGDisplayModeGetRefreshRate(m) (TEST_MODE(m)->hz)
#define CGDisplayModeCopyPixelEncoding(m) ((CFStringRef)CFRetain(TEST_MODE(m)->encoding))
#define CGDisplayCopyDisplayMode(d) \
	((d) == 1 ? (CGDisplayModeRef)&desktop : (d) == 3 ? (CGDisplayModeRef)&desktop60 : NULL)
#define CGDisplayModeRelease(m) ((void)(m))
#define shim_log(...) fprintf(stderr, __VA_ARGS__)
#include "../displaymode.m"

@interface WineApplicationController : NSObject
- (BOOL)setMode:(CGDisplayModeRef)mode forDisplay:(CGDirectDisplayID)display;
@end
@implementation WineApplicationController
- (BOOL)setMode:(CGDisplayModeRef)mode forDisplay:(CGDirectDisplayID)display
{
	forwarded = mode;
	forwarded_display = display;
	return wine_result;
}
@end

int main(void)
{
	@autoreleasepool {
		CFArrayRef modes = shim_copy_modes(CGMainDisplayID(), NULL);
		if (modes) CFRelease(modes);
		WineApplicationController *wine = [WineApplicationController new];
		struct test_mode game = desktop;
		CGDisplayModeRef request = (CGDisplayModeRef)&game;
		game.hz = 59.94;
		game.flags &= ~kDisplayModeDefaultFlag;
		BOOL result = [wine setMode:request forDisplay:1];
		CHECK(result && forwarded == (CGDisplayModeRef)&desktop && forwarded_display == 1,
		      "a same-size 59.94 Hz mode should forward the current 120 Hz mode");
		game.hz = 0;
		wine_result = NO;
		CHECK(![wine setMode:request forDisplay:1] && forwarded == (CGDisplayModeRef)&desktop,
		      "an unspecified refresh should forward the current mode and preserve failure");
		game.hz = 75;
		[wine setMode:request forDisplay:1];
		CHECK(forwarded == request, "explicit 75 Hz");
		game.hz = 60;
		game.pixels_wide /= 2;
		CHECK(!keep_display_refresh((CGDisplayModeRef)&desktop, request), "different backing size");
		game.pixels_wide = desktop.pixels_wide;
		game.height--;
		CHECK(!keep_display_refresh((CGDisplayModeRef)&desktop, request), "different logical size");
		game.height = desktop.height;
		game.flags |= kDisplayModeInterlacedFlag;
		CHECK(!keep_display_refresh((CGDisplayModeRef)&desktop, request), "interlaced");
		game.flags &= ~kDisplayModeInterlacedFlag;
		game.encoding = CFSTR("other");
		CHECK(!keep_display_refresh((CGDisplayModeRef)&desktop, request), "different encoding");
		[wine setMode:request forDisplay:2];
		CHECK(forwarded == request && forwarded_display == 2, "unknown display");
		game.encoding = desktop.encoding;
		wine_result = YES;
		struct test_mode raised = desktop60, restore = desktop60;
		raised.hz = 120;
		[wine setMode:(CGDisplayModeRef)&raised forDisplay:3];
		CHECK(forwarded == (CGDisplayModeRef)&raised, "a raised refresh goes through");
		desktop60.hz = 120;
		[wine setMode:(CGDisplayModeRef)&restore forDisplay:3];
		CHECK(forwarded == (CGDisplayModeRef)&restore, "restoring a 60 Hz desktop goes through");
		desktop.hz = 60;
		CHECK(!keep_display_refresh((CGDisplayModeRef)&desktop, request), "60 Hz desktop");
		desktop.hz = 0;
		CHECK(keep_display_refresh((CGDisplayModeRef)&desktop, request),
		      "keep the current mode when CoreGraphics reports no fixed rate");
		game.hz = 0;
		CHECK(!keep_display_refresh((CGDisplayModeRef)&desktop, request),
		      "both modes already report no fixed rate");
	}
	puts("display refresh forwarding passed");
	return 0;
}
