// Frame rate limit: NOTPROTON_FPS_LIMIT (BRIDGEPLAY_FPS_LIMIT in launch options and confs)
// = 15-360 frames per second, held to the display: never below 15 nor above the display's
// rate. 10 to 14 from earlier releases count as 15, and display and half as the display's
// rate and half of it. NOTPROTON_FPS_LIMIT_OFF=1 turns the limit off and keeps its value, as
// the quick settings' switch does. Included by overlay_shim.m after perfhud.m.
//
// A limit paces the game to the display it is on; it never changes the display's refresh
// rate. Any limit turns display sync on (as NOTPROTON_VSYNC=1 does), so presents land on
// refreshes and the game cannot outrun the screen; that alone is "display". Below the
// display's rate the game's own nextDrawable call also waits for its slot, which is where
// a game asks for the next frame's drawable, so the CPU and GPU idle in between rather than
// queueing frames. Frame generation's own drawables are left alone (fg_internal), so it
// still fills in between and nothing is throttled twice.
//
// Cool and steady, NOTPROTON_SUSTAINED=1 (BRIDGEPLAY_SUSTAINED, SUSTAINED in confs): when macOS
// reports the Mac as hot (thermal state serious, then critical) the limit steps down to 3/4,
// then 1/2 of what it was (the display's rate without a limit), at a rate the display divides
// evenly and never below 30, so frame times stay even rather than swinging as the chip slows
// down. It steps back up once the Mac has been cooler for 30 seconds. The player's own limit is
// kept as set and only ever lowered.

#import <mach/mach_time.h>

enum { fl_off, fl_display, fl_half, fl_fixed };
static const char *const fl_mode_names[] = { "off", "display", "half", "fixed" };
#define fl_min_fps 15

// Changed at run time by the quick settings sidebar, read on the game's thread. fl_mode and
// fl_fixed_fps are the value; fl_disabled is the switch that turns it off without losing it.
static _Atomic int fl_mode;
static _Atomic int fl_fixed_fps;
static _Atomic int fl_disabled;
static mach_timebase_info_data_t fl_timebase;

static os_unfair_lock fl_lock = OS_UNFAIR_LOCK_INIT;
static id fl_layer; // compared only, never messaged
static uint64_t fl_layer_last;
static uint64_t fl_next;
static uint64_t fl_screen_asked;
static _Atomic int fl_screen_pending;
static _Atomic uint64_t fl_waits;

// Cool and steady: the switch, and the step now in force (0 none, 1 serious, 2 critical).
static _Atomic int fl_sustained;
static _Atomic int fl_step;
static _Atomic int fl_step_synced;
static _Atomic int fl_sustained_started;
static _Atomic int fl_thermal_test;
static os_unfair_lock fl_thermal_lock = OS_UNFAIR_LOCK_INIT;
static double fl_cool_since;
#define fl_sustained_floor 30
#define fl_sustained_hold 30.0

static uint64_t fl_ticks(double seconds)
{
	return (uint64_t)(seconds * 1e9 * fl_timebase.denom / fl_timebase.numer);
}

// The player's own limit, set and switched on
static int fl_own_active(void)
{
	return atomic_load(&fl_mode) != fl_off && !atomic_load(&fl_disabled);
}

static int framelimit_active(void)
{
	return fl_own_active() || atomic_load(&fl_step) > 0;
}

// Cool and steady's cap for a limit of base on a display refreshing at hz (0 when not known):
// 3/4 of base at step 1, 1/2 at step 2, as the largest rate hz divides evenly at or below that,
// never below 30. base itself when that would not lower it, or when no such rate is 30 or more:
// display sync is on, so a rate between divisors would alternate one and two refreshes.
static double fl_cooled(double base, int hz, int step)
{
	if (step <= 0 || base <= fl_sustained_floor)
		return base;
	double target = fmax(base * (step >= 2 ? 0.5 : 0.75), fl_sustained_floor);
	double rate;
	if (hz > 0) {
		int n = (int)ceil(hz / target - 1e-9);
		if (n < 1 || (double)hz / n < fl_sustained_floor)
			return base;
		rate = (double)hz / n;
	} else {
		rate = round(target);
	}
	return rate < base ? rate : base;
}

