// Scaling filter: NOTPROTON_SCALING_FILTER (BRIDGEPLAY_SCALING_FILTER in launch options and
// confs) = linear | nearest | integer. Included by overlay_shim.m after framelimit.m.
//
// When a game's drawable has fewer pixels than its window on screen (High Resolution off,
// the default, renders at the window's point size, half a Retina display's pixels; a game
// set to a lower resolution than its window), Core Animation scales each frame up to the
// screen with the layer's magnificationFilter. Wine's Mac driver sets that to nearest while
// Retina mode is off, so a Wine game is pixel-doubled today; a native game gets Core
// Animation's own linear. Unset leaves either as it is; this picks the filter instead. It is the last step before the screen, after the game and after
// DXMT's MetalFX upscaling, and it changes nothing when the drawable already matches the
// screen. integer is nearest only at an exact whole-number scale (2x, 3x), where every game
// pixel becomes an even square, and linear otherwise, where nearest would draw some pixels
// wider than others.

#import <math.h>

enum { sf_default, sf_linear, sf_nearest, sf_integer };
static const char *const sf_mode_names[] = { "default", "linear", "nearest", "integer" };

// Changed at run time by the quick settings sidebar
static _Atomic int sf_mode;
// The filter the game's layer came with, put back when the quick settings return to Automatic
// Each layer keeps the filter it came with, so Automatic puts back that layer's own (Wine's
// nearest on the game layer, the default on framegen's covering layer) even after the game
// has changed layers. Main thread.
static char sf_original_key;
static NSHashTable *sf_changed; // every layer given a filter, held weakly, for Automatic

static void sf_remember(CALayer *layer)
{
	if (objc_getAssociatedObject(layer, &sf_original_key) != nil)
		return;
	objc_setAssociatedObject(layer, &sf_original_key, layer.magnificationFilter, OBJC_ASSOCIATION_COPY);
	if (sf_changed == nil)
		sf_changed = [[NSHashTable weakObjectsHashTable] retain];
	[sf_changed addObject:layer];
	shim_log("overlay_shim scalefilter: the layer came with %s magnification\n",
	         layer.magnificationFilter.UTF8String);
}

static void sf_restore(CALayer *layer)
{
	NSString *original = objc_getAssociatedObject(layer, &sf_original_key);
	if (original == nil)
		return;
	layer.magnificationFilter = original;
	objc_setAssociatedObject(layer, &sf_original_key, nil, OBJC_ASSOCIATION_COPY);
}
static os_unfair_lock sf_lock = OS_UNFAIR_LOCK_INIT;
static id sf_layer; // compared only
static double sf_checked;
static _Atomic int sf_pending;
// What the screen shows, for the overlay: the filter in use (0 not yet known, 1 linear,
// 2 nearest) and screen pixels per drawable pixel, times 100
static _Atomic int sf_filter;
static _Atomic int sf_scale_x100;

// Main thread: measure the scale the layer is drawn at and set its filter, and the filter
// of framegen's covering layer, which shows the frames while it is on
static void sf_apply(CAMetalLayer *layer)
{
	ph_read_screen(layer);
	CGSize drawable = layer.drawableSize;
	CGRect bounds = layer.bounds;
	double screen = atomic_load(&ph_scale);
	double sx = drawable.width > 0 ? bounds.size.width * screen / drawable.width : 0;
	double sy = drawable.height > 0 ? bounds.size.height * screen / drawable.height : 0;

	int whole = sx >= 1.99 && fabs(sx - round(sx)) < 0.01 && fabs(sy - round(sy)) < 0.01 &&
	            fabs(sx - sy) < 0.01;
	int mode = atomic_load(&sf_mode);
	int nearest = mode == sf_nearest || (mode == sf_integer && whole);
	NSString *filter = nearest ? kCAFilterNearest : kCAFilterLinear;

	fg_ca_begin();
	sf_remember(layer);
	if (![layer.magnificationFilter isEqualToString:filter])
		layer.magnificationFilter = filter;
	for (CALayer *sub in layer.sublayers)
		if ([sub isKindOfClass:[CAMetalLayer class]]) {
			sf_remember(sub);
			if (![sub.magnificationFilter isEqualToString:filter])
				sub.magnificationFilter = filter;
		}
	fg_ca_end();

	int scale = (int)lround(sx * 100);
	int before = atomic_exchange(&sf_filter, nearest ? 2 : 1);
	int before_scale = atomic_exchange(&sf_scale_x100, scale);
	if (before != (nearest ? 2 : 1) || abs(before_scale - scale) > 1)
		shim_log("overlay_shim scalefilter: %s, drawable %.0fx%.0f shown at %.0fx%.0f px (%.2fx), %s\n",
		         sf_mode_names[mode], drawable.width, drawable.height, bounds.size.width * screen,
		         bounds.size.height * screen, sx, nearest ? "nearest" : "linear");
}

