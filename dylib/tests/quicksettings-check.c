// The in-game sidebar's change requests: only the three settings and their menu values get
// through, each file is taken once, and odd names and links are left alone.
#include "../feats/quicksettings.c"

#include <stdlib.h>
#include <sys/time.h>

static int failed;

static void is(const char *what, const char *want, const char *got) {
    int ok = strcmp(want, got) == 0;
    if (!ok) failed++;
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) printf("        want %s\n        got  %s\n", want, got);
}

static void put(const char *dir, const char *name, const char *text) {
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "w");
    fputs(text, f);
    fclose(f);
}

static int exists(const char *dir, const char *name) {
    char path[1024];
    struct stat st;
    snprintf(path, sizeof path, "%s/%s", dir, name);
    return lstat(path, &st) == 0;
}

int main(void) {
    char tmpl[] = "/tmp/np-quicksettings-XXXXXX";
    char *dir = mkdtemp(tmpl);
    if (!dir) return 1;
    char json[2048];

    np_quick_settings_take("/nonexistent/quick-settings", 0, json, sizeof json, NULL);
    is("a missing folder answers an empty object", "{}", json);

    put(dir, "3372060.conf", "BRIDGEPLAY_FPS_LIMIT=30\nBRIDGEPLAY_PERF_OVERLAY=summary\r\n");
    int n = np_quick_settings_take(dir, 0, json, sizeof json, NULL);
    is("a game's changes come back as JSON", "{\"3372060\":{\"BRIDGEPLAY_FPS_LIMIT\":\"30\","
       "\"BRIDGEPLAY_PERF_OVERLAY\":\"summary\"}}", json);
    is("one app", "1", n == 1 ? "1" : "other");
    is("and the file is gone", "no", exists(dir, "3372060.conf") ? "yes" : "no");
    np_quick_settings_take(dir, 0, json, sizeof json, NULL);
    is("so a second poll finds nothing", "{}", json);

    put(dir, "42.conf", "BRIDGEPLAY_FPS_LIMIT=half\nBRIDGEPLAY_SCALING_FILTER=fsr\nPATH=/evil\n"
        "DYLD_INSERT_LIBRARIES=/x\nBRIDGEPLAY_SCALING_FILTER=integer\nnot a line\nBRIDGEPLAY_FPS_LIMIT_OFF=yes\n");
    np_quick_settings_take(dir, 0, json, sizeof json, NULL);
    is("only the sidebar's values of its keys pass", "{\"42\":{\"BRIDGEPLAY_SCALING_FILTER\":\"integer\"}}", json);

    put(dir, "46.conf", "BRIDGEPLAY_FPS_LIMIT=47\nBRIDGEPLAY_FPS_LIMIT_OFF=1\n");
    np_quick_settings_take(dir, 0, json, sizeof json, NULL);
    is("a slider value and the off switch pass",
       "{\"46\":{\"BRIDGEPLAY_FPS_LIMIT\":\"47\",\"BRIDGEPLAY_FPS_LIMIT_OFF\":\"1\"}}", json);

    put(dir, "43.conf", "BRIDGEPLAY_FPS_LIMIT=5\n");
    np_quick_settings_take(dir, 0, json, sizeof json, NULL);
    is("a file with nothing allowed is dropped", "{}", json);
    is("and removed", "no", exists(dir, "43.conf") ? "yes" : "no");

    put(dir, "notes.conf", "BRIDGEPLAY_FPS_LIMIT=30\n");
    put(dir, "007.conf", "BRIDGEPLAY_FPS_LIMIT=30\n");
    put(dir, "12345678901.conf", "BRIDGEPLAY_FPS_LIMIT=30\n");
    np_quick_settings_take(dir, 0, json, sizeof json, NULL);
    is("names that are not an appid are ignored", "{}", json);
    is("and left in place", "yes", exists(dir, "notes.conf") && exists(dir, "007.conf") ? "yes" : "no");

    char target[1024], link[1024];
    snprintf(target, sizeof target, "%s/notes.conf", dir);
    snprintf(link, sizeof link, "%s/99.conf", dir);
    symlink(target, link);
    np_quick_settings_take(dir, 0, json, sizeof json, NULL);
    is("a link is not followed", "{}", json);

    put(dir, "44.conf", "BRIDGEPLAY_FPS_LIMIT=30\n");
    char old_path[1024];
    snprintf(old_path, sizeof old_path, "%s/44.conf", dir);
    struct timeval then[2] = { { time(NULL) - 3600, 0 }, { time(NULL) - 3600, 0 } };
    utimes(old_path, then);
    int stale = 0;
    np_quick_settings_take(dir, time(NULL) - 60, json, sizeof json, &stale);
    is("a change left from an earlier Steam session is not handed on", "{}", json);
    is("it is counted", "1", stale == 1 ? "1" : "other");
    is("and removed", "no", exists(dir, "44.conf") ? "yes" : "no");
    put(dir, "45.conf", "BRIDGEPLAY_FPS_LIMIT=30\n");
    np_quick_settings_take(dir, time(NULL) - 60, json, sizeof json, &stale);
    is("one written in this session still is", "{\"45\":{\"BRIDGEPLAY_FPS_LIMIT\":\"30\"}}", json);
    is("and nothing is counted stale", "0", stale == 0 ? "0" : "other");

    is("allowed: overlay off", "1", np_quick_settings_allowed("BRIDGEPLAY_PERF_OVERLAY", "0") ? "1" : "0");
    const char *limits[][2] = { { "15", "1" }, { "60", "1" }, { "360", "1" }, { "14", "0" }, { "361", "0" },
                                { "045", "0" }, { "0", "0" }, { "display", "0" }, { "4a", "0" }, { "", "0" } };
    for (size_t i = 0; i < sizeof limits / sizeof limits[0]; i++) {
        char what[64];
        snprintf(what, sizeof what, "the limit %s: %s", limits[i][0], limits[i][1][0] == '1' ? "allowed" : "refused");
        is(what, limits[i][1], np_quick_settings_allowed("BRIDGEPLAY_FPS_LIMIT", limits[i][0]) ? "1" : "0");
    }
    is("refused: the Metal HUD is not a sidebar choice", "0",
       np_quick_settings_allowed("BRIDGEPLAY_PERF_OVERLAY", "hud") ? "1" : "0");
    is("refused: MTL_HUD_ENABLED", "0", np_quick_settings_allowed("MTL_HUD_ENABLED", "1") ? "1" : "0");

    char cmd[1100];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir);
    system(cmd);
    if (failed) {
        printf("==> quicksettings-check: %d failed\n", failed);
        return 1;
    }
    printf("==> quicksettings-check: change requests are read once and filtered\n");
    return 0;
}
