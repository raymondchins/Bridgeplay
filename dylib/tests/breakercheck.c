// The crash-loop breaker and the health files, against a scratch home. Every start runs in
// a forked child, so each has its own pid the way a real Steam start does.
#include <ftw.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

#include "../feats/breaker.c"

// The compat chunk hook, with its webpatch inputs faked and its health report recorded.
static void web_report(const char *shape, size_t applied, size_t total, int drifted);
#define np_health_web web_report
#include "../hooks/hook_webpatch.c"
#undef np_health_web

static int    fake_patch = 1;
static size_t fake_live = 5, fake_total = 6;
static char   got_shape[64];
static size_t got_applied = (size_t)-1, got_total;
static int    got_reports;

static void web_report(const char *shape, size_t applied, size_t total, int drifted) {
    (void)drifted;
    set_str(got_shape, sizeof got_shape, shape);
    got_applied = applied;
    got_total = total;
    got_reports++;
}
void np_webpatch_set_fallback_tool(const char *name) { (void)name; }
void np_webpatch_set_fex_tools(const char *const *names, size_t count) { (void)names; (void)count; }
const char *np_compat_fallback_tool_name(void) { return "fake"; }
size_t np_compat_fex_tools(const char **names, size_t max) { (void)names; (void)max; return 0; }
int np_compatsvc_routes(void) { return NP_COMPATSVC_ABSENT + 1; }
int np_webpatch_should_patch(const char *path) { (void)path; return 0; }
void np_webpatch_last_gates(size_t *live, size_t *total, int *drifted) {
    *live = fake_live;
    *total = fake_total;
    *drifted = !fake_patch;
}
char *np_webpatch_transform(const uint8_t *src, size_t src_len, size_t *out_len,
                            const char **out_shape) {
    if (out_shape) *out_shape = "selecttool";
    if (!fake_patch) return NULL;
    char *out = malloc(src_len);
    if (out) memcpy(out, src, src_len);
    *out_len = src_len;
    return out;
}

static int fails;
static char root[PATH_MAX];
static char pkg[PATH_MAX];
static char support[PATH_MAX];

#define CHECK(what, cond) do { \
    if (cond) printf("  ok    %s\n", what); \
    else { printf("  FAIL  %s (%s:%d)\n", what, __FILE__, __LINE__); fails++; } \
} while (0)

static void mkdirs(const char *path) {
    char buf[PATH_MAX];
    snprintf(buf, sizeof buf, "%s", path);
    for (char *p = buf + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0'; mkdir(buf, 0755); *p = '/';
    }
    mkdir(buf, 0755);
}

static void put(const char *dir, const char *name, const char *text) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); exit(1); }
    fputs(text, f);
    fclose(f);
}

static void touch_at(const char *dir, const char *name, time_t when) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    struct timeval tv[2] = { { when, 0 }, { when, 0 } };
    utimes(path, tv);
}

static void drop(const char *dir, const char *name) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    unlink(path);
}

static const char *manifest(const char *version) {
    static char text[512];
    snprintf(text, sizeof text,
             "\"osx\"\n{\n\t\"version\"\t\t\"%s\"\n\t\"ostype\"\t\t\"macos1015\"\n"
             "\t\"bins_osx\"\n\t{\n\t\t\"file\"\t\t\"bins.zip\"\n\t\t\"version\"\t\t\"7\"\n\t}\n}\n",
             version);
    return text;
}

static cJSON *load_json(const char *dir, const char *name) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    size_t len = 0;
    uint8_t *raw = np_read_whole_file(path, &len);
    if (!raw) return NULL;
    cJSON *j = cJSON_ParseWithLength((const char *)raw, len);
    free(raw);
    return j;
}

static const char *jstr(cJSON *j, const char *k) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(j, k);
    return cJSON_IsString(v) ? v->valuestring : "<missing>";
}

static double jnum(cJSON *j, const char *k) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(j, k);
    return cJSON_IsNumber(v) ? v->valuedouble : -1;
}

