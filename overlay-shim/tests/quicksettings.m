#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import <crt_externs.h>
#import <dlfcn.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>

#import "check.h"

// Quick settings: what the in-game sidebar sets takes effect while the game runs (a limit
// set mid-run holds the frame rate, Off lets it go and gives the game back its own VSync
// choice; the overlay comes on and goes off; a filter is applied and Automatic puts back the
// layer's own), is saved for Steam to pick up, and the Metal HUD keeps the overlay its own.

typedef int (*set_fn)(const char *, const char *);
typedef int (*event_fn)(id);

// Stands in for an NSEvent: the sidebar reads only these
@interface FakeEvent : NSObject
@property NSUInteger type, modifierFlags;
@property unsigned short keyCode;
@property BOOL isARepeat;
@end
@implementation FakeEvent
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
#define SHIFT (1UL << 17)
typedef void (*limit_probe_fn)(int *, double *, int *, int *);
typedef void (*hud_probe_fn)(int *, int *, int *, double *, int *, int *);

static id<MTLCommandQueue> queue;

static double present_for(CAMetalLayer *layer, double seconds)
{
	double start = CACurrentMediaTime();
	int frames = 0;
	while (CACurrentMediaTime() - start < seconds) {
		@autoreleasepool {
			id<CAMetalDrawable> drawable = [layer nextDrawable];
			if (drawable == nil)
				return -1;
			id<MTLCommandBuffer> buffer = [queue commandBuffer];
			[buffer presentDrawable:drawable];
			[buffer commit];
			frames++;
		}
	}
	return frames / (CACurrentMediaTime() - start);
}

static NSString *saved(const char *home)
{
	NSString *path = [NSString stringWithFormat:@"%s/Library/Application Support/bridgeplay/quick-settings/4242.conf", home];
	return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
}

