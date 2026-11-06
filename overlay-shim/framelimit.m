// Frame rate limit: NOTPROTON_FPS_LIMIT (BRIDGEPLAY_FPS_LIMIT in launch options and confs)
// = display | half | 10-360. Included by overlay_shim.m after perfhud.m.
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

static int fl_mode;
static double fl_fixed_fps;
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

// The cap in frames per second on a display refreshing at hz (0 when not known): fixed
// limits as set, the others from the display. 0 when only display sync applies.
static double framelimit_rate(int hz)
{
	switch (fl_mode) {
	case fl_fixed:
		return hz > 0 && fl_fixed_fps >= hz ? hz : fl_fixed_fps;
	case fl_half:
		return hz > 0 ? hz / 2.0 : 0;
	case fl_display:
		return hz > 0 ? hz : 0;
	default:
		return 0;
	}
}

// What the overlay shows: the cap now in effect, 0 when the display rate is still unknown
// for a display-relative limit, -1 without a limit.
static double framelimit_cap(void)
{
	if (fl_mode == fl_off)
		return -1;
	return framelimit_rate(atomic_load(&ph_refresh_hz));
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
	if (fl_mode == fl_off || fg_internal || layer == nil)
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

// Reads the setting; returns whether a limit is on for this process.
static int framelimit_init(void)
{
	const char *value = getenv("NOTPROTON_FPS_LIMIT");
	if (value == NULL || value[0] == '\0' || strcmp(value, "0") == 0 || strcasecmp(value, "off") == 0)
		return 0;

	if (strcasecmp(value, "display") == 0) {
		fl_mode = fl_display;
	} else if (strcasecmp(value, "half") == 0) {
		fl_mode = fl_half;
	} else {
		char *end = NULL;
		long fps = strtol(value, &end, 10);
		if (end == value || *end != '\0' || fps < 10 || fps > 360) {
			shim_log("overlay_shim framelimit: BRIDGEPLAY_FPS_LIMIT=%s not understood "
			         "(display|half|10-360), off\n", value);
			return 0;
		}
		fl_mode = fl_fixed;
		fl_fixed_fps = (double)fps;
	}
	mach_timebase_info(&fl_timebase);
	if (fl_mode == fl_fixed)
		shim_log("overlay_shim framelimit: %.0f fps, paced to the display\n", fl_fixed_fps);
	else
		shim_log("overlay_shim framelimit: %s refresh, paced to the display\n", fl_mode_names[fl_mode]);
	return 1;
}

// Test entry: the limit in force and how often the game waited for its slot
__attribute__((visibility("default"))) void np_framelimit_probe(int *mode, double *cap, int *waits,
                                                                int *vsync)
{
	if (mode != NULL)
		*mode = fl_mode;
	if (cap != NULL)
		*cap = framelimit_cap();
	if (waits != NULL)
		*waits = (int)atomic_load(&fl_waits);
	if (vsync != NULL)
		*vsync = force_vsync;
}
