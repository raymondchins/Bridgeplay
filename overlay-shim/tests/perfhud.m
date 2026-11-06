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

// Performance overlay: inert without NOTPROTON_PERF_OVERLAY, and with it a layer that
// presents gets the overlay on top, measured at the rate the frames came in, with CPU and
// GPU read from the Mac. The Metal HUD wins when both are set.

typedef void (*probe_fn)(int *, int *, int *, double *, int *, int *);

static int present_frames(id<MTLDevice> device, CAMetalLayer *layer, int frames, int spacing_us)
{
	id<MTLCommandQueue> queue = [device newCommandQueue];
	double start = CACurrentMediaTime();

	for (int i = 0; i < frames; i++) {
		@autoreleasepool {
			id<CAMetalDrawable> drawable = [layer nextDrawable];
			if (drawable == nil)
				return 0;
			id<MTLCommandBuffer> buffer = [queue commandBuffer];
			MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
			pass.colorAttachments[0].texture = drawable.texture;
			pass.colorAttachments[0].loadAction = MTLLoadActionClear;
			pass.colorAttachments[0].storeAction = MTLStoreActionStore;
			[[buffer renderCommandEncoderWithDescriptor:pass] endEncoding];
			[buffer presentDrawable:drawable];
			[buffer commit];
			[buffer waitUntilCompleted];
			double wait = start + (i + 1) * spacing_us * 1e-6 - CACurrentMediaTime();
			if (wait > 0)
				usleep((useconds_t)(wait * 1e6));
		}
	}
	return 1;
}

static int child(const char *path, const char *mode)
{
	void *shim = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	CHECK(shim != NULL, "%s does not load: %s", path, dlerror());
	probe_fn probe = (probe_fn)dlsym(shim, "np_perfhud_probe");
	CHECK(probe != NULL, "%s exports no np_perfhud_probe", path);

	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	SKIP_IF(device == nil, "no Metal device on this machine");
	CAMetalLayer *layer = [CAMetalLayer layer];
	layer.device = device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.bounds = CGRectMake(0, 0, 640, 360);
	layer.drawableSize = CGSizeMake(640, 360);

	// 50 fps for 1.6 s: three overlay ticks with frames behind them
	CHECK(present_frames(device, layer, 80, 20000), "offscreen layer vends no drawable");
	[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];

	int level = -1, frames = -1, attached = -1, cpu = -2, gpu = -2;
	double fps = -2;
	probe(&level, &frames, &attached, &fps, &cpu, &gpu);

	if (strcmp(mode, "off") == 0 || strcmp(mode, "hud") == 0) {
		CHECK(level == 0, "overlay level %d with %s", level, mode);
		CHECK(frames == 0, "overlay counted %d frames while off", frames);
		CHECK(attached == 0, "overlay attached while off");
		CHECK(layer.sublayers.count == 0, "the game layer got %lu sublayers while off",
		      (unsigned long)layer.sublayers.count);
		printf("%-10s %s\n", mode, "no overlay, no frames counted");
		return 0;
	}

	CHECK(level == 3, "overlay level %d for detailed", level);
	CHECK(frames == 80, "overlay counted %d of 80 frames", frames);
	CHECK(attached == 1, "overlay never attached to the presenting layer");
	CHECK(layer.sublayers.count == 1, "the game layer has %lu sublayers, not the overlay's one",
	      (unsigned long)layer.sublayers.count);
	CALayer *hud = layer.sublayers[0];
	CHECK(hud.contents != nil, "the overlay layer has no image");
	CHECK(hud.zPosition > 1000, "the overlay sits under framegen's layer (z %.0f)", hud.zPosition);
	// The last tick may have seen the frames stop, so allow for a short window
	CHECK(fps > 20 && fps < 60, "overlay measured %.1f fps for 50 fps frames", fps);
	CHECK(cpu >= 0 && cpu <= 100, "overlay read CPU %d%%", cpu);
	printf("%-10s overlay attached, %.1f fps measured, CPU %d%%, GPU %d%%\n", mode, fps, cpu, gpu);
	return 0;
}

static int spawn_child(const char *self, const char *mode, const char *setting, const char *hud)
{
	char **parent = *_NSGetEnviron();
	int n = 0;
	while (parent[n] != NULL)
		n++;
	char **env = calloc((size_t)n + 4, sizeof(char *));
	int k = 0;
	for (int i = 0; i < n; i++)
		if (strncmp(parent[i], "NOTPROTON_PERF_OVERLAY=", 23) != 0 &&
		    strncmp(parent[i], "MTL_HUD_ENABLED=", 16) != 0)
			env[k++] = parent[i];
	char child_var[64], setting_var[64], hud_var[64];
	snprintf(child_var, sizeof(child_var), "NP_PERFHUD_TEST_CHILD=%s", mode);
	env[k++] = child_var;
	if (setting != NULL) {
		snprintf(setting_var, sizeof(setting_var), "NOTPROTON_PERF_OVERLAY=%s", setting);
		env[k++] = setting_var;
	}
	if (hud != NULL) {
		snprintf(hud_var, sizeof(hud_var), "MTL_HUD_ENABLED=%s", hud);
		env[k++] = hud_var;
	}
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
	const char *mode = getenv("NP_PERFHUD_TEST_CHILD");
	(void)argc;

	SKIP_IF(path == NULL, "NOTPROTON_OVERLAY_SHIM names the shim to load");
	if (mode != NULL)
		return child(path, mode);

	int rc;
	if ((rc = spawn_child(argv[0], "off", NULL, NULL)) != 0)
		return rc;
	if ((rc = spawn_child(argv[0], "off", "0", NULL)) != 0)
		return rc;
	if ((rc = spawn_child(argv[0], "hud", "detailed", "1")) != 0)
		return rc;
	return spawn_child(argv[0], "detailed", "detailed", NULL);
}
