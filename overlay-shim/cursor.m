// The mouse, handed to the quick settings while they are open and back to the game after.
// Included by overlay_shim.m before sidebar.m.
//
// A game that looks around with the mouse hides the cursor and holds it in place. Wine's Mac
// driver does that for it on the main thread with AppKit and Quartz calls
// (dlls/winemac.drv/cocoa_app.m and cocoa_cursorclipping.m):
//
//   ShowCursor(FALSE), SetCursor(NULL)  +[NSCursor hide]; a cursor image goes to -[NSCursor set]
//   ClipCursor                          -[NSWindow setMouseConfinementRect:], or, with
//                                       UseConfinementCursorClipping=n, an event tap and
//                                       CGAssociateMouseAndMouseCursorPosition(false)
//   SetCursorPos (recentring each frame) CGWarpMouseCursorPosition
//   GetCursorPos                        -[WineApplicationController flippedMouseLocation:]
//
// SDL does the same for native games with +[NSCursor hide], CGAssociateMouseAndMouseCursorPosition
// and CGWarpMouseCursorPosition. So the quick settings opened over such a game had no cursor, or
// one the game kept pulling back to the middle of its window.
//
// While they are open, each of those calls is noted and not done: the cursor shows as the arrow
// and moves freely, and GetCursorPos keeps answering where the game last put it. Closing does
// what the game asked for last, so it gets its cursor back as it would have had it without the
// quick settings. The mouse events themselves stay out of the game in sidebar_send_event, which
// keeps them from Wine's window messages and its raw input alike.

#import <CoreGraphics/CoreGraphics.h>

static void (*ch_next_hide)(id, SEL);
static void (*ch_next_unhide)(id, SEL);
static void (*ch_next_set)(id, SEL);
static void (*ch_next_confine)(id, SEL, CGRect);
static CGPoint (*ch_next_flipped)(id, SEL, CGPoint);
static CGEventRef (*ch_next_tap)(id, SEL, CGEventTapProxy, CGEventType, CGEventRef);
static BOOL (*ch_next_tap_warp)(id, SEL, CGPoint *, const CGPoint *);

static CGPoint ch_location(void)
{
	CGEventRef event = CGEventCreate(NULL);
	CGPoint at = event != NULL ? CGEventGetLocation(event) : CGPointZero;
	if (event != NULL)
		CFRelease(event);
	return at;
}

// The Quartz calls the game's are held from; a test puts its own in their place
static CGError (*ch_real_warp)(CGPoint) = CGWarpMouseCursorPosition;
static CGError (*ch_real_associate)(boolean_t) = CGAssociateMouseAndMouseCursorPosition;
static CGPoint (*ch_real_location)(void) = ch_location;

// ch_taken changes under ch_lock, and the Quartz calls check it and act under it too, so a call
// from another thread lands wholly before taking or after giving back
static _Atomic int ch_taken;
static _Atomic int ch_associated = 1; // as the game last asked
static os_unfair_lock ch_lock = OS_UNFAIR_LOCK_INIT;
static CGPoint ch_game_at; // where the game has the cursor while taken, under ch_lock
static int ch_game_warped;
// Set on the thread giving the cursor back while it holds ch_lock: Wine's event tap warps
// through the interposed call then, which must not take the lock again
static __thread int ch_restoring;

// A move the game makes while taken: noted, not done
static int ch_hold_warp(CGPoint point)
{
	os_unfair_lock_lock(&ch_lock);
	int taken = atomic_load(&ch_taken);
	if (taken) {
		ch_game_at = point;
		ch_game_warped = 1;
	}
	os_unfair_lock_unlock(&ch_lock);
	return taken;
}

// Main thread only
static int ch_installed;
static int ch_hides;  // the game's hides less its unhides: AppKit's count as the game left it
static int ch_unhid;  // the unhides done on taking it
static id ch_cursor_then, ch_cursor_wanted; // retained
#define ch_max_windows 8
static struct {
	id window; // retained while taken
	CGRect rect;
} ch_confined[ch_max_windows];
static int ch_n_confined;

