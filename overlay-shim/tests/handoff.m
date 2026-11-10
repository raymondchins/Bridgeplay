#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import <crt_externs.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>

#import "check.h"

// The cursor handoff: while the quick settings are open the cursor is shown, the arrow and free,
// whatever the game hid, clipped, disconnected or recentred, and the game's mouse events and
// GetCursorPos stay where the game left them; closing gives the game back what it last asked
// for. The child runs with the shim in DYLD_INSERT_LIBRARIES, as a game does, so its Quartz
// calls go through the shim's interposers.
//
// The test links no AppKit: the classes the shim hooks are stand-ins defined here, as is NSApp,
// and the Quartz calls the shim makes itself go to the fakes below, so the machine's own cursor
// never moves.

static int hides; // AppKit's hide count as the stand-in keeps it
static id current;
static CGPoint cursor_at;
static int connected = 1;

@interface NSCursor : NSObject
@property(copy) NSString *name;
@end
@implementation NSCursor
+ (void)hide
{
	hides++;
}
+ (void)unhide
{
	if (hides > 0)
		hides--;
}
+ (id)currentCursor
{
	return current;
}
+ (id)arrowCursor
{
	static NSCursor *arrow;
	if (arrow == nil) {
		arrow = [NSCursor new];
		arrow.name = @"arrow";
	}
	return arrow;
}
- (void)set
{
	[current release];
	current = [self retain];
}
@end

@interface NSWindow : NSObject {
@public
	CGRect confinement;
}
- (CGRect)mouseConfinementRect;
- (void)setMouseConfinementRect:(CGRect)rect;
@end
@implementation NSWindow
- (CGRect)mouseConfinementRect
{
	return confinement;
}
- (void)setMouseConfinementRect:(CGRect)rect
{
	confinement = rect;
}
@end

@interface FakeApp : NSObject
@property(retain) NSArray *windows;
@end
@implementation FakeApp
@end

__attribute__((visibility("default"))) id NSApp;

// Wine's: GetCursorPos reads the cursor's place through it, and it keeps its own hidden flag
@interface WineApplicationController : NSObject {
@public
	BOOL cursorHidden;
}
+ (id)sharedController;
- (CGPoint)flippedMouseLocation:(CGPoint)point;
@end
@implementation WineApplicationController
+ (id)sharedController
{
	static WineApplicationController *shared;
	if (shared == nil)
		shared = [WineApplicationController new];
	return shared;
}
- (CGPoint)flippedMouseLocation:(CGPoint)point
{
	(void)point;
	return cursor_at;
}
@end

static int tapped, tap_warps;
static BOOL tap_clipping;
@interface WineEventTapClipCursorHandler : NSObject
- (CGEventRef)eventTapWithProxy:(CGEventTapProxy)proxy type:(CGEventType)type event:(CGEventRef)event;
- (BOOL)warpCursorTo:(CGPoint *)to from:(const CGPoint *)from;
- (BOOL)clippingCursor;
@end
@implementation WineEventTapClipCursorHandler
// Wine records each warp here and takes it out of the next event's deltas
- (BOOL)warpCursorTo:(CGPoint *)to from:(const CGPoint *)from
{
	(void)from;
	tap_warps++;
	return CGWarpMouseCursorPosition(*to) == kCGErrorSuccess;
}
- (BOOL)clippingCursor
{
	return tap_clipping;
}
- (CGEventRef)eventTapWithProxy:(CGEventTapProxy)proxy type:(CGEventType)type event:(CGEventRef)event
{
	(void)proxy;
	(void)type;
	tapped++;
	return event;
}
@end

static CGError fake_warp(CGPoint p)
{
	cursor_at = p;
	return kCGErrorSuccess;
}

static CGError fake_associate(boolean_t on)
{
	connected = on != 0;
	return kCGErrorSuccess;
}

static CGPoint fake_location(void)
{
	return cursor_at;
}

@interface FakeEvent : NSObject
@property NSUInteger type, modifierFlags;
@property unsigned short keyCode;
@property BOOL isARepeat;
@end
@implementation FakeEvent
- (id)window
{
	return nil;
}
@end

static id event(NSUInteger type, unsigned short code, NSUInteger flags)
{
	FakeEvent *e = [[FakeEvent new] autorelease];
	e.type = type;
	e.keyCode = code;
	e.modifierFlags = flags;
	return e;
}

#define CMD (1UL << 20)
#define OPT (1UL << 19)
#define KEY_P 35
#define KEY_ESCAPE 53