// One Steam start in a child. `how`: 'c' crash (no exit mark), 'q' clean quit, 'h' healthy.
// Exit status: the mode, plus 8 when a start that is not active kept the insert.
static int start(char how) {
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {
        setenv("DYLD_INSERT_LIBRARIES", "/nonexistent/notproton.dylib", 1);
        np_mode_t mode = np_breaker_start();
        int insert = getenv("DYLD_INSERT_LIBRARIES") != NULL;
        if (mode == NP_MODE_ACTIVE) {
            np_breaker_client_seen();
            np_health_signatures(18, 18);
            np_health_hooks(9, 9);
            np_health_layout(1);
            np_health_flush();
            if (how == 'h') mark(NP_STAGE_HEALTHY);
            if (how == 'q' || how == 'h') np_breaker_exit();
        }
        _exit((int)mode | (mode != NP_MODE_ACTIVE && insert ? 8 : 0));
    }
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static np_mode_t helper_mode(void) {
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) _exit((int)np_breaker_mode());
    int st = 0;
    waitpid(pid, &st, 0);
    return WIFEXITED(st) ? (np_mode_t)WEXITSTATUS(st) : (np_mode_t)-1;
}

static void decide_cases(void) {
    printf("decide\n");
    np_boot_t prev = {0}, next;
    np_mode_t mode;
    int notify;
    np_boot_env_t env = { .key = "100:85", .pid = 500, .now = 1000, .own_start = 999 };

    CHECK("a first start is active and recorded",
          np_boot_decide(NULL, &env, &next, &mode, &notify) == NP_BOOT_RECORD &&
          mode == NP_MODE_ACTIVE && next.strikes == 0 && strcmp(next.stage, "boot") == 0 &&
          next.pid == 500 && next.t0 == 1000 && !notify);

    prev = next;
    env.now = 1001;
    np_boot_decide(&prev, &env, &next, &mode, &notify);
    CHECK("the client's constructor in the same pid is the same start",
          mode == NP_MODE_ACTIVE && next.strikes == 0);

    prev = next;
    env = (np_boot_env_t){ .key = "100:85", .pid = 501, .now = 1100, .own_start = 1100 };
    np_boot_decide(&prev, &env, &next, &mode, &notify);
    CHECK("a start that died in boot is one strike", mode == NP_MODE_ACTIVE && next.strikes == 1);

    prev = next;
    snprintf(prev.stage, sizeof prev.stage, "client");
    env.pid = 502; env.now = env.own_start = 1200;
    np_boot_decide(&prev, &env, &next, &mode, &notify);
    CHECK("a second death trips the breaker, once notified",
          mode == NP_MODE_PASSIVE && next.strikes == 2 && strcmp(next.stage, "passive") == 0 &&
          notify && next.notified);

    prev = next;
    env.pid = 503; env.now = env.own_start = 1300;
    np_boot_decide(&prev, &env, &next, &mode, &notify);
    CHECK("the next start stays passive without another notification",
          mode == NP_MODE_PASSIVE && next.strikes == 2 && !notify);

    prev = next;
    env.key = "101:85"; env.pid = 504;
    np_boot_decide(&prev, &env, &next, &mode, &notify);
    CHECK("a new Steam build starts clean", mode == NP_MODE_ACTIVE && next.strikes == 0 && !next.notified);

    prev = (np_boot_t){ .key = "101:85", .pid = 600, .t0 = 2000, .stage = "healthy", .strikes = 0 };
    env = (np_boot_env_t){ .key = "101:85", .pid = 601, .now = 2100, .own_start = 2100 };
    np_boot_decide(&prev, &env, &next, &mode, &notify);
    CHECK("after a healthy start nothing is counted", mode == NP_MODE_ACTIVE && next.strikes == 0);

    prev = (np_boot_t){ .key = "101:85", .pid = 600, .t0 = 2000, .stage = "exited", .strikes = 1 };
    np_boot_decide(&prev, &env, &next, &mode, &notify);
    CHECK("a clean quit keeps the strike it had", mode == NP_MODE_ACTIVE && next.strikes == 1);

    prev = (np_boot_t){ .key = "101:85", .pid = 601, .t0 = 1500, .stage = "boot", .strikes = 1 };
    np_boot_decide(&prev, &env, &next, &mode, &notify);
    CHECK("a reused pid from an older start is not a hand-off",
          mode == NP_MODE_PASSIVE && next.strikes == 2);

    prev = (np_boot_t){ .key = "101:85", .pid = 700, .t0 = 2000, .stage = "boot", .strikes = 2 };
    env.prev_running = 1;
    CHECK("a second Steam while one runs touches nothing",
          np_boot_decide(&prev, &env, &next, &mode, &notify) == NP_BOOT_SECOND &&
          mode == NP_MODE_PASSIVE);

    env.prev_running = 0;
    env.paused = 1;
    CHECK("paused is off and counts nothing",
          np_boot_decide(&prev, &env, &next, &mode, &notify) == NP_BOOT_PAUSED &&
          mode == NP_MODE_OFF);

    np_boot_t s = { .key = "1:2", .pid = 9, .stage = "boot", .strikes = 1, .notified = 1 };
    CHECK("client follows boot", np_boot_advance(&s, 9, "client") && strcmp(s.stage, "client") == 0);
    CHECK("another pid cannot advance it", !np_boot_advance(&s, 10, "healthy"));
    CHECK("healthy clears the strikes",
          np_boot_advance(&s, 9, "healthy") && s.strikes == 0 && !s.notified);
    CHECK("healthy then exited", np_boot_advance(&s, 9, "exited") && strcmp(s.stage, "exited") == 0);
    snprintf(s.stage, sizeof s.stage, "passive");
    CHECK("a passive start stays passive at exit", !np_boot_advance(&s, 9, "exited"));
}