static void ch_hide(id cls, SEL sel)
{
	ch_hides++;
	if (!atomic_load(&ch_taken))
		ch_next_hide(cls, sel);
}

static void ch_unhide(id cls, SEL sel)
{
	// AppKit does not count below shown
	if (ch_hides > 0)
		ch_hides--;
	if (!atomic_load(&ch_taken))
		ch_next_unhide(cls, sel);
}

static void ch_set(id cursor, SEL sel)
{
	if (!atomic_load(&ch_taken)) {
		ch_next_set(cursor, sel);
		return;
	}
	if (cursor != ch_cursor_wanted) {
		[cursor retain];
		[ch_cursor_wanted release];
		ch_cursor_wanted = cursor;
	}
}

static void ch_remember_confinement(id window, CGRect rect)
{
	for (int i = 0; i < ch_n_confined; i++)
		if (ch_confined[i].window == window) {
			ch_confined[i].rect = rect;
			return;
		}
	if (ch_n_confined == ch_max_windows) {
		shim_log("overlay_shim cursor: more than %d windows clip the cursor, one is let go\n", ch_max_windows);
		return;
	}
	ch_confined[ch_n_confined].window = [window retain];
	ch_confined[ch_n_confined].rect = rect;
	ch_n_confined++;
}

static void ch_confine(id window, SEL sel, CGRect rect)
{
	if (!atomic_load(&ch_taken))
		ch_next_confine(window, sel, rect);
	else
		ch_remember_confinement(window, rect);
}

static CGPoint ch_flipped(id controller, SEL sel, CGPoint point)
{
	if (!atomic_load(&ch_taken))
		return ch_next_flipped(controller, sel, point);
	os_unfair_lock_lock(&ch_lock);
	CGPoint at = ch_game_at;
	os_unfair_lock_unlock(&ch_lock);
	return at;
}

// Wine's clipping event tap handler, as last seen: Wine makes one and keeps it, so it is not retained
static _Atomic(id) ch_tap_handler;

// Wine's clipping event tap moves the cursor itself and rewrites each event's place
static CGEventRef ch_tap(id handler, SEL sel, CGEventTapProxy proxy, CGEventType type, CGEventRef event)
{
	atomic_store(&ch_tap_handler, handler);
	if (atomic_load(&ch_taken) && type != kCGEventTapDisabledByTimeout && type != kCGEventTapDisabledByUserInput)
		return event;
	return ch_next_tap(handler, sel, proxy, type, event);
}

// Wine's clipping event tap moves the cursor through here and keeps a record of each move, which
// it takes out of the next event's deltas: a move that is not made must leave no record
static BOOL ch_tap_warp(id handler, SEL sel, CGPoint *to, const CGPoint *from)
{
	atomic_store(&ch_tap_handler, handler);
	if (to != NULL && ch_hold_warp(*to))
		return YES;
	return ch_next_tap_warp(handler, sel, to, from);
}

// Interposed: the shim comes in through DYLD_INSERT_LIBRARIES, so dyld binds every other image's
// calls here, Wine's driver loaded later included. The shim's own calls reach Quartz.
static CGError ch_warp(CGPoint point)
{
	if (ch_restoring)
		return ch_real_warp(point);
	os_unfair_lock_lock(&ch_lock);
	CGError err = kCGErrorSuccess;
	if (!atomic_load(&ch_taken)) {
		err = ch_real_warp(point);
	} else {
		ch_game_at = point;
		ch_game_warped = 1;
	}
	os_unfair_lock_unlock(&ch_lock);
	return err;
}

static CGError ch_associate(boolean_t connected)
{
	if (ch_restoring)
		return ch_real_associate(connected);
	os_unfair_lock_lock(&ch_lock);
	CGError err = atomic_load(&ch_taken) ? kCGErrorSuccess : ch_real_associate(connected);
	if (err == kCGErrorSuccess)
		atomic_store(&ch_associated, connected != 0);
	os_unfair_lock_unlock(&ch_lock);
	return err;
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
	const void *replacement;
	const void *original;
} cursor_interposes[] = {
	{ (const void *)ch_warp, (const void *)CGWarpMouseCursorPosition },
	{ (const void *)ch_associate, (const void *)CGAssociateMouseAndMouseCursorPosition },
};

