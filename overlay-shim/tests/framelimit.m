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

// Frame rate limit: inert without NOTPROTON_FPS_LIMIT; a fixed limit holds a game that
// could go far faster to that rate and turns display sync on; the overlay counts the
// frames the game actually made; a display-relative limit without a known display only
// syncs; a value out of range is refused; NOTPROTON_FPS_LIMIT_OFF=1 keeps the value and
// limits nothing; a value from before the 15 fps floor holds at 15.

typedef void (*limit_probe_fn)(int *, double *, int *, int *);
typedef void (*hud_probe_fn)(int *, int *, int *, double *, int *, int *);

// As fast as the layer gives drawables, for the given time; returns frames per second.
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

static int child(const char *path, const char *mode)
{
	void *shim = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	CHECK(shim != NULL, "%s does not load: %s", path, dlerror());
	limit_probe_fn probe = (limit_probe_fn)dlsym(shim, "np_framelimit_probe");
	hud_probe_fn hud = (hud_probe_fn)dlsym(shim, "np_perfhud_probe");
	CHECK(probe != NULL && hud != NULL, "%s exports no np_framelimit_probe or np_perfhud_probe", path);

	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	SKIP_IF(device == nil, "no Metal device on this machine");
	CAMetalLayer *layer = [CAMetalLayer layer];
	layer.device = device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.drawableSize = CGSizeMake(64, 64);
	layer.displaySyncEnabled = NO; // what a game asks for with VSync off

	double fps = present_flat_out(device, layer, 2.0);
	CHECK(fps > 0, "offscreen layer vends no drawable");

	int limit = -1, waits = -1, vsync = -1, level = -1, frames = -1, attached = -1, cpu = 0, gpu = 0;
	double cap = -2, hud_fps = -2;
	probe(&limit, &cap, &waits, &vsync);
	hud(&level, &frames, &attached, &hud_fps, &cpu, &gpu);

	if (strcmp(mode, "off") == 0 || strcmp(mode, "refused") == 0) {
		CHECK(limit == 0 && cap == -1, "limit %d cap %.1f with %s", limit, cap, mode);
		CHECK(waits == 0, "the game waited %d times without a limit", waits);
		CHECK(vsync == 0, "display sync forced without a limit");
		CHECK(!layer.displaySyncEnabled, "the game's VSync off was overridden without a limit");
		CHECK(fps > 90, "the game ran at only %.1f fps without a limit", fps);
		printf("%-10s no limit, %.0f fps flat out, the game's VSync left alone\n", mode, fps);
		return 0;
	}

	if (strcmp(mode, "switched-off") == 0) {
		CHECK(limit == 3 && cap == -1, "a limit switched off has mode %d cap %.1f, not the kept 30 and no cap", limit,
		      cap);
		CHECK(waits == 0 && vsync == 0 && !layer.displaySyncEnabled, "a limit switched off still paced the game");
		CHECK(fps > 90, "a limit switched off held the game to %.1f fps", fps);
		printf("%-10s 30 kept, switched off: %.0f fps flat out, the game's VSync left alone\n", mode, fps);
		return 0;
	}

	if (strcmp(mode, "floor") == 0) {
		CHECK(limit == 3 && cap == 15, "a limit of 10 has mode %d cap %.1f, not 15", limit, cap);
		CHECK(fps > 13 && fps < 16, "a limit of 10 let the game run at %.1f fps, not 15", fps);
		printf("%-10s 10 from an earlier release holds at %.1f fps, the 15 floor\n", mode, fps);
		return 0;
	}

	if (strcmp(mode, "display") == 0) {
		// No window and no AppKit, so no display rate: only display sync applies
		CHECK(limit == 1 && cap == 0, "display limit %d cap %.1f without a display", limit, cap);
		CHECK(vsync == 1 && layer.displaySyncEnabled, "a display limit did not turn display sync on");
		CHECK(waits == 0, "the game waited %d times for an unknown display rate", waits);
		printf("%-10s display sync on, no waits without a known display rate\n", mode);
		return 0;
	}

	CHECK(limit == 3 && cap == 30, "fixed limit %d cap %.1f for 30", limit, cap);
	CHECK(vsync == 1 && layer.displaySyncEnabled, "the limit did not turn display sync on");
	CHECK(waits > 30, "the game waited only %d times", waits);
	CHECK(fps > 27 && fps < 31, "a 30 fps limit let the game run at %.1f fps", fps);
	// The overlay counts what was made, read while its last window still had frames in it; a
	// window's edges can catch one frame more than 30 a second
	CHECK(level == 2 && hud_fps > 20 && hud_fps <= 32.5, "the overlay measured %.1f fps under a 30 limit", hud_fps);
	printf("%-10s %.1f fps flat out under 30, overlay %.1f fps, %d waits, display sync on\n", mode, fps,
	       hud_fps, waits);
	return 0;
}

static int spawn_child(const char *self, const char *mode, const char *limit, int off)
{
	char **parent = *_NSGetEnviron();
	int n = 0;
	while (parent[n] != NULL)
		n++;
	char **env = calloc((size_t)n + 5, sizeof(char *));
	int k = 0;
	for (int i = 0; i < n; i++)
		if (strncmp(parent[i], "NOTPROTON_FPS_LIMIT=", 20) != 0 &&
		    strncmp(parent[i], "NOTPROTON_FPS_LIMIT_OFF=", 24) != 0 &&
		    strncmp(parent[i], "NOTPROTON_PERF_OVERLAY=", 23) != 0 &&
		    strncmp(parent[i], "NOTPROTON_VSYNC=", 16) != 0 && strncmp(parent[i], "MTL_HUD_ENABLED=", 16) != 0)
			env[k++] = parent[i];
	char child_var[64], limit_var[64];
	snprintf(child_var, sizeof(child_var), "NP_FRAMELIMIT_TEST_CHILD=%s", mode);
	env[k++] = child_var;
	env[k++] = "NOTPROTON_PERF_OVERLAY=summary";
	if (limit != NULL) {
		snprintf(limit_var, sizeof(limit_var), "NOTPROTON_FPS_LIMIT=%s", limit);
		env[k++] = limit_var;
	}
	if (off)
		env[k++] = "NOTPROTON_FPS_LIMIT_OFF=1";
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
	const char *mode = getenv("NP_FRAMELIMIT_TEST_CHILD");
	(void)argc;

	SKIP_IF(path == NULL, "NOTPROTON_OVERLAY_SHIM names the shim to load");
	if (mode != NULL)
		return child(path, mode);

	int rc;
	if ((rc = spawn_child(argv[0], "off", NULL, 0)) != 0)
		return rc;
	if ((rc = spawn_child(argv[0], "refused", "5", 0)) != 0)
		return rc;
	if ((rc = spawn_child(argv[0], "display", "display", 0)) != 0)
		return rc;
	if ((rc = spawn_child(argv[0], "switched-off", "30", 1)) != 0)
		return rc;
	if ((rc = spawn_child(argv[0], "floor", "10", 0)) != 0)
		return rc;
	return spawn_child(argv[0], "fixed", "30", 0);
}