static void file_cases(void) {
    printf("files\n");
    char build[24], channel[64];

    put(pkg, "steam_client_osx.installed", "x");
    put(pkg, "steam_client_osx.manifest", manifest("1794536281"));
    put(pkg, "steam_client_publicbeta_osx.installed", "x");
    put(pkg, "steam_client_publicbeta_osx.manifest", manifest("1795567705"));
    touch_at(pkg, "steam_client_osx.installed", 1000);
    touch_at(pkg, "steam_client_publicbeta_osx.installed", 2000);
    CHECK("the build comes from the newest .installed",
          np_steam_build(pkg, build, sizeof build) == 0 && strcmp(build, "1795567705") == 0);

    drop(pkg, "steam_client_publicbeta_osx.manifest");
    CHECK("a newest one with no manifest gives way to the next",
          np_steam_build(pkg, build, sizeof build) == 0 && strcmp(build, "1794536281") == 0);
    drop(pkg, "steam_client_publicbeta_osx.installed");

    CHECK("no package folder is build 0",
          np_steam_build("/nonexistent/package", build, sizeof build) != 0 && strcmp(build, "0") == 0);

    np_steam_channel(pkg, channel, sizeof channel);
    CHECK("no beta file is stable", strcmp(channel, "stable") == 0);
    put(pkg, "beta", "publicbeta\n");
    np_steam_channel(pkg, channel, sizeof channel);
    CHECK("the beta file names the channel", strcmp(channel, "publicbeta") == 0);
    put(pkg, "beta", "a\"b");
    np_steam_channel(pkg, channel, sizeof channel);
    CHECK("an odd beta file is unknown", strcmp(channel, "unknown") == 0);
    drop(pkg, "beta");

    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/roundtrip.json", root);
    np_boot_t w = { .key = "1794536281:85", .pid = 42, .t0 = 1790000000, .stage = "client",
                    .strikes = 1, .notified = 1 }, r;
    CHECK("boot.json round-trips",
          np_boot_write(path, &w) == 0 && np_boot_read(path, &r) == 0 &&
          strcmp(w.key, r.key) == 0 && w.pid == r.pid && w.t0 == r.t0 &&
          strcmp(w.stage, r.stage) == 0 && w.strikes == r.strikes && w.notified == r.notified);
    put(root, "roundtrip.json", "{\"key\":");
    CHECK("a torn boot.json reads as none", np_boot_read(path, &r) != 0 && r.key[0] == 0);
    put(root, "roundtrip.json", "[1,2]");
    CHECK("a boot.json of the wrong shape reads as none", np_boot_read(path, &r) != 0);

    np_health_t h = { .written = 5, .pid = 6, .patch_build = 85, .steam_build = 1795567705ULL,
                      .channel = "publicbeta", .sigdb_build = 1795567705ULL,
                      .mode = NP_MODE_PASSIVE, .strikes = 2, .signatures_resolved = 17,
                      .signatures_required = 18, .hooks_installed = 3, .hooks_total = 9,
                      .layout_known = 1 };
    char *text = np_health_format(&h);
    cJSON *j = text ? cJSON_Parse(text) : NULL;
    free(text);
    CHECK("health.json carries every contract key",
          j && jnum(j, "written") == 5 && jnum(j, "pid") == 6 && jnum(j, "patch_build") == 85 &&
          jnum(j, "steam_build") == 1795567705.0 && strcmp(jstr(j, "channel"), "publicbeta") == 0 &&
          jnum(j, "sigdb_build") == 1795567705.0 && strcmp(jstr(j, "mode"), "passive") == 0 &&
          jnum(j, "strikes") == 2 && jnum(j, "signatures_resolved") == 17 &&
          jnum(j, "signatures_required") == 18 && jnum(j, "hooks_installed") == 3 &&
          jnum(j, "hooks_total") == 9 &&
          cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(j, "layout_known")));
    cJSON_Delete(j);
}

