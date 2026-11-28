#import <CoreFoundation/CoreFoundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import <crt_externs.h>
#import <dlfcn.h>
#import <math.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>

#import "check.h"

// Cool and steady: inert without NOTPROTON_SUSTAINED=1; a forced thermal serious steps a 60 fps
// limit down and the game runs at the lower rate; critical steps further; it steps back only
// after 30 seconds cooler; with no limit of its own a step turns display sync on, and the
// game's VSync off comes back once it is cool again. The step's rates stay even divisors of
// the display and never go below 30.

typedef void (*limit_probe_fn)(int *, double *, int *, int *);
typedef int (*tick_fn)(int, double);
typedef double (*rate_fn)(double, int, int);

static double present_flat_out(id<MTLDevice> device, CAMetalLayer *layer, double seconds)
{
	id<MTLCommandQueue> queue = [device newCommandQueue];
	double start = CACurrentMediaTime();
	int frames = 0;

	while (CACurrentMediaTime() - start < seconds) {
		@autoreleasepool {
			id<CAMetalDrawable> drawable = [layer nextDrawable];
			if (drawable == nil)
				return -1;
			id<MTLCommandBuffer> buffer = [queue commandBuffer];
			MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
			pass.colorAttachments[0].texture = drawable.texture;
			pass.colorAttachments[0].loadAction = MTLLoadActionClear;
			pass.colorAttachments[0].storeAction = MTLStoreActionStore;
			[[buffer renderCommandEncoderWithDescriptor:pass] endEncoding];
			[buffer presentDrawable:drawable];
			[buffer commit];
			frames++;
		}
	}
	return frames / (CACurrentMediaTime() - start);
}

// A few frames, then the main queue, where the shim sets display sync
static void settle(id<MTLDevice> device, CAMetalLayer *layer)
{
	present_flat_out(device, layer, 0.2);
	CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
}

static int child(const char *path, const char *mode)
{
	void *shim = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	CHECK(shim != NULL, "%s does not load: %s", path, dlerror());
	limit_probe_fn probe = (limit_probe_fn)dlsym(shim, "np_framelimit_probe");
	tick_fn tick = (tick_fn)dlsym(shim, "np_sustained_tick");
	rate_fn rate = (rate_fn)dlsym(shim, "np_sustained_rate");
	CHECK(probe != NULL && tick != NULL && rate != NULL, "%s exports no sustained test entries", path);

	if (strcmp(mode, "rates") == 0) {
		// base, display rate (0 unknown), step, the cap
		static const double cases[][4] = {
			{ 60, 60, 1, 30 },   { 60, 60, 2, 30 },  { 120, 120, 1, 60 }, { 120, 120, 2, 60 },
			{ 60, 120, 1, 40 },  { 60, 120, 2, 30 }, { 144, 144, 1, 72 }, { 60, 0, 1, 45 },
			{ 60, 0, 2, 30 },    { 50, 50, 1, 38 },  { 30, 60, 1, 30 },   { 20, 60, 2, 20 },
			{ 60, 60, 0, 60 },   { 90, 120, 1, 60 },
		};
		for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
			double got = rate(cases[i][0], (int)cases[i][1], (int)cases[i][2]);
			CHECK(got == cases[i][3], "a limit of %.0f at %.0f Hz, step %.0f, gives %.1f, not %.0f", cases[i][0],
			      cases[i][1], cases[i][2], got, cases[i][3]);
		}
		printf("%-10s %zu rates: even display divisors, never below 30, never above the limit\n", mode,
		       sizeof(cases) / sizeof(cases[0]));
		return 0;
	}

	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	SKIP_IF(device == nil, "no Metal device on this machine");
	CAMetalLayer *layer = [CAMetalLayer layer];
	layer.device = device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.drawableSize = CGSizeMake(64, 64);
	layer.displaySyncEnabled = NO; // what a game asks for with VSync off

	int limit = -1, waits = -1, vsync = -1;
	double cap = -2;

	if (strcmp(mode, "off") == 0) {
		CHECK(tick(2, 100) == -1, "the step moved without NOTPROTON_SUSTAINED");
		double fps = present_flat_out(device, layer, 1.0);
		probe(&limit, &cap, &waits, &vsync);
		CHECK(cap == 60 && fps > 55 && fps < 62, "without the switch a hot Mac gave cap %.1f, %.1f fps", cap, fps);
		printf("%-10s 60 stays 60 when hot, %.0f fps\n", mode, fps);
		return 0;
	}

	if (strcmp(mode, "alone") == 0) {
		double fps = present_flat_out(device, layer, 0.5);
		probe(&limit, &cap, &waits, &vsync);
		CHECK(cap == -1 && vsync == 0 && !layer.displaySyncEnabled, "cool, the switch alone limited the game");
		CHECK(fps > 90, "cool, the switch alone held the game to %.1f fps", fps);
		CHECK(tick(2, 100) == 1, "thermal serious did not step");
		settle(device, layer);
		probe(&limit, &cap, &waits, &vsync);
		// No window, so no display rate: the step is display sync alone here
		CHECK(cap == 0 && vsync == 1 && layer.displaySyncEnabled, "hot, cap %.1f vsync %d layer %d", cap, vsync,
		      layer.displaySyncEnabled);
		CHECK(tick(0, 101) == 1 && tick(0, 131) == 0, "cool for 30 s did not step back");
		settle(device, layer);
		probe(&limit, &cap, &waits, &vsync);
		CHECK(cap == -1 && vsync == 0 && !layer.displaySyncEnabled, "cool again, the game's VSync off did not return");
		printf("%-10s no limit: hot turns display sync on, cool gives the game its VSync off back\n", mode);
		return 0;
	}

	// steps: a 60 fps limit, then serious, critical and cool again
	double fps = present_flat_out(device, layer, 1.0);
	probe(&limit, &cap, &waits, &vsync);
	CHECK(limit == 3 && cap == 60 && fps > 55 && fps < 62, "cool: cap %.1f, %.1f fps, not 60", cap, fps);
	CHECK(tick(1, 100) == 0, "thermal fair stepped");
	CHECK(tick(2, 101) == 1, "thermal serious did not step");
	fps = present_flat_out(device, layer, 2.0);
	probe(&limit, &cap, &waits, &vsync);
	CHECK(cap == 45 && fps > 42 && fps < 46, "serious: cap %.1f, %.1f fps, not 45", cap, fps);
	CHECK(tick(3, 102) == 2, "thermal critical did not step further");
	probe(&limit, &cap, &waits, &vsync);
	CHECK(cap == 30, "critical: cap %.1f, not 30", cap);
	CHECK(tick(0, 103) == 2 && tick(0, 120) == 2, "it stepped back before 30 s cooler");
	// Serious after critical counts as cooler: back to step 1 once 30 s have passed since 103
	CHECK(tick(2, 125) == 2 && tick(2, 140) == 1, "serious after critical did not step back to 1 after 30 s");
	CHECK(tick(0, 141) == 1 && tick(0, 171) == 0, "30 s cooler did not step back");
	probe(&limit, &cap, &waits, &vsync);
	CHECK(limit == 3 && cap == 60, "cool again: mode %d cap %.1f, not the 60 as set", limit, cap);
	printf("%-10s 60 as set, serious 45 (%.0f fps), critical 30, back to 60 after 30 s cooler\n", mode, fps);
	return 0;
}