typedef int (*event_fn)(id);
typedef void (*fakes_fn)(CGError (*)(CGPoint), CGError (*)(boolean_t), CGPoint (*)(void));

static void present(CAMetalLayer *layer, id<MTLCommandQueue> queue, int frames)
{
	for (int i = 0; i < frames; i++) {
		@autoreleasepool {
			id<CAMetalDrawable> drawable = [layer nextDrawable];
			id<MTLCommandBuffer> buffer = [queue commandBuffer];
			[buffer presentDrawable:drawable];
			[buffer commit];
			[buffer waitUntilCompleted];
		}
	}
}

static NSString *cursor_name(void)
{
	return [current name] ?: @"none";
}

typedef void (*install_fn)(void);

static int child(const char *path, const char *mode)
{
	int by_hand = strcmp(mode, "by-hand") == 0;
	void *shim = dlopen(path, RTLD_NOW | (by_hand ? 0 : RTLD_NOLOAD));
	CHECK(shim != NULL, "%s is not loaded %s", path, by_hand ? "by hand" : "through DYLD_INSERT_LIBRARIES");
	// What lsteamclient does where dyld drops the insert list (FEX's hardened loader)
	if (by_hand) {
		install_fn install = (install_fn)dlsym(shim, "np_overlay_shim_install");
		CHECK(install != NULL, "%s exports no np_overlay_shim_install", path);
		install();
	}
	event_fn send = (event_fn)dlsym(shim, "np_quick_settings_event");
	fakes_fn fakes = (fakes_fn)dlsym(shim, "np_quick_settings_cursor_fakes");
	CHECK(send != NULL && fakes != NULL, "%s exports no np_quick_settings_cursor_fakes", path);
	fakes(fake_warp, fake_associate, fake_location);

	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	SKIP_IF(device == nil, "no Metal device on this machine");
	id<MTLCommandQueue> queue = [device newCommandQueue];
	CAMetalLayer *layer = [CAMetalLayer layer];
	layer.device = device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.bounds = CGRectMake(0, 0, 128, 72);
	layer.drawableSize = CGSizeMake(64, 36);
	present(layer, queue, 3);

	NSWindow *window = [NSWindow new];
	FakeApp *app = [FakeApp new];
	app.windows = @[ window ];
	NSApp = app;
	NSCursor *blank = [NSCursor new];
	blank.name = @"blank";
	NSCursor *crosshair = [NSCursor new];
	crosshair.name = @"crosshair";
	WineApplicationController *wine = [WineApplicationController sharedController];
	cursor_at = CGPointMake(300, 200);
	[blank set];

	// Wine hid the cursor before the hooks went in (they wait for NSApp): its own flag says so
	[NSCursor hide];
	wine->cursorHidden = YES;
	CHECK(send(event(10, KEY_P, CMD | OPT)), "Option-Command-P did not open the quick settings");
	CHECK(hides == 0, "a cursor Wine hid before the hooks went in stayed hidden (count %d)", hides);
	CHECK(send(event(10, KEY_ESCAPE, 0)), "Escape did not close the quick settings");
	CHECK(hides == 1, "closing did not hide again the cursor Wine hid early (count %d)", hides);
	[NSCursor unhide];
	wine->cursorHidden = NO;
	CHECK(hides == 0, "Wine's unhide did not go through once the quick settings closed");

	// Opening once more over a free cursor leaves it as it is
	CHECK(send(event(10, KEY_P, CMD | OPT)), "Option-Command-P did not open the quick settings");
	CHECK(send(event(10, KEY_ESCAPE, 0)), "Escape did not close the quick settings");
	CHECK(hides == 0 && [cursor_name() isEqualToString:@"blank"] && connected,
	      "opening and closing over a free cursor changed it: hides %d, %s, connected %d", hides,
	      cursor_name().UTF8String, connected);

	// A game in mouse look: the cursor hidden, clipped to its window, disconnected, recentred
	CGRect clip = CGRectMake(100, 100, 400, 300);
	[NSCursor hide];
	[window setMouseConfinementRect:clip];
	CGAssociateMouseAndMouseCursorPosition(false);
	CGWarpMouseCursorPosition(CGPointMake(300, 250));
	CHECK(hides == 1 && !connected && CGRectEqualToRect(window->confinement, clip) && cursor_at.y == 250,
	      "the game's grab did not go through with the quick settings closed");

	CHECK(send(event(10, KEY_P, CMD | OPT)), "Option-Command-P did not open the quick settings over mouse look");
	CHECK(hides == 0, "the cursor stayed hidden under the quick settings (count %d)", hides);
	CHECK([cursor_name() isEqualToString:@"arrow"], "the quick settings showed %s, not the arrow",
	      cursor_name().UTF8String);
	CHECK(connected, "the mouse stayed disconnected from the cursor under the quick settings");
	CHECK(CGRectIsEmpty(window->confinement), "the game's clip stayed on under the quick settings");

	// Wine's clipping event tap moving the cursor keeps no record of a move not made
	WineEventTapClipCursorHandler *tap = [WineEventTapClipCursorHandler new];
	CGPoint tap_to = CGPointMake(305, 255);
	CHECK([tap warpCursorTo:&tap_to from:NULL] && tap_warps == 0, "Wine's event tap recorded a warp under the quick settings");
	CGPoint held = [wine flippedMouseLocation:CGPointZero];
	CHECK(held.x == 305 && held.y == 255, "GetCursorPos did not follow the event tap's move: %.0f,%.0f", held.x, held.y);

	// The game keeps asking each frame; none of it reaches the cursor
	[NSCursor unhide];
	[NSCursor hide];
	[crosshair set];
	CGAssociateMouseAndMouseCursorPosition(false);
	CGRect clip2 = CGRectMake(120, 110, 380, 280);
	[window setMouseConfinementRect:clip2];
	CGWarpMouseCursorPosition(CGPointMake(310, 260));
	CHECK(hides == 0 && [cursor_name() isEqualToString:@"arrow"] && connected &&
	              CGRectIsEmpty(window->confinement) && cursor_at.x == 300 && cursor_at.y == 250,
	      "the game took the cursor back under the quick settings: hides %d, %s, connected %d, at %.0f,%.0f", hides,
	      cursor_name().UTF8String, connected, cursor_at.x, cursor_at.y);

	// The player moves the cursor to the panel; GetCursorPos still answers the game's place
	cursor_at = CGPointMake(560, 140);
	CGPoint seen = [wine flippedMouseLocation:CGPointZero];
	CHECK(seen.x == 310 && seen.y == 260, "GetCursorPos followed the cursor under the quick settings: %.0f,%.0f",
	      seen.x, seen.y);
	[tap eventTapWithProxy:NULL type:kCGEventMouseMoved event:NULL];
	CHECK(tapped == 0, "Wine's clipping event tap moved the cursor under the quick settings");

	// Mouse input stays out of the game: movement, presses, drags and the wheel. A release still
	// reaches it (Wine drops one it saw no press for), and so do keys and modifiers released.
	const NSUInteger taken[] = { 5, 1, 3, 25, 6, 7, 27, 22, 17 };
	for (size_t i = 0; i < sizeof(taken) / sizeof(taken[0]); i++)
		CHECK(send(event(taken[i], 0, 0)), "a mouse event of type %lu reached the game under the quick settings",
		      (unsigned long)taken[i]);
	CHECK(!send(event(2, 0, 0)), "a left button release did not reach the game");
	CHECK(!send(event(4, 0, 0)), "a right button release did not reach the game");

	// The shortcut closes them again: the game gets back what it asked for last
	CHECK(send(event(10, KEY_P, CMD | OPT)), "Option-Command-P did not close the quick settings");
	CHECK(hides == 1, "the cursor was not hidden again on closing (count %d)", hides);
	CHECK([cursor_name() isEqualToString:@"crosshair"], "closing set %s, not the game's last cursor",
	      cursor_name().UTF8String);
	CHECK(!connected, "closing left the mouse connected to the cursor");
	CHECK(CGRectEqualToRect(window->confinement, clip2), "closing did not put the game's last clip back");
	CHECK(cursor_at.x == 310 && cursor_at.y == 260, "closing left the cursor at %.0f,%.0f, not where the game put it",
	      cursor_at.x, cursor_at.y);
	seen = [wine flippedMouseLocation:CGPointZero];
	CHECK(seen.x == 310 && seen.y == 260, "GetCursorPos stayed held after closing");
	[tap eventTapWithProxy:NULL type:kCGEventMouseMoved event:NULL];
	CHECK(tapped == 1, "Wine's clipping event tap stayed off after closing");
	CHECK(!send(event(5, 0, 0)), "mouse movement did not reach the game after closing");

	// The game lets go while they are open: it gets a free, shown cursor back where the player left it
	CHECK(send(event(10, KEY_P, CMD | OPT)), "Option-Command-P did not open the quick settings a third time");
	[NSCursor unhide];
	[window setMouseConfinementRect:CGRectZero];
	CGAssociateMouseAndMouseCursorPosition(true);
	cursor_at = CGPointMake(580, 120);
	CHECK(send(event(10, KEY_ESCAPE, 0)), "Escape did not close the quick settings");
	CHECK(hides == 0 && connected && CGRectIsEmpty(window->confinement),
	      "a game that let go got its grab back: hides %d, connected %d", hides, connected);
	CHECK(cursor_at.x == 580 && cursor_at.y == 120, "a free cursor was moved to %.0f,%.0f on closing", cursor_at.x,
	      cursor_at.y);

	// With Wine's clipping event tap on (UseConfinementCursorClipping=n), the move back goes
	// through the tap, which keeps a record of it for the next event's deltas
	tap_clipping = YES;
	CGAssociateMouseAndMouseCursorPosition(false);
	CHECK(send(event(10, KEY_P, CMD | OPT)), "Option-Command-P did not open the quick settings over the event tap");
	CHECK(connected, "the event tap's disconnected mouse stayed disconnected under the quick settings");
	CGWarpMouseCursorPosition(CGPointMake(400, 300));
	cursor_at = CGPointMake(600, 100);
	int warps_before = tap_warps;
	CHECK(send(event(10, KEY_ESCAPE, 0)), "Escape did not close the quick settings over the event tap");
	CHECK(tap_warps == warps_before + 1, "the move back did not go through Wine's event tap (%d warps)",
	      tap_warps - warps_before);
	CHECK(cursor_at.x == 400 && cursor_at.y == 300 && !connected,
	      "closing over the event tap left the cursor at %.0f,%.0f, connected %d", cursor_at.x, cursor_at.y, connected);
	tap_clipping = NO;

	printf("%-8s hidden, clipped, disconnected and recentred cursor freed under the quick settings and given back\n",
	       mode);
	return 0;
}

