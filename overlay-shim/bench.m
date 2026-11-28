// Frame-time capture: NOTPROTON_BENCH (BRIDGEPLAY_BENCH in launch options) = 1 writes the time
// between the game's frames, one line per frame in milliseconds, to
// <support>/launchers/<appid>/bench/<UTC time>-<pid>.csv. scripts/bench-summary.py reads it.
// Included by overlay_shim.m after sidebar.m, whose sb_support and sb_digits it uses.
//
// Frame generation is forced off while benching (framegen_init asks bench_wanted), so every
// frame counted is one the game rendered. The render thread only appends to a ring under a
// lock; a utility queue drains it to the file once a second. Nothing is opened until the
// first frame, so Wine's helper processes that load the shim and never draw leave no file.

#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <time.h>

#define bench_ring 8192 // over 20 s at 360 fps between drains
#define bench_keep 20 // newest files kept per game
#define bench_max_bytes (64L << 20)
#define bench_new_layer (-1.0f)

static int bench_state = -1; // -1 not read yet
static os_unfair_lock bench_lock = OS_UNFAIR_LOCK_INIT;
// Under bench_lock
static float bench_ms[bench_ring];
static uint64_t bench_head, bench_tail, bench_lost;
static double bench_last;
static uintptr_t bench_host; // identity only, never dereferenced
static int bench_started;

// On bench_queue
static dispatch_queue_t bench_queue;
static dispatch_source_t bench_timer;
static FILE *bench_file;
static uint64_t bench_lost_written;
static int bench_full;

static int bench_wanted(void)
{
	if (bench_state >= 0)
		return bench_state;
	const char *v = getenv("NOTPROTON_BENCH");
	if (v == NULL)
		v = getenv("BRIDGEPLAY_BENCH");
	bench_state = !(v == NULL || v[0] == '\0' || strcmp(v, "0") == 0 || strcasecmp(v, "off") == 0 ||
	                strcasecmp(v, "false") == 0 || strcasecmp(v, "no") == 0);
	return bench_state;
}

static int bench_name_ours(const char *name)
{
	size_t n = strlen(name);
	return n > 4 && name[0] >= '0' && name[0] <= '9' && strcmp(name + n - 4, ".csv") == 0;
}

static int bench_cmp(const void *a, const void *b)
{
	return strcmp(*(char *const *)a, *(char *const *)b);
}

// Leaves room for one more: removes the oldest of this shim's own files past bench_keep - 1.
// The names start with the UTC time, so name order is age order.
static void bench_prune(const char *dir)
{
	DIR *d = opendir(dir);
	if (d == NULL)
		return;
	char *names[256];
	int count = 0;
	struct dirent *e;
	while ((e = readdir(d)) != NULL && count < 256)
		if (bench_name_ours(e->d_name))
			names[count++] = strdup(e->d_name);
	closedir(d);
	qsort(names, (size_t)count, sizeof(names[0]), bench_cmp);
	for (int i = 0; i < count; i++) {
		if (i < count - (bench_keep - 1)) {
			char path[1200];
			snprintf(path, sizeof(path), "%s/%s", dir, names[i]);
			unlink(path);
		}
		free(names[i]);
	}
}

static int bench_mkdirs(char *path)
{
	for (char *p = path + 1; *p; p++) {
		if (*p != '/')
			continue;
		*p = '\0';
		int rc = mkdir(path, 0755);
		*p = '/';
		if (rc != 0 && errno != EEXIST)
			return -1;
	}
	return mkdir(path, 0755) == 0 || errno == EEXIST ? 0 : -1;
}

static void bench_sysctl(const char *name, char *out, size_t cap)
{
	size_t len = cap;
	if (sysctlbyname(name, out, &len, NULL, 0) != 0)
		snprintf(out, cap, "unknown");
}

static void bench_open(void)
{
	char support[1024], dir[1100], path[1200];
	sb_support(support, sizeof(support));
	if (support[0] == '\0' || !sb_digits(sb_appid)) {
		shim_log("overlay_shim bench: no %s, nothing recorded\n",
		         support[0] == '\0' ? "home folder" : "Steam app ID");
		return;
	}
	snprintf(dir, sizeof(dir), "%s/launchers/%s/bench", support, sb_appid);
	if (bench_mkdirs(dir) != 0) {
		shim_log("overlay_shim bench: cannot make %s: %s\n", dir, strerror(errno));
		return;
	}
	bench_prune(dir);

	time_t now = time(NULL);
	struct tm utc;
	gmtime_r(&now, &utc);
	char stamp[32], iso[32];
	strftime(stamp, sizeof(stamp), "%Y%m%dT%H%M%SZ", &utc);
	strftime(iso, sizeof(iso), "%Y-%m-%dT%H:%M:%SZ", &utc);
	snprintf(path, sizeof(path), "%s/%s-%d.csv", dir, stamp, getpid());
	int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
	if (fd < 0 || (bench_file = fdopen(fd, "w")) == NULL) {
		shim_log("overlay_shim bench: cannot write %s: %s\n", path, strerror(errno));
		if (fd >= 0)
			close(fd);
		return;
	}

	char chip[128], os[64];
	bench_sysctl("machdep.cpu.brand_string", chip, sizeof(chip));
	bench_sysctl("kern.osproductversion", os, sizeof(os));
	const char *fg = getenv("NOTPROTON_FRAMEGEN");
	int fg_asked = fg != NULL && fg[0] != '\0' && strcmp(fg, "0") != 0 && strcasecmp(fg, "off") != 0;
	double cap = framelimit_cap();
	char limit[32];
	if (cap > 0)
		snprintf(limit, sizeof(limit), "%.0f", cap);
	else
		snprintf(limit, sizeof(limit), "%s", cap < 0 ? "none" : "unknown");
	fprintf(bench_file,
	        "# bridgeplay-bench 1\n# appid=%s\n# exe=%s\n# pid=%d\n# started=%s\n# chip=%s\n# macos=%s\n"
	        "# framegen=%s\n# fps_limit=%s\n# frame_ms\n",
	        sb_appid, getprogname(), getpid(), iso, chip, os, fg_asked ? "forced-off" : "off", limit);
	shim_log("overlay_shim bench: recording frame times to %s\n", path);
}