static int boot_strikes(void) {
    cJSON *j = load_json(support, NP_BOOT_FILE);
    int n = j ? (int)jnum(j, "strikes") : -1;
    cJSON_Delete(j);
    return n;
}

static int boot_stage_is(const char *stage) {
    cJSON *j = load_json(support, NP_BOOT_FILE);
    int same = j && strcmp(jstr(j, "stage"), stage) == 0;
    cJSON_Delete(j);
    return same;
}

static int health_is(const char *mode, int strikes, int hooks) {
    cJSON *j = load_json(support, NP_HEALTH_FILE);
    int ok = j && strcmp(jstr(j, "mode"), mode) == 0 && jnum(j, "strikes") == strikes &&
             jnum(j, "hooks_installed") == hooks && jnum(j, "steam_build") == 1794536281.0 &&
             jnum(j, "patch_build") == BRIDGEPLAY_BUILD && strcmp(jstr(j, "channel"), "stable") == 0;
    cJSON_Delete(j);
    return ok;
}

static void runtime_cases(void) {
    printf("starts\n");
    CHECK("a first start is active", start('c') == NP_MODE_ACTIVE);
    CHECK("health.json says what it installed", health_is("active", 0, 9));
    CHECK("it died, so the second start carries a strike", start('c') == NP_MODE_ACTIVE && boot_strikes() == 1);
    CHECK("the third start is passive and drops the insert", start('c') == NP_MODE_PASSIVE);
    CHECK("health.json says passive with no hooks", health_is("passive", 2, 0));
    CHECK("Steam Helper follows it", helper_mode() == NP_MODE_PASSIVE);
    CHECK("the next start stays passive", start('q') == NP_MODE_PASSIVE && boot_stage_is("passive"));

    drop(support, NP_BOOT_FILE);
    CHECK("Try Again (boot.json removed) is active again", start('q') == NP_MODE_ACTIVE);
    CHECK("a clean quit is recorded", boot_stage_is("exited"));
    start('c');
    CHECK("a healthy start clears the strike it started with",
          start('h') == NP_MODE_ACTIVE && boot_strikes() == 0 && boot_stage_is("exited") &&
          health_is("active", 0, 9));

    start('c');
    start('c');
    CHECK("a crash after a clean quit counts once", boot_strikes() == 1);
    put(pkg, "steam_client_osx.manifest", manifest("1794536282"));
    CHECK("a Steam update starts clean", start('c') == NP_MODE_ACTIVE && boot_strikes() == 0);
    put(pkg, "steam_client_osx.manifest", manifest("1794536281"));
    start('c');

    put(support, NP_PAUSED_FILE, "");
    int before = boot_strikes();
    CHECK("paused is off and drops the insert", start('c') == NP_MODE_OFF);
    CHECK("a paused start counts nothing", boot_strikes() == before);
    CHECK("health.json says off", health_is("off", before, 0));
    CHECK("Steam Helper is off while paused", helper_mode() == NP_MODE_OFF);
    drop(support, NP_PAUSED_FILE);

    np_health_web("selecttool", 5, 6, 1);
    cJSON *j = load_json(support, NP_HEALTH_WEB_FILE);
    CHECK("health-web.json names the gates",
          j && strcmp(jstr(j, "shape"), "selecttool") == 0 && jnum(j, "gates_applied") == 5 &&
          jnum(j, "gates_total") == 6 && cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(j, "drifted")) &&
          jnum(j, "steam_build") == 1794536281.0 && jnum(j, "pid") == getpid());
    cJSON_Delete(j);

    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", support, NP_HEALTH_FILE);
    struct stat st;
    CHECK("health.json is a plain file", lstat(path, &st) == 0 && S_ISREG(st.st_mode));
}