static int spawn_child(const char *self, const char *path, const char *mode);

int main(int argc, char **argv)
{
	const char *path = getenv("NOTPROTON_OVERLAY_SHIM");
	(void)argc;
	SKIP_IF(path == NULL, "NOTPROTON_OVERLAY_SHIM names the shim to load");
	if (getenv("NP_HANDOFF_CHILD") != NULL)
		return child(path, getenv("NP_HANDOFF_CHILD"));

	int rc = spawn_child(argv[0], path, "inserted");
	if (rc == 0)
		rc = spawn_child(argv[0], path, "by-hand");
	return rc;
}

static int spawn_child(const char *self, const char *path, const char *mode)
{
	char **parent = *_NSGetEnviron();
	int n = 0;
	while (parent[n] != NULL)
		n++;
	// The quick settings note in the home folder that they were opened; not in the real one
	char tmpl[] = "/tmp/np-handoff-XXXXXX";
	char *home = mkdtemp(tmpl);
	CHECK(home != NULL, "no temporary home");
	char **env = calloc((size_t)n + 5, sizeof(char *));
	int k = 0;
	for (int i = 0; i < n; i++)
		if (strncmp(parent[i], "DYLD_", 5) != 0 && strncmp(parent[i], "HOME=", 5) != 0 &&
		    strncmp(parent[i], "BRIDGEPLAY_QUICK_SETTINGS=", 26) != 0 &&
		    strncmp(parent[i], "NOTPROTON_QUICK_SETTINGS=", 25) != 0)
			env[k++] = parent[i];
	char insert[1100], home_var[1100], mode_var[64];
	snprintf(insert, sizeof(insert), "DYLD_INSERT_LIBRARIES=%s", path);
	snprintf(home_var, sizeof(home_var), "HOME=%s", home);
	snprintf(mode_var, sizeof(mode_var), "NP_HANDOFF_CHILD=%s", mode);
	if (strcmp(mode, "inserted") == 0)
		env[k++] = insert;
	env[k++] = home_var;
	env[k++] = mode_var;
	env[k] = NULL;

	pid_t pid;
	char *args[] = { (char *)self, NULL };
	int rc = posix_spawn(&pid, self, NULL, NULL, args, env);
	free(env);
	CHECK(rc == 0, "spawning %s failed", self);
	int status = 0;
	CHECK(waitpid(pid, &status, 0) == pid, "waiting for the child failed");
	char cleanup[1100];
	snprintf(cleanup, sizeof(cleanup), "rm -rf '%s'", home);
	system(cleanup);
	CHECK(WIFEXITED(status), "the child crashed");
	return WEXITSTATUS(status);
}
