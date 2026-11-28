// The signed pause list against a scratch home, signed with a throwaway key made here from a
// fixed seed (no real key exists in the repo). Steam starts run in forked children as in
// breakercheck; a stub curl stands in for the network, and notifications go to a file.
//
//   pauselistcheck                                     every case below
//   pauselistcheck --verify <key b64> <json> <sig> <now>  prints "<status> <serial> <entries>"
#include <ftw.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "../feats/breaker.c"
#include "../feats/pauselist.c"

static int fails;
static char root[PATH_MAX];
static char pkg[PATH_MAX];
static char support[PATH_MAX];
static uint8_t pub[32], priv[64], other_pub[32], other_priv[64];
static char key_b64[64];
static long long now_s;

#define BUILD "1795567705"

#define CHECK(what, cond) do { \
    if (cond) printf("  ok    %s\n", what); \
    else { printf("  FAIL  %s (%s:%d)\n", what, __FILE__, __LINE__); fails++; } \
} while (0)

static void b64(const uint8_t *in, size_t len, char *out) {
    static const char a[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t o = 0;
    for (size_t i = 0; i < len; i += 3) {
        uint32_t w = (uint32_t)in[i] << 16 | (i + 1 < len ? (uint32_t)in[i + 1] << 8 : 0) |
                     (i + 2 < len ? in[i + 2] : 0);
        out[o++] = a[w >> 18 & 63];
        out[o++] = a[w >> 12 & 63];
        out[o++] = i + 1 < len ? a[w >> 6 & 63] : '=';
        out[o++] = i + 2 < len ? a[w & 63] : '=';
    }
    out[o] = '\0';
}

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

static int exists(const char *dir, const char *name) {
    char path[PATH_MAX];
    struct stat st;
    snprintf(path, sizeof path, "%s/%s", dir, name);
    return lstat(path, &st) == 0;
}

static char *slurp(const char *dir, const char *name) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    size_t len = 0;
    uint8_t *raw = np_read_whole_file(path, &len);
    if (!raw) return NULL;
    char *text = malloc(len + 1);
    memcpy(text, raw, len);
    text[len] = '\0';
    free(raw);
    return text;
}

static int count_lines(const char *dir, const char *name) {
    char *text = slurp(dir, name);
    int n = 0;
    for (char *p = text; p && *p; p++) n += *p == '\n';
    free(text);
    return n;
}

// A list document; `entries` is the JSON array's inside.
static const char *list_doc(unsigned long long serial, long long issued, long long expires,
                            const char *entries) {
    static char doc[8192];
    snprintf(doc, sizeof doc,
             "{\"entries\":[%s],\"expires\":%lld,\"issued\":%lld,\"serial\":%llu,\"version\":1}",
             entries, expires, issued, serial);
    return doc;
}

static void sign_with(const uint8_t *k_pub, const uint8_t *k_priv, const char *doc, char *line) {
    uint8_t sig[64];
    ed25519_sign(sig, (const unsigned char *)doc, strlen(doc), k_pub, k_priv);
    char enc[100];
    b64(sig, sizeof sig, enc);
    sprintf(line, "%s %zu\n", enc, strlen(doc));
}

static np_pl_status_t check_doc(const char *doc, const char *line, np_pl_list_t *list) {
    return np_pl_check((const uint8_t *)doc, strlen(doc), line, strlen(line), pub, now_s, list);
}

#define THIS_BUILD "{\"steam_build\":" BUILD ",\"note\":\"Steam beta " BUILD " closes at start.\"}"

