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

// Scaling filter: without NOTPROTON_SCALING_FILTER the layer keeps Core Animation's own
// linear filter; nearest sets nearest; integer sets nearest at a whole-number scale and
// linear otherwise; a filter it does not know is left alone.

typedef void (*probe_fn)(int *, int *, double *);

static int child(const char *path, const char *mode, double drawable_width)
{
	void *shim = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	CHECK(shim != NULL, "%s does not load: %s", path, dlerror());
	probe_fn probe = (probe_fn)dlsym(shim, "np_scalefilter_probe");
	CHECK(probe != NULL, "%s exports no np_scalefilter_probe", path);

	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	SKIP_IF(device == nil, "no Metal device on this machine");
	CAMetalLayer *layer = [CAMetalLayer layer];
	layer.device = device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	// No window, so the screen scale is the layer's own (1): 640 points over a smaller drawable
	layer.bounds = CGRectMake(0, 0, 640, 360);
	layer.drawableSize = CGSizeMake(drawable_width, drawable_width * 360 / 640);

	id<MTLCommandQueue> queue = [device newCommandQueue];
	for (int i = 0; i < 10; i++) {
		@autoreleasepool {
			id<CAMetalDrawable> drawable = [layer nextDrawable];
			CHECK(drawable != nil, "offscreen layer vends no drawable");
			id<MTLCommandBuffer> buffer = [queue commandBuffer];
			[buffer presentDrawable:drawable];
			[buffer commit];
			[buffer waitUntilCompleted];
		}
	}
	[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];

	int set = -1, filter = -1;
	double scale = -1;
	probe(&set, &filter, &scale);
	NSString *got = layer.magnificationFilter;

	if (strcmp(mode, "off") == 0 || strcmp(mode, "refused") == 0) {
		CHECK(set == 0 && filter == 0, "mode %d filter %d with %s", set, filter, mode);
		CHECK([got isEqualToString:kCAFilterLinear], "the layer's filter became %s with %s", got.UTF8String, mode);
		printf("%-10s layer left at Core Animation's linear filter\n", mode);
		return 0;
	}

	int want_nearest = strcmp(mode, "nearest") == 0 || strcmp(mode, "integer-2x") == 0;
	NSString *want = want_nearest ? kCAFilterNearest : kCAFilterLinear;
	CHECK([got isEqualToString:want], "%s: layer filter %s, wanted %s at %.2fx", mode, got.UTF8String,
	      want.UTF8String, scale);
	CHECK(filter == (want_nearest ? 2 : 1), "%s: probe says filter %d", mode, filter);
	CHECK(scale > 1.9, "%s: measured scale %.2f for a smaller drawable", mode, scale);
	printf("%-10s %s at %.2fx\n", mode, got.UTF8String, scale);
	return 0;
}

static int spawn_child(const char *self, const char *mode, const char *setting, const char *width)
{
	char **parent = *_NSGetEnviron();
	int n = 0;
	while (parent[n] != NULL)
		n++;
	char **env = calloc((size_t)n + 4, sizeof(char *));
	int k = 0;
	for (int i = 0; i < n; i++)
		if (strncmp(parent[i], "NOTPROTON_SCALING_FILTER=", 25) != 0)
			env[k++] = parent[i];
	char child_var[96], setting_var[64];
	snprintf(child_var, sizeof(child_var), "NP_SCALEFILTER_TEST_CHILD=%s:%s", mode, width);
	env[k++] = child_var;
	if (setting != NULL) {
		snprintf(setting_var, sizeof(setting_var), "NOTPROTON_SCALING_FILTER=%s", setting);
		env[k++] = setting_var;
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
	const char *spec = getenv("NP_SCALEFILTER_TEST_CHILD");
	(void)argc;

	SKIP_IF(path == NULL, "NOTPROTON_OVERLAY_SHIM names the shim to load");
	if (spec != NULL) {
		char mode[64];
		snprintf(mode, sizeof(mode), "%s", spec);
		char *colon = strchr(mode, ':');
		double width = colon != NULL ? atof(colon + 1) : 320;
		if (colon != NULL)
			*colon = '\0';
		return child(path, mode, width);
	}

	int rc;
	if ((rc = spawn_child(argv[0], "off", NULL, "320")) != 0)
		return rc;
	if ((rc = spawn_child(argv[0], "refused", "fsr", "320")) != 0)
		return rc;
	if ((rc = spawn_child(argv[0], "nearest", "nearest", "300")) != 0)
		return rc;
	if ((rc = spawn_child(argv[0], "integer-2x", "integer", "320")) != 0)
		return rc;
	if ((rc = spawn_child(argv[0], "integer-odd", "integer", "300")) != 0)
		return rc;
	return spawn_child(argv[0], "linear", "linear", "320");
}
