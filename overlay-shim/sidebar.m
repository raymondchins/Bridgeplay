// Bridgeplay quick settings: an in-game sidebar for the performance overlay, the frame rate
// limit and the scaling filter, with the battery and power the Mac reports. Included by
// overlay_shim.m after scalefilter.m.
//
// Option-Command-P shows it on the right edge of the game's window; Option-Command-P or
// Escape hides it, and so does a click outside it. Up and Down pick a setting, Left and
// Right (or Return) change it, and a click or a drag along a slider picks a stop. While it shows,
// the game gets no key presses, clicks, drags, scrolls or mouse movement, so neither its window
// messages nor its raw input see them; releases still pass, so nothing it saw pressed stays held.
// The cursor is the sidebar's then: shown, free and the arrow, whatever the game hid, clipped or
// recentred, and the game gets it back as it left it on closing (cursor.m). The game keeps
// drawing behind it.
//
// A change takes effect on the game's next frame and is written to
// <support>/quick-settings/<appid>.conf. Steam's page collects it through the
// NotProton.TakeQuickSettings route (dylib/feats/quicksettings.c) and saves it to the game's
// launch options with the Bridgeplay panel's own logic, so the next launch and Steam
// Properties › Bridgeplay show the same value.
//
// It is a layer above the game's CAMetalLayer, as the performance overlay is: no window of
// its own and no change of focus. BRIDGEPLAY_QUICK_SETTINGS=0 turns it off.

#import <pwd.h>
#import <fcntl.h>
#import <sys/stat.h>

// The frame rate limit is a value and a switch: the slider sets frames per second from 15 to
// the display's rate, and Enable frame limit applies it; switched off, the slider keeps its place.
// The switch is saved as BRIDGEPLAY_FPS_LIMIT_OFF, 1 when off.
enum { sb_overlay, sb_limit, sb_limit_on, sb_filter, sb_rows };

static const char *const sb_keys[sb_rows] = { "BRIDGEPLAY_PERF_OVERLAY", "BRIDGEPLAY_FPS_LIMIT",
	                                      "BRIDGEPLAY_FPS_LIMIT_OFF", "BRIDGEPLAY_SCALING_FILTER" };
static const char *const sb_titles[sb_rows] = { "Performance overlay", "Frame rate limit", "Enable frame limit",
	                                        "Scaling filter" };
// The stepped and named choices; the limit's value is a number and its switch 0 or 1
static const char *const sb_values[sb_rows][4] = {
	{ "0", "fps", "summary", "detailed" },
	{ NULL },
	{ "0", "1" },
	{ "0", "linear", "nearest", "integer" },
};
static const char *const sb_labels[sb_rows][4] = {
	{ "Off", "FPS", "Summary", "Detailed" },
	{ NULL },
	{ NULL },
	{ "Auto", "Linear", "Nearest", "Integer" },
};
static const int sb_counts[sb_rows] = { 4, 0, 2, 4 };

#define sb_key_p 35
#define sb_key_return 36
#define sb_key_tab 48
#define sb_key_space 49
#define sb_key_escape 53
#define sb_key_left 123
#define sb_key_right 124
#define sb_key_down 125
#define sb_key_up 126

#define sb_mod_shift (1UL << 17)
#define sb_mod_control (1UL << 18)
#define sb_mod_option (1UL << 19)
#define sb_mod_command (1UL << 20)
// Caps Lock to Fn: the keys a flagsChanged event reports
#define sb_mod_keys (0xffUL << 16)

static NSUInteger sb_mods; // the modifiers held as the game last saw them, main thread

static int sb_enabled;
static char sb_appid[16];
static time_t sb_started; // when this game started: an older pending file is another session's

// The layer the game draws to, from its render thread
static os_unfair_lock sb_lock = OS_UNFAIR_LOCK_INIT;
static id sb_seen; // retained
static double sb_seen_at;

// Main thread only
static int sb_open;
static int sb_row;
static CAMetalLayer *sb_host; // retained while open
static CALayer *sb_panel, *sb_scrim, *sb_hint;
static dispatch_source_t sb_timer;
static char sb_status[120];
static double sb_width;

static int sb_drag_row = -1; // a slider being dragged, main thread

static int sidebar_wanted(void)
{
	const char *off = getenv("NOTPROTON_QUICK_SETTINGS");
	if (off == NULL)
		off = getenv("BRIDGEPLAY_QUICK_SETTINGS");
	return off == NULL || strcmp(off, "0") != 0;
}

static int sb_digits(const char *v)
{
	size_t n = v != NULL ? strlen(v) : 0;
	if (n == 0 || n > 10 || v[0] == '0')
		return 0;
	for (size_t i = 0; i < n; i++)
		if (v[i] < '0' || v[i] > '9')
			return 0;
	return 1;
}

static int sidebar_init(void)
{
	sb_enabled = sidebar_wanted();
	sb_started = time(NULL);
	const char *names[] = { "SteamAppId", "SteamGameId", "STEAM_COMPAT_APP_ID" };
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]) && !sb_appid[0]; i++)
		if (sb_digits(getenv(names[i])))
			snprintf(sb_appid, sizeof(sb_appid), "%s", getenv(names[i]));
	return sb_enabled;
}

static void sb_support(char *out, size_t cap)
{
	const char *home = getenv("HOME");
	if (home == NULL || home[0] == '\0') {
		struct passwd *pw = getpwuid(getuid());
		home = pw != NULL ? pw->pw_dir : NULL;
	}
	out[0] = '\0';
	if (home == NULL)
		return;
	char current[1024], legacy[1024];
	struct stat st;
	snprintf(current, sizeof(current), "%s/Library/Application Support/bridgeplay", home);
	snprintf(legacy, sizeof(legacy), "%s/Library/Application Support/notproton", home);
	snprintf(out, cap, "%s", stat(current, &st) != 0 && stat(legacy, &st) == 0 ? legacy : current);
}

static void sb_maybe_hint(void);

// Render thread: remember the layer the game draws to. Another layer takes over only once
// this one has gone quiet (a launcher window closing, the game replacing a splash).
static void sidebar_note_layer(id layer)
{
	if (!sb_enabled || fg_internal || layer == nil)
		return;
	double now = CACurrentMediaTime();
	id dropped = nil;
	int first = 0;
	os_unfair_lock_lock(&sb_lock);
	if (layer == sb_seen) {
		sb_seen_at = now;
	} else if (sb_seen == nil || now - sb_seen_at > 1.0) {
		first = sb_seen == nil;
		dropped = sb_seen;
		sb_seen = [layer retain];
		sb_seen_at = now;
	}
	os_unfair_lock_unlock(&sb_lock);
	if (dropped != nil)
		dispatch_async(dispatch_get_main_queue(), ^{
			[dropped release];
		});
	if (first)
		dispatch_async(dispatch_get_main_queue(), ^{
			sb_maybe_hint();
		});
}