// Called on the game's thread after its nextDrawable: checks the layer when it is new and
// every second, so a resolution change in the game or a move to another display follows.
static void scalefilter_note(id layer)
{
	if (atomic_load(&sf_mode) == sf_default || fg_internal || layer == nil)
		return;

	double now = CACurrentMediaTime();
	os_unfair_lock_lock(&sf_lock);
	int due = layer != sf_layer || now - sf_checked >= 1.0;
	if (due) {
		sf_layer = layer;
		sf_checked = now;
	}
	os_unfair_lock_unlock(&sf_lock);
	if (!due || atomic_exchange(&sf_pending, 1))
		return;

	[layer retain];
	dispatch_async(dispatch_get_main_queue(), ^{
		// The quick settings may have put Automatic back since this was queued
		if (atomic_load(&sf_mode) != sf_default)
			sf_apply((CAMetalLayer *)layer);
		[layer release];
		atomic_store(&sf_pending, 0);
	});
}

// What the overlay shows: the filter in use (NULL when this is not set or not known yet)
// and the scale it is applied at
static const char *scalefilter_state(double *scale)
{
	int filter = atomic_load(&sf_filter);
	if (atomic_load(&sf_mode) == sf_default || filter == 0)
		return NULL;
	int scale_x100 = atomic_load(&sf_scale_x100);
	if (scale != NULL)
		*scale = scale_x100 / 100.0;
	// The frame already has the screen's pixels (High Resolution, MetalFX): no filter applies
	if (scale_x100 <= 101)
		return "Not scaled";
	return filter == 2 ? "Nearest" : "Linear";
}

static int sf_parse(const char *value)
{
	if (value == NULL || value[0] == '\0' || strcmp(value, "0") == 0 || strcasecmp(value, "default") == 0)
		return sf_default;
	if (strcasecmp(value, "linear") == 0)
		return sf_linear;
	if (strcasecmp(value, "nearest") == 0)
		return sf_nearest;
	if (strcasecmp(value, "integer") == 0)
		return sf_integer;
	return -1;
}

// The quick settings' filter, applied to layer now. Automatic puts back, on every layer it
// changed, the filter that layer came with. Main thread.
static int scalefilter_set(const char *value, CAMetalLayer *layer)
{
	int mode = sf_parse(value);
	if (mode < 0)
		return 0;
	atomic_store(&sf_mode, mode);
	if (layer != nil && mode != sf_default) {
		sf_apply(layer);
	} else if (mode == sf_default) {
		// Every layer the filter touched, not only the current one: the game may go back to
		// one it drew to before
		fg_ca_begin();
		for (CALayer *changed in sf_changed.allObjects)
			sf_restore(changed);
		[sf_changed removeAllObjects];
		fg_ca_end();
	}
	if (mode == sf_default)
		atomic_store(&sf_filter, 0);
	shim_log("overlay_shim scalefilter: %s from the quick settings\n", sf_mode_names[mode]);
	return 1;
}

// Reads the setting; returns whether a filter is chosen for this process.
static int scalefilter_init(void)
{
	const char *value = getenv("NOTPROTON_SCALING_FILTER");
	if (value == NULL || value[0] == '\0' || strcmp(value, "0") == 0 || strcasecmp(value, "default") == 0)
		return 0;
	if (strcasecmp(value, "linear") == 0)
		sf_mode = sf_linear;
	else if (strcasecmp(value, "nearest") == 0)
		sf_mode = sf_nearest;
	else if (strcasecmp(value, "integer") == 0)
		sf_mode = sf_integer;
	else {
		shim_log("overlay_shim scalefilter: BRIDGEPLAY_SCALING_FILTER=%s not understood "
		         "(linear|nearest|integer), left as it is\n", value);
		return 0;
	}
	shim_log("overlay_shim scalefilter: %s\n", sf_mode_names[sf_mode]);
	return 1;
}

// Test entry: the mode, and the filter and scale last applied
__attribute__((visibility("default"))) void np_scalefilter_probe(int *mode, int *filter, double *scale)
{
	if (mode != NULL)
		*mode = atomic_load(&sf_mode);
	if (filter != NULL)
		*filter = atomic_load(&sf_filter);
	if (scale != NULL)
		*scale = atomic_load(&sf_scale_x100) / 100.0;
}