static int spawn_child(const char *self, const char *mode, const char *limit, int sustained)
{
	char **parent = *_NSGetEnviron();
	int n = 0;
	while (parent[n] != NULL)
		n++;
	char **env = calloc((size_t)n + 5, sizeof(char *));
	int k = 0;
	for (int i = 0; i < n; i++)
		if (strncmp(parent[i], "NOTPROTON_FPS_LIMIT", 19) != 0 && strncmp(parent[i], "NOTPROTON_SUSTAINED=", 20) != 0 &&
		    strncmp(parent[i], "NOTPROTON_PERF_OVERLAY=", 23) != 0 &&
		    strncmp(parent[i], "NOTPROTON_VSYNC=", 16) != 0 && strncmp(parent[i], "MTL_HUD_ENABLED=", 16) != 0)
			env[k++] = parent[i];
	char child_var[64], limit_var[64];
	snprintf(child_var, sizeof(child_var), "NP_SUSTAINED_TEST_CHILD=%s", mode);
	env[k++] = child_var;
	if (limit != NULL) {
		snprintf(limit_var, sizeof(limit_var), "NOTPROTON_FPS_LIMIT=%s", limit);
		env[k++] = limit_var;
	}
	if (sustained)
		env[k++] = "NOTPROTON_SUSTAINED=1";
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
	const char *mode = getenv("NP_SUSTAINED_TEST_CHILD");
	(void)argc;

	SKIP_IF(path == NULL, "NOTPROTON_OVERLAY_SHIM names the shim to load");
	if (mode != NULL)
		return child(path, mode);

	int rc;
	if ((rc = spawn_child(argv[0], "rates", NULL, 1)) != 0)
		return rc;
	if ((rc = spawn_child(argv[0], "off", "60", 0)) != 0)
		return rc;
	if ((rc = spawn_child(argv[0], "alone", NULL, 1)) != 0)
		return rc;
	return spawn_child(argv[0], "steps", "60", 1);
}