// The player's limit in frames per second on a display refreshing at hz (0 when not known):
// fixed limits as set, at least 15 and at most the display's rate, the others from the display.
// 0 when only display sync applies.
static double fl_own_rate(int hz)
{
	double fixed = atomic_load(&fl_fixed_fps);
	if (fixed < fl_min_fps)
		fixed = fl_min_fps;
	switch (atomic_load(&fl_mode)) {
	case fl_fixed:
		return hz > 0 && fixed >= hz ? hz : fixed;
	case fl_half:
		return hz > 0 ? fmax(hz / 2.0, fl_min_fps < hz ? fl_min_fps : hz) : 0;
	case fl_display:
		return hz > 0 ? hz : 0;
	default:
		return 0;
	}
}

// The cap now: the player's limit, lowered by Cool and steady's step while the Mac runs hot.
static double framelimit_rate(int hz)
{
	double rate = fl_own_active() ? fl_own_rate(hz) : 0;
	int step = atomic_load(&fl_step);
	if (step > 0) {
		double base = rate > 0 ? rate : hz;
		double cooled = base > 0 ? fl_cooled(base, hz, step) : 0;
		if (cooled > 0 && (rate <= 0 || cooled < rate))
			rate = cooled;
	}
	return rate;
}

// What the overlay shows: the cap now in effect, 0 when the display rate is still unknown
// for a display-relative limit, -1 without a limit (none set, or switched off).
static double framelimit_cap(void)
{
	if (!framelimit_active())
		return -1;
	return framelimit_rate(atomic_load(&ph_refresh_hz));
}

// The quick settings slider's top: the display's rate, 60 while it is not known.
static int framelimit_max(void)
{
	int hz = atomic_load(&ph_refresh_hz);
	return hz >= fl_min_fps && hz <= 360 ? hz : 60;
}

// Where the quick settings slider sits: the value the limit has, or would have once switched
// on, on this display. With no value set, the display's rate.
static int framelimit_value(void)
{
	int top = framelimit_max(), fixed = atomic_load(&fl_fixed_fps);
	switch (atomic_load(&fl_mode)) {
	case fl_fixed:
		return fixed < fl_min_fps ? fl_min_fps : fixed > top ? top : fixed;
	case fl_half:
		return (int)lround(fmax(top / 2.0, fl_min_fps));
	default:
		return top;
	}
}

// The display rate of the window the game draws in, read on the main thread (perfhud's
// ph_read_screen) when the limit starts and every few seconds, so moving the window to
// another display follows.
static void fl_track_screen(id layer, uint64_t now)
{
	if (fl_screen_asked != 0 && now - fl_screen_asked < fl_ticks(3.0))
		return;
	if (atomic_exchange(&fl_screen_pending, 1))
		return;
	fl_screen_asked = now;
	[layer retain];
	dispatch_async(dispatch_get_main_queue(), ^{
		int before = atomic_load(&ph_refresh_hz);
		ph_read_screen(layer);
		int hz = atomic_load(&ph_refresh_hz);
		if (hz != before)
			shim_log("overlay_shim framelimit: display at %d Hz, limit %.0f fps%s\n", hz,
			         framelimit_rate(hz), framelimit_rate(hz) >= hz ? " (display sync alone)" : "");
		[layer release];
		atomic_store(&fl_screen_pending, 0);
	});
}

static void fl_sustained_start(void);
static void framelimit_sync_layer(id layer); // overlay_shim.m

// A step that turns the limit on or off changes display sync, which is set on the main thread
static void fl_follow_step(id layer)
{
	if (!atomic_load(&fl_sustained))
		return;
	if (!atomic_exchange(&fl_sustained_started, 1))
		fl_sustained_start();
	int step = atomic_load(&fl_step);
	if (atomic_exchange(&fl_step_synced, step) == step)
		return;
	[layer retain];
	dispatch_async(dispatch_get_main_queue(), ^{
		framelimit_sync_layer(layer);
		[layer release];
	});
}

