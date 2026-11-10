// Command-Q quits the game.
//
// Wine maps Command-Q to its Quit menu item, which only asks the game's windows to close
// (WM_CLOSE), and most games ignore that, so Command-Q did nothing. Here the game
// process's own NSApplication sendEvent: (Wine's subclass handles keys there, before
// AppKit's local monitors) catches Command-Q and ends the process. The run script sees
// the game exit and tears the Wine prefix down as it does after any exit, so nothing is
// left running. BRIDGEPLAY_COMMAND_Q=0 turns it off.
//
// The shim never links AppKit (loading it early breaks AppKit's CALayer categories, see
// interpose()), so this goes through the runtime and starts only once the game has
// brought up NSApplication itself. Included from overlay_shim.m.

#import <dispatch/dispatch.h>
#import <signal.h>

#define quit_key_code 12              // kVK_ANSI_Q
#define event_type_key_down 10        // NSEventTypeKeyDown
#define modifier_command (1UL << 20)  // NSEventModifierFlagCommand
#define modifier_others ((1UL << 17) | (1UL << 18) | (1UL << 19)) // shift, control, option

static int quit_tries;
static int quit_enabled;
static void (*next_send_event)(id, SEL, id);
static int sidebar_send_event(id event); // sidebar.m
static int sidebar_wanted(void);         // sidebar.m
static void cursor_install(void);        // cursor.m

static int quit_is_command_q(id event)
{
	if (((NSUInteger (*)(id, SEL))objc_msgSend)(event, sel_registerName("type")) != event_type_key_down)
		return 0;
	NSUInteger flags = ((NSUInteger (*)(id, SEL))objc_msgSend)(event, sel_registerName("modifierFlags"));
	if (!(flags & modifier_command) || (flags & modifier_others))
		return 0;
	return ((unsigned short (*)(id, SEL))objc_msgSend)(event, sel_registerName("keyCode")) == quit_key_code;
}

static void hook_send_event(id app, SEL selector, id event)
{
	if (event != nil && quit_enabled && quit_is_command_q(event)) {
		shim_log("overlay_shim quitkey: Command-Q, quitting pid=%d\n", getpid());
		// The run script waits on this process and kills the rest of the prefix once it ends.
		kill(getpid(), SIGKILL);
		return;
	}
	// The quick settings sidebar takes its shortcut, and the keys and clicks it is shown for
	if (event != nil && sidebar_send_event(event))
		return;
	next_send_event(app, selector, event);
}

static void quit_install(void)
{
	// The quick settings hold the game's cursor calls while they are open; counting its hides
	// starts as soon as AppKit is in, before the game has a window
	if (sidebar_wanted())
		cursor_install();
	id *app_slot = (id *)dlsym(RTLD_DEFAULT, "NSApp");
	id app = app_slot != NULL ? *app_slot : nil;

	if (objc_getClass("NSEvent") == Nil || app == nil) {
		// The game brings AppKit up on its own schedule; look again shortly, for a minute.
		if (++quit_tries < 120)
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
			               dispatch_get_main_queue(), ^{ quit_install(); });
		return;
	}

	Class app_class = object_getClass(app);
	int hooked = interpose(app_class, "sendEvent:", (IMP)hook_send_event, (IMP *)&next_send_event);
	shim_log("overlay_shim quitkey: Command-Q quits %s, quick settings %s, on %s\n",
	         !quit_enabled ? "off" : hooked ? "armed" : "failed", !sidebar_wanted() ? "off" : hooked ? "armed" : "failed",
	         class_getName(app_class));
}

static void quitkey_init(void)
{
	const char *off = getenv("BRIDGEPLAY_COMMAND_Q");
	quit_enabled = off == NULL || strcmp(off, "0") != 0;
	if (!quit_enabled && !sidebar_wanted())
		return;
	dispatch_async(dispatch_get_main_queue(), ^{ quit_install(); });
}
