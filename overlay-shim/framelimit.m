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

static uint64_t fl_ticks(double seconds)
{
	return (uint64_t)(seconds * 1e9 * fl_timebase.denom / fl_timebase.numer);
}

static int framelimit_active(void)
{
	return atomic_load(&fl_mode) != fl_off && !atomic_load(&fl_disabled);
}

// The cap in frames per second on a display refreshing at hz (0 when not known): fixed
// limits as set, at least 15 and at most the display's rate, the others from the display.
// 0 when only display sync applies.
static double framelimit_rate(int hz)
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

// Called on the game's thread before its nextDrawable runs.
static void framelimit_wait(id layer)
{
	if (!framelimit_active() || fg_internal || layer == nil)
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

static void framelimit_sync_layer(id layer); // overlay_shim.m

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