// Called on the game's thread before its nextDrawable runs.
static void framelimit_wait(id layer)
{
	if (fg_internal || layer == nil)
		return;
	fl_follow_step(layer);
	if (!framelimit_active())
		return;

	uint64_t now = mach_absolute_time();
	int hz = atomic_load(&ph_refresh_hz);
	double rate = framelimit_rate(hz);
	uint64_t target = 0;

	os_unfair_lock_lock(&fl_lock);
	// One window: a second layer (a launcher, a splash) is left alone while the first draws
	if (layer != fl_layer) {
		if (fl_layer != nil && now - fl_layer_last < fl_ticks(1.0)) {
			os_unfair_lock_unlock(&fl_lock);
			return;
		}
		fl_layer = layer;
		fl_next = 0;
		fl_screen_asked = 0;
	}
	fl_layer_last = now;
	fl_track_screen(layer, now);
	// At or above the display's rate display sync already holds the game there
	if (rate <= 0 || (hz > 0 && rate >= hz)) {
		fl_next = 0;
	} else {
		uint64_t interval = fl_ticks(1.0 / rate);
		// First frame, or the game fell more than a slot behind (loading, a stall): start the
		// schedule again rather than letting frames through back to back to catch up
		if (fl_next == 0 || now > fl_next + interval)
			fl_next = now;
		target = fl_next;
		fl_next += interval;
	}
	os_unfair_lock_unlock(&fl_lock);

	if (target > now) {
		atomic_fetch_add(&fl_waits, 1);
		mach_wait_until(target);
	}
}

// display, half, 10 to 360, or off; returns 0 for anything else.
static int framelimit_parse(const char *value, int *mode, int *fps)
{
	*fps = 0;
	if (value == NULL || value[0] == '\0' || strcmp(value, "0") == 0 || strcasecmp(value, "off") == 0) {
		*mode = fl_off;
		return 1;
	}
	if (strcasecmp(value, "display") == 0) {
		*mode = fl_display;
		return 1;
	}
	if (strcasecmp(value, "half") == 0) {
		*mode = fl_half;
		return 1;
	}
	char *end = NULL;
	long n = strtol(value, &end, 10);
	if (end == value || *end != '\0' || n < 10 || n > 360)
		return 0;
	*mode = fl_fixed;
	*fps = (int)n;
	return 1;
}

// Reads the setting; returns whether a limit is on for this process. A value switched off
// is kept, so the quick settings slider starts from it.
static int framelimit_init(void)
{
	// The quick settings can set a limit later
	mach_timebase_info(&fl_timebase);
	const char *value = getenv("NOTPROTON_FPS_LIMIT");
	const char *off = getenv("NOTPROTON_FPS_LIMIT_OFF");
	int mode, fps;
	if (!framelimit_parse(value, &mode, &fps)) {
		shim_log("overlay_shim framelimit: BRIDGEPLAY_FPS_LIMIT=%s not understood "
		         "(15-360, display, half), off\n", value);
		return 0;
	}
	atomic_store(&fl_disabled, off != NULL && strcmp(off, "1") == 0);
	if (mode == fl_off)
		return 0;
	atomic_store(&fl_fixed_fps, fps);
	atomic_store(&fl_mode, mode);
	if (atomic_load(&fl_disabled))
		shim_log("overlay_shim framelimit: %s kept, switched off\n", value);
	else if (mode == fl_fixed)
		shim_log("overlay_shim framelimit: %d fps, paced to the display\n", fps < fl_min_fps ? fl_min_fps : fps);
	else
		shim_log("overlay_shim framelimit: %s refresh, paced to the display\n", fl_mode_names[mode]);
	return framelimit_active();
}

// The quick settings' limit, applied from the next frame; layer gets display sync to match.
// Main thread.
static int framelimit_set(const char *value, id layer)
{
	int mode, fps;
	if (!framelimit_parse(value, &mode, &fps))
		return 0;
	os_unfair_lock_lock(&fl_lock);
	atomic_store(&fl_fixed_fps, fps);
	atomic_store(&fl_mode, mode);
	fl_next = 0;
	os_unfair_lock_unlock(&fl_lock);
	if (layer != nil)
		framelimit_sync_layer(layer);
	shim_log("overlay_shim framelimit: %s from the quick settings%s\n", mode == fl_off ? "off" : value,
	         atomic_load(&fl_disabled) ? ", switched off" : "");
	return 1;
}