static id ch_send(id target, const char *selector)
{
	return target != nil ? ((id (*)(id, SEL))objc_msgSend)(target, sel_registerName(selector)) : nil;
}

// Once AppKit is up, on the main thread. The hooks pass every call through until the quick
// settings take the mouse; hides are counted from here on, so this runs before a game is up.
static void cursor_install(void)
{
	Class cursor = objc_getClass("NSCursor");
	if (ch_installed || cursor == Nil)
		return;
	ch_installed = 1;
	Class meta = object_getClass((id)cursor);
	int hooked = interpose(meta, "hide", (IMP)ch_hide, (IMP *)&ch_next_hide);
	hooked += interpose(meta, "unhide", (IMP)ch_unhide, (IMP *)&ch_next_unhide);
	hooked += interpose(cursor, "set", (IMP)ch_set, (IMP *)&ch_next_set);
	int confine = interpose(objc_getClass("NSWindow"), "setMouseConfinementRect:", (IMP)ch_confine,
	                        (IMP *)&ch_next_confine);
	int wine = interpose(objc_getClass("WineApplicationController"), "flippedMouseLocation:", (IMP)ch_flipped,
	                     (IMP *)&ch_next_flipped);
	Class tap_class = objc_getClass("WineEventTapClipCursorHandler");
	int tap = interpose(tap_class, "eventTapWithProxy:type:event:", (IMP)ch_tap, (IMP *)&ch_next_tap);
	tap += interpose(tap_class, "warpCursorTo:from:", (IMP)ch_tap_warp, (IMP *)&ch_next_tap_warp);
	shim_log("overlay_shim cursor: hooks cursor=%d/3 confinement=%d wine=%d tap=%d/2\n", hooked, confine, wine, tap);
}

// Wine's own flag, for a hide made before the hooks went in: they wait for NSApp, on a main-queue
// pass that can come after Wine's first window. Wine hides once, however often it is asked.
static int ch_wine_hidden(void)
{
	Class wine = objc_getClass("WineApplicationController");
	Ivar flag = wine != Nil ? class_getInstanceVariable(wine, "cursorHidden") : NULL;
	const char *type = flag != NULL ? ivar_getTypeEncoding(flag) : NULL;
	if (type == NULL || (strcmp(type, "c") != 0 && strcmp(type, "B") != 0))
		return 0;
	id controller = ch_send((id)wine, "sharedController");
	return controller != nil && *((const char *)controller + ivar_getOffset(flag)) != 0;
}

// The game's clip on each window that has one is noted and let go
static void ch_release_confinement(void)
{
	if (ch_next_confine == NULL)
		return;
	id *slot = (id *)dlsym(RTLD_DEFAULT, "NSApp");
	NSArray *windows = ch_send(slot != NULL ? *slot : nil, "windows");
	SEL get = sel_registerName("mouseConfinementRect"), set = sel_registerName("setMouseConfinementRect:");
	for (id window in windows) {
		Method method = class_getInstanceMethod(object_getClass(window), get);
		if (method == NULL)
			continue;
		CGRect rect = ((CGRect (*)(id, SEL))method_getImplementation(method))(window, get);
		if (CGRectIsEmpty(rect))
			continue;
		ch_remember_confinement(window, rect);
		ch_next_confine(window, set, CGRectZero);
	}
}