static void bench_drain(int final)
{
	static float batch[bench_ring];
	uint64_t lost;
	unsigned n = 0;

	os_unfair_lock_lock(&bench_lock);
	while (bench_tail < bench_head)
		batch[n++] = bench_ms[bench_tail++ % bench_ring];
	lost = bench_lost;
	os_unfair_lock_unlock(&bench_lock);

	if (bench_file == NULL || bench_full)
		return;
	if (lost != bench_lost_written) {
		fprintf(bench_file, "# lost=%llu\n", (unsigned long long)(lost - bench_lost_written));
		bench_lost_written = lost;
	}
	for (unsigned i = 0; i < n; i++) {
		if (batch[i] == bench_new_layer)
			fputs("# layer\n", bench_file);
		else
			fprintf(bench_file, "%.3f\n", batch[i]);
	}
	if (ftell(bench_file) > bench_max_bytes) {
		fputs("# stopped=size limit\n", bench_file);
		bench_full = 1;
	}
	if (final)
		fputs("# end\n", bench_file);
	if (final || bench_full) {
		fclose(bench_file);
		bench_file = NULL;
	} else {
		fflush(bench_file);
	}
}

static void bench_finish(void)
{
	dispatch_sync(bench_queue, ^{
		bench_drain(1);
	});
}

static void bench_start(void)
{
	dispatch_queue_attr_t attr =
	        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
	bench_queue = dispatch_queue_create("com.bridgeplay.bench", attr);
	dispatch_async(bench_queue, ^{
		bench_open();
		if (bench_file == NULL)
			return;
		bench_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, bench_queue);
		dispatch_source_set_timer(bench_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
		                          NSEC_PER_SEC, NSEC_PER_SEC / 10);
		dispatch_source_set_event_handler(bench_timer, ^{
			bench_drain(0);
		});
		dispatch_resume(bench_timer);
	});
	atexit(bench_finish);
}

// Render thread, from hook_next_drawable, only while benching
static void bench_note_frame(id layer)
{
	if (fg_internal || layer == nil)
		return;
	double now = CACurrentMediaTime();
	int start = 0;

	os_unfair_lock_lock(&bench_lock);
	if ((uintptr_t)layer != bench_host) {
		// As the overlay does: a second window drawing at once is left out; a new one takes
		// over once the old one has gone quiet
		if (bench_host != 0 && now - bench_last < 1.0) {
			os_unfair_lock_unlock(&bench_lock);
			return;
		}
		if (bench_host != 0) {
			if (bench_head - bench_tail < bench_ring)
				bench_ms[bench_head++ % bench_ring] = bench_new_layer;
			else
				bench_lost++;
		}
		bench_host = (uintptr_t)layer;
		bench_last = 0;
	}
	if (bench_last > 0) {
		if (bench_head - bench_tail < bench_ring)
			bench_ms[bench_head++ % bench_ring] = (float)((now - bench_last) * 1000.0);
		else
			bench_lost++;
	}
	bench_last = now;
	if (!bench_started)
		start = bench_started = 1;
	os_unfair_lock_unlock(&bench_lock);

	if (start)
		bench_start();
}

// Reads the setting; returns whether frame times are recorded in this process.
static int bench_init(void)
{
	if (!bench_wanted())
		return 0;
	shim_log("overlay_shim bench: on, frame generation off, waiting for the game's first frame\n");
	return 1;
}

// For overlay-shim/tests/bench.m
__attribute__((visibility("default"))) void np_bench_probe(int *on, int *framegen, unsigned long long *frames)
{
	if (on != NULL)
		*on = bench_state == 1;
	if (framegen != NULL)
		*framegen = framegen_enabled;
	if (frames != NULL) {
		os_unfair_lock_lock(&bench_lock);
		*frames = bench_head;
		os_unfair_lock_unlock(&bench_lock);
	}
}