// The quick settings' switch: the limit off, or back on at its value. Main thread.
static int framelimit_set_off(const char *value, id layer)
{
	if (value == NULL || (strcmp(value, "0") != 0 && strcmp(value, "1") != 0))
		return 0;
	os_unfair_lock_lock(&fl_lock);
	atomic_store(&fl_disabled, value[0] == '1');
	fl_next = 0;
	os_unfair_lock_unlock(&fl_lock);
	if (layer != nil)
		framelimit_sync_layer(layer);
	shim_log("overlay_shim framelimit: %s from the quick settings\n", value[0] == '1' ? "switched off" : "switched on");
	return 1;
}

// Cool and steady's step for a thermal state (0 nominal to 3 critical) at a time in seconds:
// up at once, down only after fl_sustained_hold seconds cooler.
static int fl_thermal_tick(int thermal, double now)
{
	int want = thermal >= 3 ? 2 : thermal == 2 ? 1 : 0;
	os_unfair_lock_lock(&fl_thermal_lock);
	int step = atomic_load(&fl_step);
	if (want > step) {
		step = want;
		fl_cool_since = 0;
	} else if (want < step) {
		if (fl_cool_since == 0)
			fl_cool_since = now;
		if (now - fl_cool_since >= fl_sustained_hold) {
			step = want;
			fl_cool_since = 0;
		}
	} else {
		fl_cool_since = 0;
	}
	int was = atomic_exchange(&fl_step, step);
	os_unfair_lock_unlock(&fl_thermal_lock);
	if (was != step) {
		static const char *const names[] = { "nominal", "fair", "serious", "critical" };
		double rate = framelimit_rate(atomic_load(&ph_refresh_hz));
		char cap[32] = "no limit";
		if (rate > 0)
			snprintf(cap, sizeof(cap), "%.0f fps", rate);
		else if (framelimit_active())
			snprintf(cap, sizeof(cap), "display sync");
		shim_log("overlay_shim sustained: thermal %s, step %d, %s\n",
		         names[thermal < 0 ? 0 : thermal > 3 ? 3 : thermal], step, cap);
	}
	return step;
}

static double fl_seconds(void)
{
	return (double)mach_absolute_time() * fl_timebase.numer / fl_timebase.denom / 1e9;
}

// Started on the first frame, so only a process that draws reads the thermal state
static void fl_sustained_start(void)
{
	dispatch_source_t timer =
	    dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
	if (timer == NULL)
		return;
	dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 2 * NSEC_PER_SEC, NSEC_PER_SEC);
	dispatch_source_set_event_handler(timer, ^{
		if (atomic_load(&fl_thermal_test))
			return;
		@autoreleasepool {
			fl_thermal_tick((int)[[NSProcessInfo processInfo] thermalState], fl_seconds());
		}
	});
	dispatch_resume(timer);
}

// Reads Cool and steady's switch; returns whether it is on.
static int framelimit_sustained_init(void)
{
	const char *value = getenv("NOTPROTON_SUSTAINED");
	if (value == NULL || strcmp(value, "1") != 0)
		return 0;
	atomic_store(&fl_sustained, 1);
	shim_log("overlay_shim sustained: on, the limit steps down while the Mac runs hot\n");
	return 1;
}

// Test entries: a thermal state at a time in seconds, which stops the real readings, and the
// cap Cool and steady gives a limit of base on a display at hz at a step
__attribute__((visibility("default"))) int np_sustained_tick(int thermal, double seconds)
{
	if (!atomic_load(&fl_sustained))
		return -1;
	atomic_store(&fl_thermal_test, 1);
	return fl_thermal_tick(thermal, seconds);
}

__attribute__((visibility("default"))) double np_sustained_rate(double base, int hz, int step)
{
	return fl_cooled(base, hz, step);
}

// Test entry: the limit in force and how often the game waited for its slot
__attribute__((visibility("default"))) void np_framelimit_probe(int *mode, double *cap, int *waits,
                                                                int *vsync)
{
	if (mode != NULL)
		*mode = atomic_load(&fl_mode);
	if (cap != NULL)
		*cap = framelimit_cap();
	if (waits != NULL)
		*waits = (int)atomic_load(&fl_waits);
	if (vsync != NULL)
		*vsync = force_vsync || framelimit_active();
}