// The quick settings take the mouse: the arrow, shown, free to move. Main thread.
static void cursor_take(void)
{
	if (atomic_load(&ch_taken))
		return;
	cursor_install();
	Class cursor = objc_getClass("NSCursor");
	os_unfair_lock_lock(&ch_lock);
	CGPoint at = ch_real_location();
	ch_game_at = at;
	ch_game_warped = 0;
	atomic_store(&ch_taken, 1);
	os_unfair_lock_unlock(&ch_lock);
	if (ch_hides == 0 && ch_wine_hidden()) {
		shim_log("overlay_shim cursor: Wine hid the cursor before the hooks were in\n");
		ch_hides = 1;
	}

	ch_release_confinement();
	if (!atomic_load(&ch_associated))
		ch_real_associate(true);
	ch_unhid = 0;
	if (ch_next_unhide != NULL)
		for (; ch_unhid < ch_hides; ch_unhid++)
			ch_next_unhide((id)cursor, sel_registerName("unhide"));
	if (ch_next_set != NULL) {
		ch_cursor_then = [ch_send((id)cursor, "currentCursor") retain];
		id arrow = ch_send((id)cursor, "arrowCursor");
		if (arrow != nil)
			ch_next_set(arrow, sel_registerName("set"));
	}
	shim_log("overlay_shim cursor: taken, game had it hidden=%d connected=%d clipped=%d at %.0f,%.0f\n", ch_unhid,
	         atomic_load(&ch_associated), ch_n_confined, at.x, at.y);
}

// Back to the game, as it last asked for it while the quick settings were open. Main thread.
static void cursor_give_back(void)
{
	if (!atomic_load(&ch_taken))
		return;
	Class cursor = objc_getClass("NSCursor");

	// Hidden first, so the cursor is not seen jumping back
	if (ch_next_hide != NULL)
		for (int i = 0; i < ch_hides; i++)
			ch_next_hide((id)cursor, sel_registerName("hide"));
	id wanted = ch_cursor_wanted != nil ? ch_cursor_wanted : ch_cursor_then;
	if (wanted != nil && ch_next_set != NULL)
		ch_next_set(wanted, sel_registerName("set"));
	[ch_cursor_wanted release];
	[ch_cursor_then release];
	ch_cursor_wanted = ch_cursor_then = nil;

	int clipped = 0;
	for (int i = 0; i < ch_n_confined; i++)
		clipped |= !CGRectIsEmpty(ch_confined[i].rect);
	if (ch_next_confine != NULL)
		for (int i = 0; i < ch_n_confined; i++)
			ch_next_confine(ch_confined[i].window, sel_registerName("setMouseConfinementRect:"), ch_confined[i].rect);
	for (int i = 0; i < ch_n_confined; i++)
		[ch_confined[i].window release];

	// Back where the game holds the cursor or last put it; a cursor it leaves free stays where it is.
	// Under the lock, so a Quartz call from another thread comes wholly before or after.
	os_unfair_lock_lock(&ch_lock);
	CGPoint at = ch_game_at;
	int connected = atomic_load(&ch_associated);
	int held = ch_hides > 0 || !connected || clipped || ch_game_warped;
	id tap = atomic_load(&ch_tap_handler);
	SEL clipping = sel_registerName("clippingCursor");
	if (!held || tap == nil || ch_next_tap_warp == NULL || ![tap respondsToSelector:clipping] ||
	    !((BOOL (*)(id, SEL))objc_msgSend)(tap, clipping))
		tap = nil;
	atomic_store(&ch_taken, 0);
	if (held && tap != nil) {
		// Wine's clipping event tap takes each warp out of the next event's deltas, so this one goes
		// through it, reading the cursor's real place now that it is no longer held
		ch_restoring = 1;
		ch_next_tap_warp(tap, sel_registerName("warpCursorTo:from:"), &at, NULL);
		ch_restoring = 0;
	} else if (held) {
		ch_real_warp(at);
	}
	// Also after a warp, which holds the mouse still for a moment unless it is connected again
	// (Wine's setCursorPosition: does the same)
	if (held)
		ch_real_associate(connected);
	os_unfair_lock_unlock(&ch_lock);
	shim_log("overlay_shim cursor: given back, hidden=%d connected=%d clipped=%d%s\n", ch_hides, connected, clipped,
	         held ? ", back where the game holds it" : "");
	ch_n_confined = 0;
}

// Test entry: the Quartz calls replaced, so a test does not move the machine's own cursor
__attribute__((visibility("default"))) void np_quick_settings_cursor_fakes(CGError (*warp)(CGPoint),
                                                                          CGError (*associate)(boolean_t),
                                                                          CGPoint (*location)(void))
{
	ch_real_warp = warp;
	ch_real_associate = associate;
	ch_real_location = location;
}
