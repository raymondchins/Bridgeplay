#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import <crt_externs.h>
#import <dirent.h>
#import <dlfcn.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

#import "check.h"

// Frame-time capture: without NOTPROTON_BENCH nothing is written; with it, frame generation
// stays off even when asked for, and the game's frames land in one file per process under
// <support>/launchers/<appid>/bench/, with a header and one frame time per line; old files
// past the newest 20 are removed, other files there are not.

typedef void (*bench_probe_fn)(int *, int *, unsigned long long *);

static int child(const char *path, const char *mode)
{
	void *shim = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	CHECK(shim != NULL, "%s does not load: %s", path, dlerror());
	bench_probe_fn probe = (bench_probe_fn)dlsym(shim, "np_bench_probe");
	CHECK(probe != NULL, "%s exports no np_bench_probe", path);

	id<MTLDevice> device = MTLCreateSystemDefaultDevice();
	SKIP_IF(device == nil, "no Metal device on this machine");
	CAMetalLayer *layer = [CAMetalLayer layer];
	layer.device = device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.drawableSize = CGSizeMake(64, 64);
	id<MTLCommandQueue> queue = [device newCommandQueue];

	int frames = 0;
	double start = CACurrentMediaTime();
	while (CACurrentMediaTime() - start < 1.5) {
		@autoreleasepool {
			id<CAMetalDrawable> drawable = [layer nextDrawable];
			CHECK(drawable != nil, "offscreen layer vends no drawable");
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

	int on = -1, framegen = -1;
	unsigned long long noted = 0;
	probe(&on, &framegen, &noted);
	if (strcmp(mode, "off") == 0) {
		CHECK(on == 0 && noted == 0, "bench on (%d, %llu frames) without NOTPROTON_BENCH", on, noted);
		return 0;
	}
	CHECK(on == 1, "NOTPROTON_BENCH=1 did not turn the capture on");
	CHECK(framegen == 0, "frame generation is on while benching");
	CHECK(noted + 1 >= (unsigned long long)frames - 1, "noted %llu of %d frames", noted, frames);
	printf("%d\n", frames);
	return 0; // exit runs the shim's final write
}

static int run_child(const char *self, const char *mode, const char *home, int *frames)
{
	char **parent = *_NSGetEnviron();
	int n = 0;
	while (parent[n] != NULL)
		n++;
	char **env = calloc((size_t)n + 8, sizeof(char *));
	int k = 0;
	for (int i = 0; i < n; i++)
		if (strncmp(parent[i], "NOTPROTON_", 10) != 0 && strncmp(parent[i], "BRIDGEPLAY_", 11) != 0 &&
		    strncmp(parent[i], "HOME=", 5) != 0 && strncmp(parent[i], "Steam", 5) != 0 &&
		    strncmp(parent[i], "STEAM_COMPAT_APP_ID=", 20) != 0 && strncmp(parent[i], "MTL_HUD_ENABLED=", 16) != 0)
			env[k++] = parent[i];
	char child_var[64], home_var[1100], shim_var[1100];
	snprintf(child_var, sizeof(child_var), "NP_BENCH_TEST_CHILD=%s", mode);
	snprintf(home_var, sizeof(home_var), "HOME=%s", home);
	snprintf(shim_var, sizeof(shim_var), "NOTPROTON_OVERLAY_SHIM=%s", getenv("NOTPROTON_OVERLAY_SHIM"));
	env[k++] = child_var;
	env[k++] = home_var;
	env[k++] = shim_var;
	env[k++] = "SteamAppId=4242";
	env[k++] = strcmp(mode, "off") == 0 ? "NOTPROTON_PERF_OVERLAY=fps" : "NOTPROTON_BENCH=1";
	if (strcmp(mode, "on") == 0)
		env[k++] = "NOTPROTON_FRAMEGEN=2";
	env[k] = NULL;

	int out[2];
	CHECK(pipe(out) == 0, "pipe failed");
	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_adddup2(&actions, out[1], 1);
	posix_spawn_file_actions_addclose(&actions, out[0]);
	pid_t pid;
	char *argv[] = { (char *)self, NULL };
	int rc = posix_spawn(&pid, self, &actions, NULL, argv, env);
	posix_spawn_file_actions_destroy(&actions);
	free(env);
	close(out[1]);
	CHECK(rc == 0, "spawning %s failed", self);
	char buf[4096] = { 0 };
	ssize_t got, used = 0;
	while ((got = read(out[0], buf + used, sizeof(buf) - 1 - (size_t)used)) > 0)
		used += got;
	close(out[0]);
	int status = 0;
	CHECK(waitpid(pid, &status, 0) == pid, "waiting for the %s child failed", mode);
	CHECK(WIFEXITED(status), "the %s child crashed", mode);
	if (WEXITSTATUS(status) != 0) {
		fputs(buf, stdout);
		return WEXITSTATUS(status);
	}
	*frames = atoi(buf);
	return 0;
}

static int count_csv(const char *dir, char *newest, size_t cap)
{
	DIR *d = opendir(dir);
	if (d == NULL)
		return -1;
	int count = 0;
	struct dirent *e;
	newest[0] = '\0';
	while ((e = readdir(d)) != NULL) {
		size_t n = strlen(e->d_name);
		if (n > 4 && strcmp(e->d_name + n - 4, ".csv") == 0) {
			count++;
			if (strcmp(e->d_name, newest) > 0)
				snprintf(newest, cap, "%s", e->d_name);
		}
	}
	closedir(d);
	return count;
}

static int check_files(const char *self, const char *home)
{
	char dir[1100], path[1400], newest[256];
	snprintf(dir, sizeof(dir), "%s/Library/Application Support/bridgeplay/launchers/4242/bench", home);
	struct stat st;
	int frames = 0, rc;

	if ((rc = run_child(self, "off", home, &frames)) != 0)
		return rc;
	CHECK(stat(dir, &st) != 0, "a bench folder was made without NOTPROTON_BENCH");

	// Older captures, and a file of someone else's that must stay
	char cmd[1300];
	snprintf(cmd, sizeof(cmd), "mkdir -p '%s'", dir);
	CHECK(system(cmd) == 0, "cannot make %s", dir);
	for (int i = 0; i < 25; i++) {
		snprintf(path, sizeof(path), "%s/2001%04dT000000Z-1.csv", dir, i);
		FILE *f = fopen(path, "w");
		CHECK(f != NULL, "cannot write %s", path);
		fclose(f);
	}
	snprintf(path, sizeof(path), "%s/notes.txt", dir);
	FILE *keep = fopen(path, "w");
	CHECK(keep != NULL, "cannot write %s", path);
	fclose(keep);

	if ((rc = run_child(self, "on", home, &frames)) != 0)
		return rc;
	CHECK(stat(path, &st) == 0, "pruning removed a file that is not a capture");
	int count = count_csv(dir, newest, sizeof(newest));
	CHECK(count == 20, "%d captures kept, not 20", count);
	snprintf(path, sizeof(path), "%s/2001%04dT000000Z-1.csv", dir, 5);
	CHECK(stat(path, &st) != 0, "the oldest captures were kept");
	CHECK(strncmp(newest, "2001", 4) != 0, "no new capture was written");

	snprintf(path, sizeof(path), "%s/%s", dir, newest);
	FILE *f = fopen(path, "r");
	CHECK(f != NULL, "cannot read %s", path);
	char line[512];
	int lines = 0, header = 0, appid = 0, forced = 0, end = 0, bad = 0;
	while (fgets(line, sizeof(line), f) != NULL) {
		if (line[0] == '#') {
			header += strcmp(line, "# bridgeplay-bench 1\n") == 0;
			appid += strcmp(line, "# appid=4242\n") == 0;
			forced += strcmp(line, "# framegen=forced-off\n") == 0;
			end += strcmp(line, "# end\n") == 0;
			continue;
		}
		double ms = atof(line);
		if (!(ms > 0 && ms < 1000))
			bad++;
		lines++;
	}
	fclose(f);
	CHECK(header == 1 && appid == 1 && forced == 1, "header incomplete in %s", newest);
	CHECK(end == 1, "the capture was not closed at exit");
	CHECK(bad == 0, "%d frame times out of range", bad);
	CHECK(lines >= frames - 2 && lines <= frames, "%d frame times for %d frames", lines, frames);
	printf("off: nothing written; on: %d frame times for %d frames, framegen forced off, 20 kept\n", lines,
	       frames);
	return 0;
}

int main(int argc, char **argv)
{
	(void)argc;
	const char *path = getenv("NOTPROTON_OVERLAY_SHIM");
	const char *mode = getenv("NP_BENCH_TEST_CHILD");

	SKIP_IF(path == NULL, "NOTPROTON_OVERLAY_SHIM names the shim to load");
	if (mode != NULL)
		return child(path, mode);

	const char *tmp = getenv("TMPDIR");
	char work[1024];
	snprintf(work, sizeof(work), "%s/np-bench.XXXXXX", tmp != NULL && tmp[0] ? tmp : "/tmp");
	CHECK(mkdtemp(work) != NULL, "mkdtemp failed");
	int rc = check_files(argv[0], work);
	char cmd[1100];
	snprintf(cmd, sizeof(cmd), "rm -rf '%s'", work);
	system(cmd);
	return rc;
}