static CAMetalLayer *sb_current_layer(void)
{
	os_unfair_lock_lock(&sb_lock);
	id layer = [sb_seen retain];
	os_unfair_lock_unlock(&sb_lock);
	return [layer autorelease];
}

// MARK: Settings

// Where each setting stands now, as an index into its choices; -1 when it has none (a
// number set by hand in Steam) or cannot change (the Metal HUD owns the overlay).
static int sb_index(int row)
{
	switch (row) {
	case sb_overlay:
		return ph_hud_locked ? -1 : atomic_load(&ph_level);
	case sb_limit:
		return -1;
	case sb_limit_on:
		// Off with no value set too: there is no limit until one is switched on
		return !atomic_load(&fl_disabled) && atomic_load(&fl_mode) != fl_off;
	default:
		return atomic_load(&sf_mode);
	}
}

// The change waits there until Steam's page takes it; a newer pick of the same setting
// replaces it, and the other settings still waiting stay.
static int sb_save(const char *key, const char *value)
{
	if (!sb_appid[0]) {
		snprintf(sb_status, sizeof(sb_status), "Applied for this session. No Steam app to save it to.");
		return 0;
	}
	char support[1024], dir[1100], path[1200], tmp[1300];
	sb_support(support, sizeof(support));
	snprintf(dir, sizeof(dir), "%s/quick-settings", support);
	struct stat st;
	// A link in place of the folder is refused, so nothing is written where it points
	if (!support[0] || (mkdir(dir, 0700) != 0 && errno != EEXIST) || lstat(dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
		snprintf(sb_status, sizeof(sb_status), "Applied for this session. Could not save it.");
		return 0;
	}
	snprintf(path, sizeof(path), "%s/%s.conf", dir, sb_appid);
	snprintf(tmp, sizeof(tmp), "%s.%d.tmp", path, getpid());

	// Picks still waiting from this game carry over; a file from before it started belongs to
	// an earlier session, maybe another Steam account's, and is replaced, not merged
	char kept[sb_rows][16] = { { 0 } };
	FILE *in = fopen(path, "r");
	struct stat file;
	if (in != NULL && (fstat(fileno(in), &file) != 0 || file.st_mtime < sb_started)) {
		fclose(in);
		in = NULL;
	}
	if (in != NULL) {
		char line[128];
		while (fgets(line, sizeof(line), in) != NULL) {
			line[strcspn(line, "\r\n")] = '\0';
			for (int i = 0; i < sb_rows; i++) {
				size_t n = strlen(sb_keys[i]);
				if (strncmp(line, sb_keys[i], n) == 0 && line[n] == '=')
					snprintf(kept[i], sizeof(kept[i]), "%s", line + n + 1);
			}
		}
		fclose(in);
	}
	for (int i = 0; i < sb_rows; i++)
		if (strcmp(key, sb_keys[i]) == 0)
			snprintf(kept[i], sizeof(kept[i]), "%s", value);

	// A new file of our own: never one already there, nor a link's target
	unlink(tmp);
	int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
	FILE *out = fd >= 0 ? fdopen(fd, "w") : NULL;
	if (fd >= 0 && out == NULL)
		close(fd);
	int ok = out != NULL;
	for (int i = 0; ok && i < sb_rows; i++)
		if (kept[i][0])
			ok = fprintf(out, "%s=%s\n", sb_keys[i], kept[i]) > 0;
	if (out != NULL && fclose(out) != 0)
		ok = 0;
	if (!ok || rename(tmp, path) != 0) {
		unlink(tmp);
		snprintf(sb_status, sizeof(sb_status), "Applied for this session. Could not save it.");
		return 0;
	}
	snprintf(sb_status, sizeof(sb_status), "Applied. Saved for this game's next launch.");
	return 1;
}

// Applies one setting now and saves it. Main thread.
static int sb_apply(const char *key, const char *value)
{
	CAMetalLayer *host = sb_host != nil ? sb_host : sb_current_layer();
	int ok = 0;
	if (strcmp(key, sb_keys[sb_overlay]) == 0) {
		for (int i = 0; i < sb_counts[sb_overlay]; i++)
			if (strcmp(value, sb_values[sb_overlay][i]) == 0)
				ok = perfhud_set_level(i);
	} else if (strcmp(key, sb_keys[sb_limit]) == 0) {
		ok = framelimit_set(value, host);
	} else if (strcmp(key, sb_keys[sb_limit_on]) == 0) {
		ok = framelimit_set_off(value, host);
	} else if (strcmp(key, sb_keys[sb_filter]) == 0) {
		ok = scalefilter_set(value, host);
	}
	if (!ok)
		return 0;
	int saved = sb_save(key, value);
	shim_log("overlay_shim sidebar: %s=%s applied, %s\n", key, value, saved ? "saved" : sb_status);
	return 1;
}

static CGColorRef sb_gray(double alpha);

// MARK: Drawing
//
// Control kinds chosen by what the choices are. The overlay level is ordered steps, so it is a
// stepped slider whose position means something: more detail to the right. The frame rate limit
// is a number, so a continuous slider in whole frames per second, with a switch under it that
// turns it off and dims it. The scaling filters are not an order, so they stay a selector that
// shows every name. Text is placed by centring its capitals on the line it belongs to
// (ph_centred), so labels and values of different sizes share one optical centre.

// Layout, in points from the panel's top-left
#define sb_pad 22.0
#define sb_head_mid 38.0     // title line
#define sb_power_mid 76.0    // battery line
#define sb_power_bar 92.0    // battery gauge
#define sb_rows_top 118.0    // the first row's card
#define sb_tint_inset 10.0   // the focus tint's inset from the panel's sides
// A row is a card (the focus tint, the click target) with sb_card_pad inside it on every side,
// measured to the text's capitals, the same as the inset its text has from the card's sides
// (sb_pad - sb_tint_inset). Offsets below are from the card's top.
#define sb_card_pad 12.0
#define sb_title_mid 17.0    // a row's title line
#define sb_track_mid 40.0    // slider track centre
#define sb_stops_mid 60.0    // slider stop and range labels
#define sb_hit_above 18.0    // a press this far above the track to below its labels picks a stop
#define sb_hit_below 32.0
#define sb_seg_top 32.0      // selector
#define sb_seg_h 32.0
#define sb_note_mid 76.0     // the selector's measured note
#define sb_switch_mid 20.0   // a switch row's title and switch
#define sb_thumb_r 8.0
#define sb_inset 9.0         // stops start this far in, so the end thumbs stay inside
#define sb_switch_w 32.0
#define sb_switch_h 18.0
#define sb_group_gap 6.0     // between settings; a switch stays with the slider it belongs to

// Each row's card height, and the gap after it. Together they fit a 480 pt-tall window.
static const double sb_row_heights[sb_rows] = { 76, 76, 40, 92 };
static const double sb_row_gaps[sb_rows] = { sb_group_gap, 0, sb_group_gap, 0 };

static double sb_row_top(int row)
{
	double top = sb_rows_top;
	for (int i = 0; i < row; i++)
		top += sb_row_heights[i] + sb_row_gaps[i];
	return top;
}

struct sb_fonts {
	CTFontRef title, row, value, stop, stop_on, seg, seg_on, small;
};
static struct sb_fonts sb_f;

static int sb_hover_row = -1, sb_hover_k = -1; // the stop or choice under the pointer, main thread

static void sb_fonts_load(void)
{
	ph_style_load();
	if (sb_f.title != NULL)
		return;
	sb_f.title = ph_font(17, 600);
	sb_f.row = ph_font(13, 600);
	sb_f.value = ph_font(13, 500);
	sb_f.stop = ph_font(11, 500);
	sb_f.stop_on = ph_font(11, 650);
	sb_f.seg = ph_font(12, 500);
	sb_f.seg_on = ph_font(12, 650);
	sb_f.small = ph_font(11, 400);
}

// A rectangle given from the top of a box h tall
static CGRect sb_rect(double h, double x, double y, double w, double rh)
{
	return CGRectMake(x, h - y - rh, w, rh);
}

static void sb_fill_round(CGContextRef ctx, CGRect r, double radius, double red, double green, double blue,
                          double alpha)
{
	CGPathRef path = CGPathCreateWithRoundedRect(r, radius, radius, NULL);
	CGContextAddPath(ctx, path);
	CGContextSetRGBFillColor(ctx, red, green, blue, alpha);
	CGContextFillPath(ctx);
	CGPathRelease(path);
}

static void sb_stroke_round(CGContextRef ctx, CGRect r, double radius, double alpha)
{
	CGPathRef path = CGPathCreateWithRoundedRect(r, radius, radius, NULL);
	CGContextAddPath(ctx, path);
	CGContextSetRGBStrokeColor(ctx, 1, 1, 1, alpha);
	CGContextSetLineWidth(ctx, 1);
	CGContextStrokePath(ctx);
	CGPathRelease(path);
}

static void sb_hairline(CGContextRef ctx, double h, double x, double y, double w)
{
	CGContextSetFillColorWithColor(ctx, ph_style.line);
	CGContextFillRect(ctx, sb_rect(h, x, y, w, 1));
}

static double sb_text_right(CGContextRef ctx, double h, double right, double mid, const char *text, CTFontRef font,
                            CGColorRef color)
{
	double tw = ph_width(text, font, 0);
	ph_text(ctx, h, right - tw, ph_centred(mid, font), text, font, color, 0);
	return tw;
}

// A stepped control's stops, left to right, as indexes into its choices
static int sb_stops(int row, int pick[6])
{
	for (int k = 0; k < sb_counts[row]; k++)
		pick[k] = k;
	return sb_counts[row];
}

// The stop the current choice sits on; -1 when it has none
static int sb_position(int row, const int *pick, int n)
{
	int sel = sb_index(row);
	for (int k = 0; k < n; k++)
		if (sel >= 0 && pick[k] == sel)
			return k;
	return -1;
}

static double sb_stop_x(double w, int k, int n)
{
	double x0 = sb_pad + sb_inset, x1 = w - sb_pad - sb_inset;
	return n > 1 ? x0 + (x1 - x0) * k / (n - 1) : x0;
}

// The words beside a row's title, only where the control alone does not say it
static void sb_readout(int row, char *out, size_t cap)
{
	out[0] = '\0';
	if (row == sb_overlay && ph_hud_locked) {
		snprintf(out, cap, "Metal HUD");
	} else if (row == sb_limit) {
		snprintf(out, cap, "%d FPS", framelimit_value());
	}
}

// The limit slider's x for a value, and the value under an x, in whole frames per second
static double sb_limit_x(double w, int v)
{
	double x0 = sb_pad + sb_inset, x1 = w - sb_pad - sb_inset;
	int top = framelimit_max();
	return top > fl_min_fps ? x0 + (x1 - x0) * (v - fl_min_fps) / (top - fl_min_fps) : x1;
}

static int sb_limit_at(double w, double x)
{
	double x0 = sb_pad + sb_inset, x1 = w - sb_pad - sb_inset;
	int top = framelimit_max();
	double t = x1 > x0 ? (x - x0) / (x1 - x0) : 1;
	int v = (int)lround(fl_min_fps + t * (top - fl_min_fps));
	return v < fl_min_fps ? fl_min_fps : v > top ? top : v;
}

// The thumb, with a soft offset shadow so it sits on the track
static void sb_draw_thumb(CGContextRef ctx, double h, double x, double cy, int disabled)
{
	CGContextSaveGState(ctx);
	CGColorRef shadow = sb_gray(0.55);
	CGContextSetShadowWithColor(ctx, CGSizeMake(0, -1), 3, shadow);
	CGColorRelease(shadow);
	if (disabled)
		CGContextSetRGBFillColor(ctx, PH_RGB(0x6E6E73, 1));
	else
		CGContextSetRGBFillColor(ctx, PH_RGB(0xF5F5F7, 1));
	CGContextFillEllipseInRect(ctx, sb_rect(h, x - sb_thumb_r, cy - sb_thumb_r, 2 * sb_thumb_r, 2 * sb_thumb_r));
	CGContextRestoreGState(ctx);
}

// The frame rate limit: the track filled with the brand gradient up to the value, as the
// stepped slider is, and the two ends named under it. Switched off, it dims and the fill goes
// grey, so the value it keeps still shows.
static void sb_draw_range(CGContextRef ctx, double w, double h, double top, int disabled)
{
	int v = framelimit_value(), maxv = framelimit_max();
	double cy = top + sb_track_mid, x0 = sb_pad + sb_inset, x1 = w - sb_pad - sb_inset, xp = sb_limit_x(w, v);
	sb_fill_round(ctx, sb_rect(h, x0 - 2, cy - 2, x1 - x0 + 4, 4), 2, PH_RGB(0x2C2C30, 1));
	CGRect fill = sb_rect(h, x0 - 2, cy - 2, xp - x0 + 4, 4);
	if (disabled) {
		sb_fill_round(ctx, fill, 2, PH_RGB(0x48484E, 1));
	} else {
		CGContextSaveGState(ctx);
		CGPathRef path = CGPathCreateWithRoundedRect(fill, 2, 2, NULL);
		CGContextAddPath(ctx, path);
		CGContextClip(ctx);
		ph_gradient(ctx, CGPointMake(x0, 0), CGPointMake(x1, 0));
		CGContextRestoreGState(ctx);
		CGPathRelease(path);
	}
	sb_draw_thumb(ctx, h, xp, cy, disabled);
	// The two ends named under them, where the thumb sits at 15 and at the display's rate
	char lo[8], hi[8];
	snprintf(lo, sizeof(lo), "%d", fl_min_fps);
	snprintf(hi, sizeof(hi), "%d", maxv);
	double mid = top + sb_stops_mid;
	ph_text(ctx, h, x0 - ph_width(lo, sb_f.stop, 0) / 2, ph_centred(mid, sb_f.stop), lo, sb_f.stop, ph_style.fg3, 0);
	ph_text(ctx, h, x1 - ph_width(hi, sb_f.stop, 0) / 2, ph_centred(mid, sb_f.stop), hi, sb_f.stop, ph_style.fg3, 0);
}

// A switch at the row's right, in the app's switch blue when on
static void sb_draw_switch(CGContextRef ctx, double w, double h, double mid, int on)
{
	double x = w - sb_pad - sb_switch_w, y = mid - sb_switch_h / 2;
	CGRect track = sb_rect(h, x, y, sb_switch_w, sb_switch_h);
	if (on)
		sb_fill_round(ctx, track, sb_switch_h / 2, PH_RGB(0x4FB3FF, 1));
	else
		sb_fill_round(ctx, track, sb_switch_h / 2, PH_RGB(0x3A3A3F, 1));
	double r = sb_switch_h / 2 - 2, kx = on ? x + sb_switch_w - 2 - 2 * r : x + 2;
	CGContextSetRGBFillColor(ctx, PH_RGB(0xF5F5F7, 1));
	CGContextFillEllipseInRect(ctx, sb_rect(h, kx, y + 2, 2 * r, 2 * r));
}

static void sb_draw_slider(CGContextRef ctx, double w, double h, double top, int row, int disabled)
{
	int pick[6], n = sb_stops(row, pick), pos = sb_position(row, pick, n);
	int hover = sb_hover_row == row && !disabled ? sb_hover_k : -1;
	double cy = top + sb_track_mid, x0 = sb_stop_x(w, 0, n), x1 = sb_stop_x(w, n - 1, n);

	// The track, filled with the brand gradient from its start to the choice, as the app's progress
	// bars are; a notch at each step
	sb_fill_round(ctx, sb_rect(h, x0 - 2, cy - 2, x1 - x0 + 4, 4), 2, PH_RGB(0x2C2C30, 1));
	if (pos > 0) {
		double xp = sb_stop_x(w, pos, n);
		CGContextSaveGState(ctx);
		CGPathRef fill = CGPathCreateWithRoundedRect(sb_rect(h, x0 - 2, cy - 2, xp - x0 + 4, 4), 2, 2, NULL);
		CGContextAddPath(ctx, fill);
		CGContextClip(ctx);
		ph_gradient(ctx, CGPointMake(x0, 0), CGPointMake(x1, 0));
		CGContextRestoreGState(ctx);
		CGPathRelease(fill);
	}
	for (int k = 0; k < n; k++) {
		if (k == pos)
			continue;
		double sx = sb_stop_x(w, k, n);
		if (k < pos)
			CGContextSetRGBFillColor(ctx, 1, 1, 1, 0.85);
		else if (k == hover)
			CGContextSetRGBFillColor(ctx, PH_RGB(0xA1A1A6, 1));
		else
			CGContextSetRGBFillColor(ctx, PH_RGB(0x5A5A60, 1));
		CGContextFillEllipseInRect(ctx, sb_rect(h, sx - 2, cy - 2, 4, 4));
	}
	if (pos >= 0)
		sb_draw_thumb(ctx, h, sb_stop_x(w, pos, n), cy, disabled);
	// Every stop named under it, centred on its notch
	double mid = top + sb_stops_mid;
	for (int k = 0; k < n; k++) {
		const char *label = sb_labels[row][pick[k]];
		CTFontRef font = k == pos ? sb_f.stop_on : sb_f.stop;
		double tw = ph_width(label, font, 0), lx = sb_stop_x(w, k, n) - tw / 2;
		// Inside the card's padding, as every other label is
		if (lx < sb_pad)
			lx = sb_pad;
		if (lx + tw > w - sb_pad)
			lx = w - sb_pad - tw;
		CGColorRef color = disabled ? ph_style.fg3 : k == pos || k == hover ? ph_style.fg : ph_style.fg3;
		ph_text(ctx, h, lx, ph_centred(mid, font), label, font, color, 0);
	}
}

static double sb_seg_width(double w, int row)
{
	return (w - 2 * sb_pad - 6) / sb_counts[row];
}

static void sb_draw_selector(CGContextRef ctx, double w, double h, double top, int row)
{
	int sel = sb_index(row), hover = sb_hover_row == row ? sb_hover_k : -1;
	CGRect box = sb_rect(h, sb_pad, top + sb_seg_top, w - 2 * sb_pad, sb_seg_h);
	sb_fill_round(ctx, box, 8, PH_RGB(0x18181B, 1));
	double segw = sb_seg_width(w, row), mid = top + sb_seg_top + sb_seg_h / 2;
	for (int i = 0; i < sb_counts[row]; i++) {
		double x = sb_pad + 3 + i * segw;
		int on = i == sel;
		CGRect seg = sb_rect(h, x, top + sb_seg_top + 3, segw, sb_seg_h - 6);
		if (on)
			sb_fill_round(ctx, seg, 6, PH_RGB(0x34343A, 1));
		else if (i == hover)
			sb_fill_round(ctx, seg, 6, PH_RGB(0x1F1F23, 1));
		CTFontRef font = on ? sb_f.seg_on : sb_f.seg;
		const char *label = sb_labels[row][i];
		double tw = ph_width(label, font, 0);
		ph_text(ctx, h, x + (segw - tw) / 2, ph_centred(mid, font), label, font,
		        on || i == hover ? ph_style.fg : ph_style.fg2, 0);
	}
	// What the filter has to work with, measured from the game's layer
	char note[96] = "";
	if (sb_host != nil) {
		CGSize d = sb_host.drawableSize;
		double scale = atomic_load(&ph_scale), sx = d.width > 0 ? sb_host.bounds.size.width * scale / d.width : 0;
		if (sx > 1.01)
			snprintf(note, sizeof(note), "Game draws %.0f × %.0f, shown %.1f× larger", d.width, d.height, sx);
		else
			snprintf(note, sizeof(note), "Game draws at full resolution: nothing to scale");
	}
	ph_text(ctx, h, sb_pad, ph_centred(top + sb_note_mid, sb_f.small), note, sb_f.small, ph_style.fg3, 0);
}

static void sb_draw_row(CGContextRef ctx, double w, double h, int row)
{
	double top = sb_row_top(row);
	int focused = row == sb_row;
	int disabled = (row == sb_overlay && ph_hud_locked) || (row == sb_limit && sb_index(sb_limit_on) == 0);
	// Focus: one tint behind the whole row, the same for every kind of control
	if (focused)
		sb_fill_round(ctx, sb_rect(h, sb_tint_inset, top, w - 2 * sb_tint_inset, sb_row_heights[row]), 10,
		              1, 1, 1, 0.05);
	char readout[48];
	sb_readout(row, readout, sizeof(readout));
	double mid = top + (row == sb_limit_on ? sb_switch_mid : sb_title_mid);
	ph_text(ctx, h, sb_pad, ph_centred(mid, sb_f.row), sb_titles[row], sb_f.row, focused ? ph_style.fg : ph_style.fg2,
	        -0.1);
	if (readout[0])
		sb_text_right(ctx, h, w - sb_pad, mid, readout, sb_f.value, disabled ? ph_style.fg3 : ph_style.fg2);
	if (row == sb_filter) {
		sb_draw_selector(ctx, w, h, top, row);
	} else if (row == sb_limit) {
		sb_draw_range(ctx, w, h, top, disabled);
	} else if (row == sb_limit_on) {
		sb_draw_switch(ctx, w, h, mid, sb_index(row));
	} else if (disabled) {
		// The Metal HUD is the game's only overlay: say where it is changed instead of a slider
		// that cannot move
		ph_text(ctx, h, sb_pad, ph_centred(top + sb_track_mid, sb_f.small), "Apple's Metal HUD is on for this game.",
		        sb_f.small, ph_style.fg2, 0);
		ph_text(ctx, h, sb_pad, ph_centred(top + sb_stops_mid, sb_f.small),
		        "Change it in Steam Properties › Bridgeplay.", sb_f.small, ph_style.fg3, 0);
	} else {
		sb_draw_slider(ctx, w, h, top, row, 0);
	}
}

static void sb_draw(CGContextRef ctx, double w, double h)
{
	CGContextSetRGBFillColor(ctx, PH_RGB(0x0B0B0D, 0.97));
	CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
	CGContextSetFillColorWithColor(ctx, ph_style.line);
	CGContextFillRect(ctx, CGRectMake(0, 0, 1, h));

	// Title, and the shortcut that closes it again as a Mac menu shows one
	ph_text(ctx, h, sb_pad, ph_centred(sb_head_mid, sb_f.title), "Quick settings", sb_f.title, ph_style.fg, -0.3);
	sb_text_right(ctx, h, w - sb_pad, sb_head_mid, "⌥⌘P", sb_f.value, ph_style.fg3);

	// Battery and power, where the Mac reports them: one line of context, not the headline
	int battery, on_ac, charging, minutes;
	ph_read_battery(&battery, &on_ac, &charging, &minutes);
	double watts = ph_power();
	char text[64], state[48] = "";
	if (battery >= 0) {
		if (on_ac == 1)
			snprintf(state, sizeof(state), "%s", charging == 1 ? "charging" : "on power");
		else if (minutes > 0)
			snprintf(state, sizeof(state), "%d:%02d left", minutes / 60, minutes % 60);
		else
			snprintf(state, sizeof(state), "on battery");
		if (watts > 0)
			snprintf(text, sizeof(text), "%d%% · %s · %.1f W", battery, state, watts);
		else
			snprintf(text, sizeof(text), "%d%% · %s", battery, state);
		ph_text(ctx, h, sb_pad, ph_centred(sb_power_mid, sb_f.value), "Battery", sb_f.value, ph_style.fg2, 0);
		sb_text_right(ctx, h, w - sb_pad, sb_power_mid, text, sb_f.value, ph_style.fg);
		// A thin gauge; amber only when the battery is low and draining
		CGRect track = sb_rect(h, sb_pad, sb_power_bar, w - 2 * sb_pad, 2);
		sb_fill_round(ctx, track, 1, PH_RGB(0x222226, 1));
		int low = battery <= 20 && on_ac != 1;
		CGRect fill = sb_rect(h, sb_pad, sb_power_bar, (w - 2 * sb_pad) * battery / 100.0, 2);
		if (low)
			sb_fill_round(ctx, fill, 1, PH_RGB(0xFF9F0A, 1));
		else
			sb_fill_round(ctx, fill, 1, PH_RGB(0x8E8E93, 1));
	} else if (watts > 0) {
		snprintf(text, sizeof(text), "%.1f W", watts);
		ph_text(ctx, h, sb_pad, ph_centred(sb_power_mid, sb_f.value), "Power drawn", sb_f.value, ph_style.fg2, 0);
		sb_text_right(ctx, h, w - sb_pad, sb_power_mid, text, sb_f.value, ph_style.fg);
	} else {
		ph_text(ctx, h, sb_pad, ph_centred(sb_power_mid, sb_f.small), "No battery or power reading on this Mac",
		        sb_f.small, ph_style.fg3, 0);
	}
	sb_hairline(ctx, h, sb_pad, sb_rows_top - 8, w - 2 * sb_pad);

	for (int row = 0; row < sb_rows; row++)
		sb_draw_row(ctx, w, h, row);

	// Right under the settings, where the eye is after a change
	double foot = sb_row_top(sb_rows - 1) + sb_row_heights[sb_rows - 1] + 8;
	sb_hairline(ctx, h, sb_pad, foot, w - 2 * sb_pad);
	ph_text(ctx, h, sb_pad, ph_centred(foot + 22, sb_f.small),
	        sb_status[0] ? sb_status : "Changes apply now and are saved for this game.", sb_f.small,
	        sb_status[0] ? ph_style.fg : ph_style.fg2, 0);
	ph_text(ctx, h, sb_pad, ph_centred(foot + 42, sb_f.small), "↑↓ setting    ←→ change    esc close",
	        sb_f.small, ph_style.fg3, 0.2);
}

static CGImageRef sb_render(double w, double h, double scale)
{
	sb_fonts_load();
	size_t pw = (size_t)ceil(w * scale), phh = (size_t)ceil(h * scale);
	CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef ctx = CGBitmapContextCreate(NULL, pw, phh, 8, 0, srgb,
	                                         kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
	CGColorSpaceRelease(srgb);
	if (ctx == NULL)
		return NULL;
	CGContextScaleCTM(ctx, scale, scale);
	CGContextSetShouldSmoothFonts(ctx, false);
	sb_draw(ctx, w, h);
	CGImageRef image = CGBitmapContextCreateImage(ctx);
	CGContextRelease(ctx);
	return image;
}

static CGColorRef sb_gray(double alpha)
{
	CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGFloat c[] = { 0, 0, 0, alpha };
	CGColorRef color = CGColorCreate(srgb, c);
	CGColorSpaceRelease(srgb);
	return color;
}

// Lays the scrim and the panel over the host and draws the panel. Main thread.
static void sb_redraw(void)
{
	if (!sb_open || sb_host == nil)
		return;
	CGRect b = sb_host.bounds;
	double w = b.size.width < 380 ? b.size.width : 320;
	double scale = atomic_load(&ph_scale);
	CGImageRef image = sb_render(w, b.size.height, scale);
	fg_ca_begin();
	if (sb_scrim == nil) {
		sb_scrim = [[CALayer alloc] init];
		// Under the performance overlay (2000), so it stays readable while settings change
		sb_scrim.zPosition = 1500;
		CGColorRef dim = sb_gray(0.32);
		sb_scrim.backgroundColor = dim;
		CGColorRelease(dim);
	}
	if (sb_panel == nil) {
		sb_panel = [[CALayer alloc] init];
		sb_panel.anchorPoint = CGPointZero;
		sb_panel.zPosition = 3000;
		sb_panel.contentsGravity = kCAGravityResize;
	}
	if (sb_scrim.superlayer != sb_host) {
		[sb_scrim removeFromSuperlayer];
		[sb_host addSublayer:sb_scrim];
	}
	if (sb_panel.superlayer != sb_host) {
		[sb_panel removeFromSuperlayer];
		[sb_host addSublayer:sb_panel];
	}
	sb_scrim.frame = b;
	sb_panel.bounds = CGRectMake(0, 0, w, b.size.height);
	sb_panel.position = CGPointMake(b.origin.x + b.size.width - w, b.origin.y);
	sb_panel.contentsScale = scale;
	sb_panel.contents = (id)image;
	sb_scrim.hidden = NO;
	sb_panel.hidden = NO;
	fg_ca_end();
	if (image != NULL)
		CGImageRelease(image);
	sb_width = w;
}

// MARK: Showing and input

static id sb_msg(id target, const char *selector)
{
	SEL sel = sel_registerName(selector);
	return target != nil && [target respondsToSelector:sel] ? ((id (*)(id, SEL))objc_msgSend)(target, sel) : nil;
}

static id sb_view(CALayer *layer)
{
	Class view_class = objc_getClass("NSView");
	for (CALayer *l = layer; l != nil && view_class != Nil; l = l.superlayer)
		if (l.delegate != nil && [l.delegate isKindOfClass:view_class])
			return l.delegate;
	return nil;
}

static void sb_mark_seen(void)
{
	char support[1024], marker[1100];
	sb_support(support, sizeof(support));
	if (!support[0])
		return;
	snprintf(marker, sizeof(marker), "%s/.quick-settings-seen", support);
	int fd = open(marker, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
	if (fd >= 0)
		close(fd);
}

static void sb_close(void)
{
	if (!sb_open)
		return;
	sb_open = 0;
	cursor_give_back();
	sb_drag_row = -1;
	sb_hover_row = sb_hover_k = -1;
	fg_ca_begin();
	sb_panel.hidden = YES;
	sb_scrim.hidden = YES;
	fg_ca_end();
	if (sb_timer != NULL) {
		dispatch_source_cancel(sb_timer);
		dispatch_release(sb_timer);
		sb_timer = NULL;
	}
	[sb_host release];
	sb_host = nil;
	shim_log("overlay_shim sidebar: closed\n");
}

static void sb_show(void)
{
	CAMetalLayer *host = sb_current_layer();
	if (host == nil)
		return;
	sb_host = [host retain];
	sb_open = 1;
	cursor_take();
	sb_status[0] = '\0';
	ph_read_screen(sb_host);
	if (sb_hint != nil) {
		fg_ca_begin();
		sb_hint.hidden = YES;
		fg_ca_end();
	}
	sb_mark_seen();
	sb_redraw();
	// The battery and power figures move while it is open, and the game can move to another
	// display, whose rate is the limit slider's top
	sb_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
	dispatch_source_set_timer(sb_timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC,
	                          200 * NSEC_PER_MSEC);
	dispatch_source_set_event_handler(sb_timer, ^{
		@autoreleasepool {
			if (sb_host != nil)
				ph_read_screen(sb_host);
			sb_redraw();
		}
	});
	dispatch_resume(sb_timer);
	id view = sb_view(sb_host);
	CALayer *view_layer = (CALayer *)sb_msg(view, "layer");
	shim_log("overlay_shim sidebar: open, layer %.0fx%.0f, view %.0fx%.0f flipped=%d, app %s\n",
	         sb_host.bounds.size.width, sb_host.bounds.size.height, view_layer.bounds.size.width,
	         view_layer.bounds.size.height,
	         view != nil ? (int)((BOOL (*)(id, SEL))objc_msgSend)(view, sel_registerName("isFlipped")) : -1,
	         sb_appid[0] ? sb_appid : "unknown");
}

// The limit at v frames per second, from the slider: not while it is switched off
static void sb_set_limit(int v)
{
	if (sb_index(sb_limit_on) == 0)
		return;
	int top = framelimit_max();
	v = v < fl_min_fps ? fl_min_fps : v > top ? top : v;
	if (atomic_load(&fl_mode) == fl_fixed && v == framelimit_value())
		return;
	char value[8];
	snprintf(value, sizeof(value), "%d", v);
	sb_apply(sb_keys[sb_limit], value);
}

// Enable frame limit: off keeps the value; on with no value yet takes the slider's, the
// display's rate
static void sb_toggle_limit(void)
{
	if (sb_index(sb_limit_on) == 1) {
		sb_apply(sb_keys[sb_limit_on], "1");
		return;
	}
	if (atomic_load(&fl_mode) == fl_off) {
		char value[8];
		snprintf(value, sizeof(value), "%d", framelimit_value());
		sb_apply(sb_keys[sb_limit], value);
	}
	if (atomic_load(&fl_disabled))
		sb_apply(sb_keys[sb_limit_on], "0");
}

// Left and Right move along the control as drawn, the limit by one frame per second; Return
// and Space go to the next stop and wrap. On the switch, each of them flips it.
static void sb_step(int row, int delta)
{
	if (row == sb_overlay && ph_hud_locked)
		return;
	if (row == sb_limit) {
		if (delta != 0)
			sb_set_limit(framelimit_value() + delta);
		return;
	}
	if (row == sb_limit_on) {
		sb_toggle_limit();
		return;
	}
	int pick[6], n = sb_stops(row, pick), at = sb_position(row, pick, n);
	int next = at < 0 ? (delta > 0 ? 0 : n - 1) : at + delta;
	if (delta == 0)
		next = at < 0 ? 0 : (at + 1) % n;
	if (next < 0 || next >= n || next == at)
		return;
	sb_apply(sb_keys[row], sb_values[row][pick[next]]);
}

// The slider stop nearest x
static int sb_nearest_stop(int row, double x)
{
	int pick[6], n = sb_stops(row, pick), best = 0;
	for (int k = 1; k < n; k++)
		if (fabs(x - sb_stop_x(sb_width, k, n)) < fabs(x - sb_stop_x(sb_width, best, n)))
			best = k;
	return best;
}

// The slider stop nearest x, applied when the choice is not already on it
static void sb_pick_stop(int row, double x)
{
	if (row == sb_overlay && ph_hud_locked)
		return;
	int pick[6], n = sb_stops(row, pick), best = sb_nearest_stop(row, x);
	if (best != sb_position(row, pick, n))
		sb_apply(sb_keys[row], sb_values[row][pick[best]]);
}

// A click's place in the panel, from its top-left; 0 when it is not in the game's window.
static int sb_point(id event, double *x, double *y)
{
	id view = sb_view(sb_host);
	id window = sb_msg(view, "window");
	if (window == nil || sb_msg(event, "window") != window)
		return 0;
	CGPoint loc = ((CGPoint (*)(id, SEL))objc_msgSend)(event, sel_registerName("locationInWindow"));
	CGPoint p = ((CGPoint (*)(id, SEL, CGPoint, id))objc_msgSend)(view, sel_registerName("convertPoint:fromView:"),
	                                                              loc, nil);
	CALayer *view_layer = (CALayer *)sb_msg(view, "layer");
	CGSize size = view_layer != nil ? view_layer.bounds.size : sb_host.bounds.size;
	BOOL flipped = ((BOOL (*)(id, SEL))objc_msgSend)(view, sel_registerName("isFlipped"));
	*x = p.x - (size.width - sb_width);
	*y = flipped ? p.y : size.height - p.y;
	return 1;
}

// The row under a point in the panel (-1 outside the rows), and the selector choice or slider
// stop it is on (-1 when on neither; 0 on the limit's track or anywhere on its switch's row)
static int sb_hit(double x, double y, int *row_out)
{
	int row = -1;
	for (int i = 0; i < sb_rows; i++)
		if (y >= sb_row_top(i) && y < sb_row_top(i) + sb_row_heights[i])
			row = i;
	*row_out = -1;
	if (x < 0 || x > sb_width || row < 0)
		return -1;
	*row_out = row;
	double top = sb_row_top(row);
	if (row == sb_limit_on)
		return 0;
	if (row == sb_filter) {
		double seg_top = top + sb_seg_top;
		if (y < seg_top || y > seg_top + sb_seg_h || x < sb_pad + 3)
			return -1;
		int i = (int)floor((x - sb_pad - 3) / sb_seg_width(sb_width, row));
		return i >= 0 && i < sb_counts[row] ? i : -1;
	}
	if (y < top + sb_track_mid - sb_hit_above || y > top + sb_track_mid + sb_hit_below)
		return -1;
	return row == sb_limit ? 0 : sb_nearest_stop(row, x);
}

static void sb_click(id event)
{
	double x, y;
	if (!sb_point(event, &x, &y))
		return;
	if (x < 0) {
		sb_close();
		return;
	}
	int row, k = sb_hit(x, y, &row);
	if (row < 0)
		return;
	sb_row = row;
	if (row == sb_filter) {
		if (k >= 0 && k != sb_index(row))
			sb_apply(sb_keys[row], sb_values[row][k]);
	} else if (row == sb_limit_on) {
		sb_toggle_limit();
	} else if (row == sb_limit && k >= 0) {
		// A press on the track sets the value under it and starts a drag
		sb_set_limit(sb_limit_at(sb_width, x));
		sb_drag_row = row;
	} else if (k >= 0) {
		// A press on the track or its labels picks the nearest stop and starts a drag
		sb_pick_stop(row, x);
		sb_drag_row = row;
	}
	sb_redraw();
}

// The pointer over a stop or choice lights it, so a click's target shows before the click
static void sb_hover(id event)
{
	double x, y;
	int row = -1, k = -1;
	if (sb_point(event, &x, &y))
		k = sb_hit(x, y, &row);
	if ((row == sb_overlay && ph_hud_locked) || row == sb_limit || row == sb_limit_on)
		k = -1;
	if (k < 0)
		row = -1;
	if (row != sb_hover_row || k != sb_hover_k) {
		sb_hover_row = row;
		sb_hover_k = k;
		sb_redraw();
	}
}

// NSApplication sendEvent:, before the game sees the event; returns 1 when it is taken.
static int sidebar_send_event(id event)
{
	if (!sb_enabled)
		return 0;
	NSUInteger type = ((NSUInteger (*)(id, SEL))objc_msgSend)(event, sel_registerName("type"));
	int key_down = type == 10;
	unsigned short code = 0;
	int shortcut = 0;
	NSUInteger flags = 0;
	if (key_down || type == 12)
		flags = ((NSUInteger (*)(id, SEL))objc_msgSend)(event, sel_registerName("modifierFlags"));
	if (key_down) {
		code = ((unsigned short (*)(id, SEL))objc_msgSend)(event, sel_registerName("keyCode"));
		BOOL repeat = ((BOOL (*)(id, SEL))objc_msgSend)(event, sel_registerName("isARepeat"));
		shortcut = code == sb_key_p && (flags & sb_mod_command) && (flags & sb_mod_option) &&
		           !(flags & (sb_mod_control | sb_mod_shift)) && !repeat;
	}
	if (!sb_open) {
		if (!shortcut)
			return 0;
		sb_show();
		sb_mods = flags & sb_mod_keys;
		return 1;
	}
	switch (type) {
	case 10: // key down: every key is the sidebar's while it shows
		if (shortcut || code == sb_key_escape)
			sb_close();
		else if (code == sb_key_up)
			sb_row = (sb_row + sb_rows - 1) % sb_rows;
		else if (code == sb_key_down || code == sb_key_tab)
			sb_row = (sb_row + 1) % sb_rows;
		else if (code == sb_key_left)
			sb_step(sb_row, -1);
		else if (code == sb_key_right)
			sb_step(sb_row, 1);
		else if (code == sb_key_return || code == sb_key_space)
			sb_step(sb_row, 0);
		sb_redraw();
		return 1;
	case 1: // left mouse down
		sb_click(event);
		return 1;
	case 6: { // left mouse dragged: a slider follows the pointer from stop to stop
		double x, y;
		if (sb_drag_row >= 0 && sb_point(event, &x, &y)) {
			if (sb_drag_row == sb_limit)
				sb_set_limit(sb_limit_at(sb_width, x));
			else
				sb_pick_stop(sb_drag_row, x);
			sb_redraw();
		}
		sb_hover(event);
		return 1;
	}
	case 2: // left mouse up ends a drag, and still reaches the game
		sb_drag_row = -1;
		sb_hover(event);
		return 0;
	case 5: // mouse moved
		sb_hover(event);
		return 1;
	case 3: case 7: case 22: case 25: case 27: // other presses, drags, scrolls
		return 1;
	case 17: // cursor updates: AppKit would set the game window's cursor over the sidebar's arrow
		return 1;
	case 12: { // modifiers: a press stays out of the game; anything that releases a key reaches
		// it, so nothing stays held there, even with another modifier still pressed
		NSUInteger now = flags & sb_mod_keys;
		if ((now & ~sb_mods) && !(sb_mods & ~now))
			return 1;
		sb_mods = now;
		return 0;
	}
	default: // key and button releases: the game keeps an accurate picture
		return 0;
	}
}

// The first time a game runs with the sidebar available, a short pointer to its shortcut.
static void sb_maybe_hint(void)
{
	char support[1024], marker[1100];
	struct stat st;
	sb_support(support, sizeof(support));
	snprintf(marker, sizeof(marker), "%s/.quick-settings-seen", support);
	if (!support[0] || stat(marker, &st) == 0 || sb_hint != nil)
		return;
	CAMetalLayer *host = sb_current_layer();
	// Only on a layer in a window: an offscreen layer has nobody to tell
	if (host == nil || sb_view(host) == nil)
		return;
	ph_read_screen(host);
	sb_fonts_load();
	const char *keys = "⌥⌘P", *text = "Bridgeplay quick settings";
	double kw = ph_width(keys, sb_f.row, 0.4), tw = ph_width(text, sb_f.small, 0);
	double w = 16 + kw + 10 + tw + 16, h = 32, scale = atomic_load(&ph_scale);
	CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)ceil(w * scale), (size_t)ceil(h * scale), 8, 0, srgb,
	                                         kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
	CGColorSpaceRelease(srgb);
	if (ctx == NULL)
		return;
	CGContextScaleCTM(ctx, scale, scale);
	sb_fill_round(ctx, CGRectMake(0.5, 0.5, w - 1, h - 1), 8, PH_RGB(0x0D0D0F, 0.9));
	sb_stroke_round(ctx, CGRectMake(0.5, 0.5, w - 1, h - 1), 8, 0.10);
	ph_text(ctx, h, 16, ph_centred(h / 2, sb_f.row), keys, sb_f.row, ph_style.fg, 0.4);
	ph_text(ctx, h, 16 + kw + 10, ph_centred(h / 2, sb_f.small), text, sb_f.small, ph_style.fg2, 0);
	CGImageRef image = CGBitmapContextCreateImage(ctx);
	CGContextRelease(ctx);

	int flipped = 0;
	for (CALayer *l = host; l != nil; l = l.superlayer)
		flipped ^= l.geometryFlipped ? 1 : 0;
	CGRect b = host.bounds;
	fg_ca_begin();
	sb_hint = [[CALayer alloc] init];
	sb_hint.anchorPoint = CGPointZero;
	sb_hint.zPosition = 2900;
	sb_hint.contentsScale = scale;
	sb_hint.contents = (id)image;
	sb_hint.bounds = CGRectMake(0, 0, w, h);
	sb_hint.position = CGPointMake(b.origin.x + b.size.width - w - 12,
	                               flipped ? b.origin.y + 12 : b.origin.y + b.size.height - h - 12);
	[host addSublayer:sb_hint];
	fg_ca_end();
	CGImageRelease(image);
	shim_log("overlay_shim sidebar: showing the shortcut hint\n");
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		fg_ca_begin();
		sb_hint.hidden = YES;
		fg_ca_end();
	});
}

// Test entry: applies and saves one setting as the sidebar does. Main thread.
__attribute__((visibility("default"))) int np_quick_settings_set(const char *key, const char *value)
{
	return sb_apply(key, value);
}

// Test entry: one event through the sidebar, as NSApplication sendEvent: hands it over; 1 when
// the sidebar takes it, 0 when the game gets it. Main thread.
__attribute__((visibility("default"))) int np_quick_settings_event(id event)
{
	return sidebar_send_event(event);
}