static void pure_cases(void) {
    printf("format\n");
    uint8_t out[8];
    CHECK("base64 decodes a full quartet", np_pl_base64("TWFu", 4, out, 8) == 3 && !memcmp(out, "Man", 3));
    CHECK("base64 decodes one pad", np_pl_base64("TWE=", 4, out, 8) == 2 && !memcmp(out, "Ma", 2));
    CHECK("base64 decodes two pads", np_pl_base64("TQ==", 4, out, 8) == 1 && out[0] == 'M');
    CHECK("base64 refuses a short quartet", np_pl_base64("TQ=", 3, out, 8) < 0);
    CHECK("base64 refuses padding inside", np_pl_base64("TW=u", 4, out, 8) < 0);
    CHECK("base64 refuses odd characters", np_pl_base64("TW*u", 4, out, 8) < 0);
    CHECK("base64 refuses what doesn't fit", np_pl_base64("TWFuTWFu", 8, out, 4) < 0);

    char line[200];
    const char *doc = list_doc(10, now_s - 60, now_s + 86400, THIS_BUILD);
    sign_with(pub, priv, doc, line);
    uint8_t sig[64];
    size_t length = 0;
    CHECK("the .sig line parses", np_pl_parse_sig(line, strlen(line), sig, &length) == 0 &&
          length == strlen(doc));
    CHECK("a .sig line with three parts is refused", np_pl_parse_sig("AAAA 4 x", 8, sig, &length) < 0);
    CHECK("a .sig line with a short signature is refused", np_pl_parse_sig("TWFu 4", 6, sig, &length) < 0);

    printf("signature\n");
    np_pl_list_t *list = calloc(1, sizeof *list);
    CHECK("a signed list checks out", check_doc(doc, line, list) == NP_PL_OK &&
          list->serial == 10 && list->count == 1 && strstr(list->entries[0].note, "closes"));

    char bad[8192];
    snprintf(bad, sizeof bad, "%s", doc);
    bad[strlen(bad) - 2] = '2';
    CHECK("one changed byte is refused", check_doc(bad, line, list) == NP_PL_INVALID && list->serial == 0);

    char other[200];
    sign_with(other_pub, other_priv, doc, other);
    CHECK("a list signed by another key is refused", check_doc(doc, other, list) == NP_PL_INVALID);

    char shifted[200];
    snprintf(shifted, sizeof shifted, "%.*s %zu\n", 88, line, strlen(doc) + 1);
    CHECK("a length that isn't the file's is refused", check_doc(doc, shifted, list) == NP_PL_INVALID);

    doc = list_doc(11, now_s - 3 * 86400, now_s - 60, THIS_BUILD);
    sign_with(pub, priv, doc, line);
    CHECK("an expired list is expired and keeps its serial",
          check_doc(doc, line, list) == NP_PL_EXPIRED && list->serial == 11);

    doc = list_doc(12, now_s, now_s + 40 * 86400LL, THIS_BUILD);
    sign_with(pub, priv, doc, line);
    CHECK("a list meant to last over 31 days is refused", check_doc(doc, line, list) == NP_PL_INVALID);

    doc = list_doc(13, now_s, now_s - 1, THIS_BUILD);
    sign_with(pub, priv, doc, line);
    CHECK("a list that expires before it was issued is refused", check_doc(doc, line, list) == NP_PL_INVALID);

    doc = "{\"entries\":[],\"expires\":2,\"issued\":1,\"serial\":1,\"version\":2}";
    sign_with(pub, priv, doc, line);
    CHECK("a version this build doesn't know is refused", check_doc(doc, line, list) == NP_PL_INVALID);

    printf("entries\n");
    const char *mixed =
        "{\"steam_build\":1,\"surprise\":true},"                      // unknown key
        "{\"note\":\"no selector\"},"                                 // nothing to match on
        "{\"steam_build\":2,\"steam_build\":3},"                      // repeated key
        "{\"steam_build\":4,\"steam_build_min\":4},"                  // exact and range
        "{\"steam_build_min\":9,\"steam_build_max\":8},"              // empty range
        "{\"steam_build\":5,\"note\":\"bad\\u0007bell\"},"            // control character
        "{\"steam_build\":6,\"url\":\"http://example.invalid/\"},"    // not https
        "{\"channel\":\"public beta\"},"                              // odd channel
        "{\"steam_build\":7.5},"                                      // not whole
        "{\"steam_build_min\":100,\"steam_build_max\":200,\"patch_build_max\":50},"
        "{\"channel\":\"publicbeta\",\"fixed_in\":\"0.7.70\",\"url\":\"https://example.invalid/i/1\"},"
        "{\"steam_build\":300,\"channel\":\"stable\"}";
    CHECK("entries this build can't read are left out, the rest kept",
          np_pl_parse(list_doc(1, 1, 2, mixed), strlen(list_doc(1, 1, 2, mixed)), list) == 0 &&
          list->count == 3);
    CHECK("a range matches inside it", np_pl_match(list, 150, "stable", 50) == &list->entries[0]);
    CHECK("a range misses outside it", np_pl_match(list, 201, "stable", 50) == NULL);
    CHECK("a fixed Bridgeplay build is not paused", np_pl_match(list, 150, "stable", 51) == NULL);
    CHECK("a channel entry matches any build on it",
          np_pl_match(list, 999, "publicbeta", 85) == &list->entries[1]);
    CHECK("a channel entry needs that channel", np_pl_match(list, 999, "stable", 85) == NULL);
    CHECK("build and channel both have to match",
          np_pl_match(list, 300, "stable", 85) == &list->entries[2] &&
          np_pl_match(list, 300, "unknown", 85) == NULL);
    CHECK("an unreadable Steam build matches no build entry",
          np_pl_match(list, 0, "stable", 1) == NULL && np_pl_match(list, 0, "publicbeta", 1) != NULL);

    char many[8192] = "";
    for (int i = 0; i < 40; i++)
        snprintf(many + strlen(many), sizeof many - strlen(many), "%s{\"steam_build\":%d}",
                 i ? "," : "", i + 1);
    const char *big = list_doc(1, 1, 2, many);
    CHECK("at most 32 entries are kept", np_pl_parse(big, strlen(big), list) == 0 &&
          list->count == NP_PL_MAX_ENTRIES);
    free(list);
}