static int child(const char *path, const char *mode, const char *home)
{
	void *shim = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	CHECK(shim != NULL, "%s does not load: %s", path, dlerror());
	set_fn set = (set_fn)dlsym(shim, "np_quick_settings_set");
	limit_probe_fn limit = (limit_probe_fn)dlsym(shim, "np_framelimit_probe");
	hud_probe_fn hud = (hud_probe_fn)dlsym(shim, "np_perfhud_probe");
	event_fn send = (event_fn)dlsym(shim, "np_quick_settings_event");
	CHECK(set != NULL && limit != NULL && hud != NULL && send != NULL, "%s exports no np_quick_settings_set", path);

	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	SKIP_IF(device == nil, "no Metal device on this machine");
	queue = [device newCommandQueue];
	CAMetalLayer *layer = [CAMetalLayer layer];
	layer.device = device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.bounds = CGRectMake(0, 0, 128, 72);
	layer.drawableSize = CGSizeMake(64, 36);
	layer.displaySyncEnabled = NO; // the game turns VSync off
	layer.magnificationFilter = kCAFilterNearest; // as Wine's Mac driver sets it with Retina mode off

	if (strcmp(mode, "hud") == 0) {
		present_for(layer, 0.2);
		CHECK(!set("BRIDGEPLAY_PERF_OVERLAY", "summary"), "the overlay came on over the Metal HUD");
		CHECK(saved(home).length == 0, "a refused change was saved");
		CHECK(set("BRIDGEPLAY_FPS_LIMIT", "30"), "the limit is refused with the Metal HUD on");
		printf("%-10s the Metal HUD keeps the overlay; the limit still changes\n", mode);
		return 0;
	}

	// A link planted at the name the save writes through first must not be followed
	NSString *dir = [NSString stringWithFormat:@"%s/Library/Application Support/bridgeplay/quick-settings", home];
	NSString *victim = [NSString stringWithFormat:@"%s/save.dat", home];
	[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
	[@"SAVE" writeToFile:victim atomically:NO encoding:NSUTF8StringEncoding error:nil];
	NSString *planted = [NSString stringWithFormat:@"%@/4242.conf.%d.tmp", dir, getpid()];
	symlink(victim.UTF8String, planted.UTF8String);

	// Uncapped, well above the 30 limit below; the floor allows for a busy machine
	double before = present_for(layer, 1.0);
	CHECK(before > 45, "the game ran at only %.1f fps before any limit", before);
	CHECK(!layer.displaySyncEnabled, "VSync was forced before any limit");

	// A pick still waiting from an earlier session is replaced, not carried into this one's
	NSString *stale = [dir stringByAppendingString:@"/4242.conf"];
	[@"BRIDGEPLAY_PERF_OVERLAY=detailed\n" writeToFile:stale atomically:NO encoding:NSUTF8StringEncoding error:nil];
	[[NSFileManager defaultManager] setAttributes:@{ NSFileModificationDate : [NSDate dateWithTimeIntervalSinceNow:-3600] }
	                                 ofItemAtPath:stale error:nil];
	CHECK(set("BRIDGEPLAY_FPS_LIMIT", "30"), "a 30 fps limit was refused");
	CHECK([saved(home) isEqualToString:@"BRIDGEPLAY_FPS_LIMIT=30\n"], "the save carried over an earlier session's pick: %s",
	      saved(home).UTF8String);
	CHECK(layer.displaySyncEnabled, "the limit did not turn display sync on at once");
	double capped = present_for(layer, 2.0);
	CHECK(capped > 27 && capped < 31, "a limit set mid-run let the game run at %.1f fps", capped);

	CHECK(set("BRIDGEPLAY_FPS_LIMIT", "0"), "Off was refused");
	CHECK(!layer.displaySyncEnabled, "Off did not give the game back its VSync off");
	double after = present_for(layer, 1.0);
	CHECK(after > 45, "the game stayed at %.1f fps after Off", after);

	int level = -1, frames = -1, attached = -1, cpu = 0, gpu = 0;
	double fps = 0;
	CHECK(set("BRIDGEPLAY_PERF_OVERLAY", "summary"), "the overlay was refused");
	present_for(layer, 1.2);
	[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
	hud(&level, &frames, &attached, &fps, &cpu, &gpu);
	CHECK(level == 2 && attached == 1, "the overlay level %d attached %d after Summary", level, attached);
	CHECK(set("BRIDGEPLAY_PERF_OVERLAY", "0"), "overlay Off was refused");
	hud(&level, &frames, &attached, &fps, &cpu, &gpu);
	CHECK(level == 0, "the overlay level stayed %d after Off", level);

	NSString *original = [layer.magnificationFilter copy];
	CHECK(set("BRIDGEPLAY_SCALING_FILTER", "nearest"), "Nearest was refused");
	CHECK([layer.magnificationFilter isEqualToString:kCAFilterNearest], "Nearest was not applied at once");
	CHECK(set("BRIDGEPLAY_SCALING_FILTER", "0"), "Automatic was refused");
	CHECK([layer.magnificationFilter isEqualToString:original], "Automatic left %s, not %s",
	      layer.magnificationFilter.UTF8String, original.UTF8String);

	// A check the game's frame queued for the main thread must not undo Automatic
	CHECK(set("BRIDGEPLAY_SCALING_FILTER", "linear"), "Linear was refused");
	present_for(layer, 0.05);
	CHECK(set("BRIDGEPLAY_SCALING_FILTER", "0"), "Automatic was refused");
	[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
	CHECK([layer.magnificationFilter isEqualToString:original], "a queued check left %s after Automatic, not %s",
	      layer.magnificationFilter.UTF8String, original.UTF8String);

	// Automatic gives every layer it changed back its own filter, also after the game moved to
	// a new layer that came with another filter, and the layer it left
	CAMetalLayer *next = [CAMetalLayer layer];
	next.device = device;
	next.pixelFormat = MTLPixelFormatBGRA8Unorm;
	next.bounds = CGRectMake(0, 0, 128, 72);
	next.drawableSize = CGSizeMake(64, 36);
	next.magnificationFilter = kCAFilterTrilinear;
	CHECK(set("BRIDGEPLAY_SCALING_FILTER", "linear"), "Linear was refused");
	CHECK([layer.magnificationFilter isEqualToString:kCAFilterLinear], "Linear was not applied to the game layer");
	present_for(next, 1.1);
	[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
	CHECK([next.magnificationFilter isEqualToString:kCAFilterLinear], "Linear did not follow the game to its new layer");
	CHECK(set("BRIDGEPLAY_SCALING_FILTER", "0"), "Automatic was refused after the layer changed");
	CHECK([next.magnificationFilter isEqualToString:kCAFilterTrilinear], "Automatic gave the new layer %s, not its own",
	      next.magnificationFilter.UTF8String);
	CHECK([layer.magnificationFilter isEqualToString:original], "Automatic left the earlier layer at %s, not %s",
	      layer.magnificationFilter.UTF8String, original.UTF8String);
	present_for(layer, 1.2); // the game layer is the current one again once next has gone quiet

	// A Metal sublayer (framegen's covering layer) follows the limit's display sync both ways
	CAMetalLayer *cover = [CAMetalLayer layer];
	[layer addSublayer:cover];
	cover.displaySyncEnabled = NO; // a new layer starts with it on
	CHECK(set("BRIDGEPLAY_FPS_LIMIT", "30"), "a 30 fps limit was refused again");
	CHECK(cover.displaySyncEnabled, "the covering layer did not get display sync with the limit");
	CHECK(set("BRIDGEPLAY_FPS_LIMIT", "0"), "Off was refused again");
	CHECK(!cover.displaySyncEnabled && !layer.displaySyncEnabled, "Off left display sync on (game %d, cover %d)",
	      layer.displaySyncEnabled, cover.displaySyncEnabled);
	[cover removeFromSuperlayer];

	// While the sidebar shows, a modifier press stays out of the game; releases reach it
	CHECK(send(event(10, 35, CMD | OPT)), "Option-Command-P did not open the sidebar");
	CHECK(send(event(12, 56, CMD | OPT | SHIFT)), "a Shift press reached the game under the sidebar");
	CHECK(!send(event(12, 58, CMD | SHIFT)), "the Option release, with Shift still held, did not reach the game");
	CHECK(!send(event(12, 56, CMD)), "the Shift release did not reach the game");
	CHECK(!send(event(12, 55, 0)), "the Command release did not reach the game");
	CHECK(send(event(12, 59, 1UL << 18)), "a Control press reached the game under the sidebar");
	CHECK(!send(event(12, 59, 0)), "the Control release did not reach the game");
	CHECK(send(event(10, 126, 0)), "an arrow key reached the game under the sidebar");
	CHECK(send(event(10, 53, 0)), "Escape did not close the sidebar");
	CHECK(!send(event(12, 56, SHIFT)), "a Shift press did not reach the game once the sidebar closed");

	CHECK(!set("BRIDGEPLAY_FPS_LIMIT", "5"), "a limit of 5 was accepted");
	CHECK(!set("MTL_HUD_ENABLED", "1"), "an unknown setting was accepted");

	NSString *file = saved(home);
	CHECK([file isEqualToString:@"BRIDGEPLAY_PERF_OVERLAY=0\nBRIDGEPLAY_FPS_LIMIT=0\nBRIDGEPLAY_SCALING_FILTER=0\n"],
	      "the saved changes read %s", file.UTF8String);
	CHECK([[NSString stringWithContentsOfFile:victim encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"SAVE"],
	      "saving wrote through a link at its temporary name");

	// Switched off, the limit keeps its value and lets the game go; switched back on, it holds again
	CHECK(set("BRIDGEPLAY_FPS_LIMIT", "45"), "a limit of 45 was refused");
	CHECK(set("BRIDGEPLAY_FPS_LIMIT_OFF", "1"), "the switch was refused");
	CHECK(!set("BRIDGEPLAY_FPS_LIMIT_OFF", "2"), "the switch took 2");
	int lmode = -1, lwaits = -1, lsync = -1;
	double lcap = -2;
	limit(&lmode, &lcap, &lwaits, &lsync);
	CHECK(lmode == 3 && lcap == -1 && lsync == 0 && !layer.displaySyncEnabled,
	      "switched off: mode %d cap %.1f sync %d layer %d", lmode, lcap, lsync, layer.displaySyncEnabled);
	double free_fps = present_for(layer, 1.0);
	CHECK(free_fps > 55, "a limit switched off held the game to %.1f fps", free_fps);
	CHECK(set("BRIDGEPLAY_FPS_LIMIT_OFF", "0"), "switching the limit back on was refused");
	limit(&lmode, &lcap, &lwaits, &lsync);
	CHECK(lmode == 3 && lcap == 45 && layer.displaySyncEnabled, "switched on: mode %d cap %.1f", lmode, lcap);
	double held = present_for(layer, 2.0);
	CHECK(held > 42 && held < 47, "the kept 45 held the game to %.1f fps", held);
	file = saved(home);
	CHECK([file containsString:@"BRIDGEPLAY_FPS_LIMIT=45\n"] && [file containsString:@"BRIDGEPLAY_FPS_LIMIT_OFF=0\n"],
	      "the saved changes read %s", file.UTF8String);

	// The keys: the limit moves one frame per second at a time, and the switch flips on Return
	// and Space. The modifier check above left the focus on the last row.
	CHECK(send(event(10, 35, CMD | OPT)), "Option-Command-P did not open the sidebar again");
	send(event(12, 55, 0));
	send(event(10, 125, 0)); // to the overlay
	send(event(10, 125, 0)); // to the frame rate limit
	send(event(10, 124, 0));
	send(event(10, 124, 0));
	limit(&lmode, &lcap, &lwaits, &lsync);
	CHECK(lmode == 3 && lcap == 47, "two Right presses took 45 to %.1f, not 47", lcap);
	send(event(10, 125, 0)); // to Enable frame limit
	send(event(10, 36, 0));
	limit(&lmode, &lcap, &lwaits, &lsync);
	CHECK(lcap == -1, "Return on Enable frame limit left a cap of %.1f", lcap);
	send(event(10, 126, 0)); // back up to the limit
	send(event(10, 124, 0));
	limit(&lmode, &lcap, &lwaits, &lsync);
	CHECK(lcap == -1 && [saved(home) containsString:@"BRIDGEPLAY_FPS_LIMIT=47\n"],
	      "Right on a switched-off limit moved it (cap %.1f, %s)", lcap, saved(home).UTF8String);
	send(event(10, 125, 0)); // to Enable frame limit
	send(event(10, 49, 0));
	limit(&lmode, &lcap, &lwaits, &lsync);
	CHECK(lcap == 47, "Space switched the limit back on at %.1f, not the kept 47", lcap);
	send(event(10, 53, 0));

	// A link in place of the folder is not written through either
	NSString *elsewhere = [NSString stringWithFormat:@"%s/elsewhere", home];
	[[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
	[[NSFileManager defaultManager] createDirectoryAtPath:elsewhere withIntermediateDirectories:YES attributes:nil error:nil];
	symlink(elsewhere.UTF8String, dir.UTF8String);
	CHECK(set("BRIDGEPLAY_FPS_LIMIT", "30"), "a limit was refused with the folder linked away");
	CHECK(![[NSFileManager defaultManager] fileExistsAtPath:[elsewhere stringByAppendingString:@"/4242.conf"]],
	      "saving wrote through a link in place of the quick-settings folder");
	CHECK(set("BRIDGEPLAY_FPS_LIMIT", "0"), "Off was refused with the folder linked away");
	printf("%-10s %.0f fps, 30 limit %.1f fps, Off %.0f fps; overlay, filter and save follow\n", mode, before,
	       capped, after);
	return 0;
}

static int spawn_child(const char *self, const char *mode, const char *home, int with_hud)
{
	char **parent = *_NSGetEnviron();
	int n = 0;
	while (parent[n] != NULL)
		n++;
	char **env = calloc((size_t)n + 6, sizeof(char *));
	int k = 0;
	for (int i = 0; i < n; i++)
		if (strncmp(parent[i], "NOTPROTON_", 10) != 0 && strncmp(parent[i], "MTL_HUD_ENABLED=", 16) != 0 &&
		    strncmp(parent[i], "HOME=", 5) != 0 && strncmp(parent[i], "SteamAppId=", 11) != 0)
			env[k++] = parent[i];
	char child_var[64], home_var[1100];
	snprintf(child_var, sizeof(child_var), "NP_QUICK_TEST_CHILD=%s", mode);
	snprintf(home_var, sizeof(home_var), "HOME=%s", home);
	env[k++] = child_var;
	env[k++] = home_var;
	env[k++] = "SteamAppId=4242";
	char shim_var[1100];
	snprintf(shim_var, sizeof(shim_var), "NOTPROTON_OVERLAY_SHIM=%s", getenv("NOTPROTON_OVERLAY_SHIM"));
	env[k++] = shim_var;
	if (with_hud)
		env[k++] = "MTL_HUD_ENABLED=1";
	env[k] = NULL;

	pid_t pid;
	char *argv[] = { (char *)self, NULL };
	int rc = posix_spawn(&pid, self, NULL, NULL, argv, env);
	free(env);
	CHECK(rc == 0, "spawning %s failed", self);
	int status = 0;
	CHECK(waitpid(pid, &status, 0) == pid, "waiting for the %s child failed", mode);
	CHECK(WIFEXITED(status), "the %s child crashed", mode);
	return WEXITSTATUS(status);
}

int main(int argc, char **argv)
{
	const char *path = getenv("NOTPROTON_OVERLAY_SHIM");
	const char *mode = getenv("NP_QUICK_TEST_CHILD");
	(void)argc;

	SKIP_IF(path == NULL, "NOTPROTON_OVERLAY_SHIM names the shim to load");
	if (mode != NULL)
		return child(path, mode, getenv("HOME"));

	char tmpl[] = "/tmp/np-quick-XXXXXX";
	char *home = mkdtemp(tmpl);
	CHECK(home != NULL, "no temporary home");
	char support[1100];
	snprintf(support, sizeof(support), "mkdir -p '%s/Library/Application Support/bridgeplay'", home);
	system(support);
	int rc = spawn_child(argv[0], "live", home, 0);
	if (rc == 0) {
		snprintf(support, sizeof(support), "rm -rf '%s/Library/Application Support/bridgeplay/quick-settings'", home);
		system(support);
		rc = spawn_child(argv[0], "hud", home, 1);
	}
	snprintf(support, sizeof(support), "rm -rf '%s'", home);
	system(support);
	return rc;
}