static void chunk_cases(void) {
    printf("web report\n");
    char chunk[PATH_MAX];
    snprintf(chunk, sizeof chunk, "%s/chunk.js", root);
    put(root, "chunk.js", "console.log(1)\n");

    got_reports = 0;
    int fd = open_patched(chunk);
    CHECK("a served chunk reports its gates", fd >= 0 && got_reports == 1 &&
          strcmp(got_shape, "selecttool") == 0 && got_applied == 5 && got_total == 6);
    if (fd >= 0) close(fd);

    chmod(support, 0500);
    got_reports = 0;
    fd = open_patched(chunk);
    chmod(support, 0755);
    CHECK("a chunk that could not be staged reports no gate applied",
          fd < 0 && got_reports == 1 && got_applied == 0 && got_total == 6);
    if (fd >= 0) close(fd);

    fake_patch = 0;
    got_reports = 0;
    CHECK("a drifted chunk Steam reads unpatched reports no gate applied",
          open_patched(chunk) < 0 && got_reports == 1 && got_applied == 0 && got_total == 6);
    fake_patch = 1;
}

static void web_retry_case(void) {
    chmod(support, 0500);
    np_health_web("vite", 3, 4, 0);
    chmod(support, 0755);
    np_health_web("vite", 3, 4, 0);
    cJSON *j = load_json(support, NP_HEALTH_WEB_FILE);
    CHECK("a report that failed to write is written by the next identical one",
          j && strcmp(jstr(j, "shape"), "vite") == 0 && jnum(j, "gates_applied") == 3 &&
          jnum(j, "gates_total") == 4);
    cJSON_Delete(j);
}

// Another start holds the boot record's lock: this one waits for it, up to a bound.
static int locked_start(int hold_ms, int *written_while_held) {
    char lock[PATH_MAX], boot[PATH_MAX];
    snprintf(lock, sizeof lock, "%s/%s", support, NP_BOOT_LOCK_FILE);
    snprintf(boot, sizeof boot, "%s/%s", support, NP_BOOT_FILE);
    drop(support, NP_BOOT_FILE);
    int fd = open(lock, O_RDWR | O_CREAT, 0600);
    if (fd < 0 || flock(fd, LOCK_EX) != 0) return -1;
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {
        np_breaker_start();
        _exit(0);
    }
    usleep((useconds_t)hold_ms * 1000);
    struct stat st;
    *written_while_held = stat(boot, &st) == 0;
    close(fd);
    int status = 0;
    waitpid(pid, &status, 0);
    return stat(boot, &st) == 0;
}

static void lock_cases(void) {
    printf("boot lock\n");
    int early = 1;
    CHECK("a start waits while another holds the boot record",
          locked_start(300, &early) == 1 && !early && boot_strikes() == 0);
    CHECK("and goes on without the lock once the wait runs out",
          locked_start(NP_BOOT_LOCK_MS + 500, &early) == 1 && early);
}

static int scrub(const char *path, const struct stat *st, int flag, struct FTW *ftw) {
    (void)st; (void)flag; (void)ftw;
    if (strncmp(path, root, strlen(root)) != 0) return -1;
    return remove(path);
}

int main(void) {
    const char *tmp = getenv("TMPDIR");
    snprintf(root, sizeof root, "%s/breakercheck.XXXXXX", tmp && tmp[0] ? tmp : "/tmp");
    if (!mkdtemp(root)) { perror("mkdtemp"); return 1; }
    if (setenv("HOME", root, 1) != 0) return 1;
    setenv("BRIDGEPLAY_BREAKER_QUIET", "1", 1);
    np_log_level = -1;

    snprintf(pkg, sizeof pkg, "%s%s", root, NP_STEAM_PACKAGE_DIR);
    snprintf(support, sizeof support, "%s/Library/Application Support/bridgeplay", root);
    mkdirs(pkg);
    mkdirs(support);

    decide_cases();
    file_cases();
    runtime_cases();
    chunk_cases();
    web_retry_case();
    lock_cases();

    // Only temp files could be left, and none may be.
    int strays = 0;
    DIR *dh = opendir(support);
    struct dirent *e;
    while (dh && (e = readdir(dh)) != NULL)
        strays += strstr(e->d_name, ".tmp") != NULL;
    if (dh) closedir(dh);
    CHECK("no temp file is left behind", strays == 0);

    nftw(root, scrub, 16, FTW_DEPTH | FTW_PHYS);
    if (fails) { printf("==> breakercheck: %d failed\n", fails); return 1; }
    printf("==> breakercheck: bad starts, Pause and the health files behave\n");
    return 0;
}