// ---- Steam starts ---------------------------------------------------------------------

static void record_note(const char *subtitle, const char *body) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/notes", root);
    FILE *f = fopen(path, "a");
    if (f) { fprintf(f, "%s|%s\n", subtitle, body); fclose(f); }
}

// One Steam start in a child. Exit status: the mode, plus 8 when a start that is not active
// kept the insert. It writes how long np_breaker_start took to root/elapsed.
static int start(void) {
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {
        setenv("DYLD_INSERT_LIBRARIES", "/nonexistent/notproton.dylib", 1);
        struct timespec a, b;
        clock_gettime(CLOCK_MONOTONIC, &a);
        np_mode_t mode = np_breaker_start();
        clock_gettime(CLOCK_MONOTONIC, &b);
        char ms[32];
        snprintf(ms, sizeof ms, "%ld\n", (long)((b.tv_sec - a.tv_sec) * 1000 + (b.tv_nsec - a.tv_nsec) / 1000000));
        put(root, "elapsed", ms);
        int insert = getenv("DYLD_INSERT_LIBRARIES") != NULL;
        if (mode == NP_MODE_ACTIVE) np_breaker_exit();
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

static cJSON *health(void) {
    char *text = slurp(support, NP_HEALTH_FILE);
    cJSON *j = text ? cJSON_Parse(text) : NULL;
    free(text);
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

static int health_is(const char *mode, const char *reason, const char *list, double serial) {
    cJSON *j = health();
    int ok = j && strcmp(jstr(j, "mode"), mode) == 0 && strcmp(jstr(j, "mode_reason"), reason) == 0 &&
             strcmp(jstr(j, "pause_list"), list) == 0 && jnum(j, "pause_list_serial") == serial;
    if (!ok && j)
        printf("        health: mode=%s reason=%s list=%s serial=%.0f\n", jstr(j, "mode"),
               jstr(j, "mode_reason"), jstr(j, "pause_list"), jnum(j, "pause_list_serial"));
    cJSON_Delete(j);
    return ok;
}

// The next start may fetch again; what was announced stays announced.
static void fetch_due(void) {
    pl_state_t state;
    state_read(support, &state);
    state.checked = 1;
    state_write(support, &state);
}

static int wait_lines(const char *dir, const char *name, int n) {
    for (int i = 0; i < 100; i++) {
        if (count_lines(dir, name) >= n) return 1;
        usleep(50 * 1000);
    }
    return 0;
}

static int elapsed_ms(void) {
    char *ms = slurp(root, "elapsed");
    int n = ms ? atoi(ms) : -1;
    free(ms);
    return n;
}

static int wait_for(const char *dir, const char *name, int gone) {
    for (int i = 0; i < 100; i++) {
        if (exists(dir, name) != gone) return 1;
        usleep(50 * 1000);
    }
    return 0;
}

static void serve(const char *doc, int sign_ok) {
    char line[200];
    sign_with(pub, priv, doc, line);
    if (!sign_ok) line[3] = line[3] == 'A' ? 'B' : 'A';
    char dir[PATH_MAX];
    snprintf(dir, sizeof dir, "%s/serve", root);
    put(dir, "list.json", doc);
    put(dir, "list.sig", line);
}

// Leaves a fetched pair as a finished fetch would.
static void fetched(const char *doc, int sign_ok) {
    char line[200];
    sign_with(pub, priv, doc, line);
    if (!sign_ok) line[5] = line[5] == 'A' ? 'B' : 'A';
    put(support, NP_PL_NEW_SIG, line);
    put(support, NP_PL_NEW_FILE, doc);
}

static int cache_serial(void) {
    np_pl_list_t *list = calloc(1, sizeof *list);
    uint8_t k[32];
    np_pl_base64(key_b64, strlen(key_b64), k, sizeof k);
    np_pl_status_t s = check_cache(support, k, now_s, list);
    int serial = s == NP_PL_OK || s == NP_PL_EXPIRED ? (int)list->serial : -1;
    free(list);
    return serial;
}

static void kill_hang(void) {
    char *pid = slurp(root, "hang.pid");
    if (pid && atoi(pid) > 0) kill(atoi(pid), SIGKILL);
    free(pid);
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/hang.pid", root);
    unlink(path);
}

static const char *fake_curl =
    "#!/bin/sh\n"
    "printf '%s\\n' \"$*\" >> \"$HOME/curl-calls\"\n"
    "out= url=\n"
    "while [ $# -gt 0 ]; do\n"
    "  case $1 in -o) out=$2; shift 2 ;; *) url=$1; shift ;; esac\n"
    "done\n"
    "case $(cat \"$HOME/curl-mode\" 2>/dev/null) in\n"
    "  offline) exit 7 ;;\n"
    "  hang) echo $$ > \"$HOME/hang.pid\"; exec /bin/sleep 20 ;;\n"
    "esac\n"
    "case $url in\n"
    "  *.sig) cp \"$HOME/serve/list.sig\" \"$out\" ;;\n"
    "  *) cp \"$HOME/serve/list.json\" \"$out\" ;;\n"
    "esac\n";

static void runtime_cases(void) {
    char curl[PATH_MAX], dir[PATH_MAX];
    snprintf(curl, sizeof curl, "%s/fake-curl", root);
    put(root, "fake-curl", fake_curl);
    chmod(curl, 0755);
    snprintf(dir, sizeof dir, "%s/serve", root);
    mkdirs(dir);
    g_pl_curl = curl;
    g_notify = record_note;

    printf("no key\n");
    g_pl_key = "";
    CHECK("with no key built in Steam starts active", start() == NP_MODE_ACTIVE);
    CHECK("health.json says unkeyed", health_is("active", "", "unkeyed", 0));
    usleep(200 * 1000);
    CHECK("and nothing is fetched", count_lines(root, "curl-calls") == 0);

    g_pl_key = key_b64;
    printf("offline\n");
    put(root, "curl-mode", "offline");
    CHECK("a first start with no list and no network is active", start() == NP_MODE_ACTIVE);
    CHECK("health.json says none", health_is("active", "", "none", 0));
    CHECK("it tried one fetch", wait_for(root, "curl-calls", 0) && count_lines(root, "curl-calls") == 1);
    char *calls = slurp(root, "curl-calls");
    CHECK("curl reads no .curlrc and speaks only HTTPS",
          calls && strncmp(calls, "-q ", 3) == 0 && strstr(calls, "--proto =https") &&
          strstr(calls, "--proto-redir =https") && strstr(calls, "--max-time 8") &&
          strstr(calls, NP_PAUSE_LIST_URL));
    free(calls);
    start();
    usleep(300 * 1000);
    CHECK("a start right after does not fetch again", count_lines(root, "curl-calls") == 1);

    printf("fetch and pause\n");
    put(root, "curl-mode", "serve");
    serve(list_doc(100, now_s - 60, now_s + 14 * 86400, THIS_BUILD), 1);
    fetch_due();
    CHECK("the start that fetches is still active", start() == NP_MODE_ACTIVE);
    CHECK("the fetch lands for the next start", wait_for(support, NP_PL_NEW_FILE, 0));
    CHECK("the next start is passive and drops the insert", start() == NP_MODE_PASSIVE);
    CHECK("the fetched pair became the cache", cache_serial() == 100 &&
          !exists(support, NP_PL_NEW_FILE) && !exists(support, NP_PL_NEW_SIG));
    CHECK("health.json says paused by the list", health_is("passive", "pause_list", "ok", 100));
    cJSON *j = health();
    CHECK("health.json carries the entry's note", j && strstr(jstr(j, "pause_note"), "closes at start"));
    cJSON_Delete(j);
    char *boot = slurp(support, NP_BOOT_FILE);
    CHECK("no strike was counted", !boot || strstr(boot, "\"strikes\":0"));
    free(boot);
    CHECK("one notification says so", count_lines(root, "notes") == 1);
    char *notes = slurp(root, "notes");
    CHECK("it names the pause", notes && strstr(notes, "Paused for this Steam build|Steam beta " BUILD " closes at start. Steam opens without Bridgeplay until a fix ships"));
    free(notes);
    CHECK("the next start stays passive with no second notification",
          start() == NP_MODE_PASSIVE && count_lines(root, "notes") == 1);
    printf("        np_breaker_start with no fetch due: %d ms\n", elapsed_ms());
    CHECK("Steam Helper follows it", helper_mode() == NP_MODE_PASSIVE);

    printf("rollback and tampering\n");
    fetched(list_doc(50, now_s - 60, now_s + 86400, ""), 1);
    CHECK("an older signed list is refused", start() == NP_MODE_PASSIVE && cache_serial() == 100 &&
          !exists(support, NP_PL_NEW_FILE));
    fetched(list_doc(100, now_s - 60, now_s + 86400, ""), 1);
    CHECK("a list with the same serial is refused", start() == NP_MODE_PASSIVE && cache_serial() == 100);
    fetched(list_doc(200, now_s - 60, now_s + 86400, ""), 0);
    CHECK("a newer list with a bad signature is refused",
          start() == NP_MODE_PASSIVE && cache_serial() == 100 && !exists(support, NP_PL_NEW_FILE));
    put(support, NP_PL_NEW_FILE, list_doc(201, now_s - 60, now_s + 86400, ""));
    CHECK("a list without its signature is refused", start() == NP_MODE_PASSIVE && cache_serial() == 100);

    printf("news of a fix\n");
    fetched(list_doc(150, now_s - 60, now_s + 86400,
                     "{\"steam_build\":" BUILD ",\"fixed_in\":\"0.7.70\"}"), 1);
    CHECK("a newer list that names the fix stays passive", start() == NP_MODE_PASSIVE && cache_serial() == 150);
    notes = slurp(root, "notes");
    CHECK("and says where the fix is, once",
          count_lines(root, "notes") == 2 && notes && strstr(notes, "Fixed in Bridgeplay 0.7.70. Open Bridgeplay to update"));
    free(notes);
    j = health();
    CHECK("health.json carries the fix version", j && strcmp(jstr(j, "pause_fixed_in"), "0.7.70") == 0);
    cJSON_Delete(j);
    char entry[256];
    snprintf(entry, sizeof entry, "{\"steam_build\":" BUILD ",\"patch_build_max\":%d}", BRIDGEPLAY_BUILD - 1);
    fetched(list_doc(160, now_s - 60, now_s + 86400, entry), 1);
    CHECK("a Bridgeplay newer than patch_build_max is active again", start() == NP_MODE_ACTIVE);
    CHECK("health.json says ok, not paused", health_is("active", "", "ok", 160));

    printf("expiry\n");
    fetched(list_doc(170, now_s - 3 * 86400, now_s - 60, THIS_BUILD), 1);
    CHECK("an expired list pauses nothing", start() == NP_MODE_ACTIVE && cache_serial() == 170);
    CHECK("health.json says expired", health_is("active", "", "expired", 170));
    fetched(list_doc(165, now_s - 60, now_s + 86400, THIS_BUILD), 1);
    CHECK("an expired cache still refuses an older list", start() == NP_MODE_ACTIVE && cache_serial() == 170);

    printf("offline with a cache\n");
    put(root, "curl-mode", "offline");
    fetched(list_doc(180, now_s - 60, now_s + 86400, THIS_BUILD), 1);
    start();
    int tried = count_lines(root, "curl-calls");
    fetch_due();
    CHECK("with no network the cached list still pauses", start() == NP_MODE_PASSIVE && cache_serial() == 180);
    CHECK("that start tried the network", wait_lines(root, "curl-calls", tried + 1));
    printf("        np_breaker_start with a fetch: %d ms\n", elapsed_ms());

    char *cache = slurp(support, NP_PL_CACHE_FILE);
    if (cache) {
        cache[strlen(cache) - 4] ^= 1;
        put(support, NP_PL_CACHE_FILE, cache);
    }
    free(cache);
    CHECK("a cache changed on disk is refused", start() == NP_MODE_ACTIVE && health_is("active", "", "invalid", 0));
    fetched(list_doc(180, now_s - 60, now_s + 86400, THIS_BUILD), 1);
    CHECK("a signed list replaces it", start() == NP_MODE_PASSIVE && cache_serial() == 180);

    printf("switches\n");
    int before = count_lines(root, "curl-calls");
    fetch_due();
    setenv("BRIDGEPLAY_PAUSE_LIST", "0", 1);
    CHECK("BRIDGEPLAY_PAUSE_LIST=0 ignores the list", start() == NP_MODE_ACTIVE &&
          health_is("active", "", "ignored", 0));
    unsetenv("BRIDGEPLAY_PAUSE_LIST");
    put(support, NP_PAUSED_FILE, "");
    CHECK("the app's Pause still wins", start() == NP_MODE_OFF && health_is("off", "paused", "ok", 180));
    usleep(300 * 1000);
    CHECK("neither of them fetched", count_lines(root, "curl-calls") == before);
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", support, NP_PAUSED_FILE);
    unlink(path);

    printf("timeout\n");
    put(root, "curl-mode", "hang");
    put(support, "pause-list.fetch.1.json", "half");
    struct timeval old[2] = { { now_s - 3600, 0 }, { now_s - 3600, 0 } };
    snprintf(path, sizeof path, "%s/pause-list.fetch.1.json", support);
    utimes(path, old);
    fetch_due();
    CHECK("a fetch that hangs does not hold up Steam's start", start() == NP_MODE_PASSIVE);
    char *ms = slurp(root, "elapsed");
    CHECK("the start took under 250 ms", ms && atoi(ms) < 250);
    if (ms) printf("        np_breaker_start: %d ms\n", atoi(ms));
    free(ms);
    CHECK("the hanging fetch was running", wait_for(root, "hang.pid", 0));
    kill_hang();
    CHECK("a fetch killed halfway long ago was cleared", !exists(support, "pause-list.fetch.1.json"));
    CHECK("and left nothing for the next start", wait_for(support, NP_PL_NEW_FILE, 1) && !exists(support, NP_PL_NEW_SIG));
}

static int verify_main(char **argv) {
    uint8_t k[32];
    if (np_pl_base64(argv[2], strlen(argv[2]), k, sizeof k) != 32) {
        printf("badkey 0 0\n");
        return 2;
    }
    size_t jl = 0, sl = 0;
    uint8_t *json = np_read_whole_file(argv[3], &jl);
    uint8_t *sig = np_read_whole_file(argv[4], &sl);
    np_pl_list_t *list = calloc(1, sizeof *list);
    np_pl_status_t s = json && sig && list
        ? np_pl_check(json, jl, (char *)sig, sl, k, atoll(argv[5]), list) : NP_PL_INVALID;
    printf("%s %llu %d\n", np_pl_status_name(s), list ? list->serial : 0, list ? list->count : 0);
    free(json); free(sig); free(list);
    return 0;
}

static int scrub(const char *path, const struct stat *st, int flag, struct FTW *ftw) {
    (void)st; (void)flag; (void)ftw;
    if (strncmp(path, root, strlen(root)) != 0) return -1;
    return remove(path);
}

int main(int argc, char **argv) {
    np_log_level = -1;
    if (argc == 6 && strcmp(argv[1], "--verify") == 0)
        return verify_main(argv);

    const char *tmp = getenv("TMPDIR");
    snprintf(root, sizeof root, "%s/pauselistcheck.XXXXXX", tmp && tmp[0] ? tmp : "/tmp");
    if (!mkdtemp(root)) { perror("mkdtemp"); return 1; }
    if (setenv("HOME", root, 1) != 0) return 1;
    unsetenv("BRIDGEPLAY_BREAKER_QUIET");
    unsetenv("BRIDGEPLAY_PAUSE_LIST");

    uint8_t seed[32], seed2[32];
    for (int i = 0; i < 32; i++) { seed[i] = (uint8_t)(i + 1); seed2[i] = (uint8_t)(0xa0 + i); }
    ed25519_create_keypair(pub, priv, seed);
    ed25519_create_keypair(other_pub, other_priv, seed2);
    b64(pub, sizeof pub, key_b64);
    now_s = (long long)time(NULL);

    snprintf(pkg, sizeof pkg, "%s%s", root, NP_STEAM_PACKAGE_DIR);
    snprintf(support, sizeof support, "%s/Library/Application Support/bridgeplay", root);
    mkdirs(pkg);
    mkdirs(support);
    put(pkg, "steam_client_publicbeta_osx.installed", "x");
    put(pkg, "steam_client_publicbeta_osx.manifest", "\"osx\"\n{\n\t\"version\"\t\t\"" BUILD "\"\n}\n");
    put(pkg, "beta", "publicbeta\n");

    pure_cases();
    runtime_cases();

    int strays = 0;
    DIR *dh = opendir(support);
    struct dirent *e;
    while (dh && (e = readdir(dh)) != NULL)
        strays += strstr(e->d_name, ".tmp") != NULL || strstr(e->d_name, "fetch.") != NULL;
    if (dh) closedir(dh);
    CHECK("no temp file is left behind", strays == 0);

    nftw(root, scrub, 16, FTW_DEPTH | FTW_PHYS);
    if (fails) { printf("==> pauselistcheck: %d failed\n", fails); return 1; }
    printf("==> pauselistcheck: signatures, expiry, rollback, cache and fetch behave\n");
    return 0;
}
