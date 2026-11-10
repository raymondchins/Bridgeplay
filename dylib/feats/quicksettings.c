// Changes made in a game's quick settings sidebar (overlay-shim/sidebar.m), on their way to
// the game's Steam launch options.
//
// The game process cannot touch Steam's config, so it writes what the player picked to
// <support>/quick-settings/<appid>.conf as KEY=VALUE lines. The Steam page polls the
// NotProton.TakeQuickSettings route, which hands it these as JSON and removes the files;
// the page then writes them through the Bridgeplay panel's own launch-option logic, the
// same path a pick in Steam Properties › Bridgeplay takes. Only the settings the sidebar
// offers, with the values it can set, get through: the frame rate limit as a whole number
// from 15 to 360 and its off switch as 0 or 1.
#include "quicksettings.h"

#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *const qs_overlay[] = { "0", "fps", "summary", "detailed", NULL };
static const char *const qs_limit_off[] = { "0", "1", NULL };
static const char *const qs_filter[] = { "0", "linear", "nearest", "integer", NULL };

static const struct {
    const char *key;
    const char *const *values;
} qs_keys[] = {
    { "BRIDGEPLAY_PERF_OVERLAY", qs_overlay },
    { "BRIDGEPLAY_FPS_LIMIT_OFF", qs_limit_off },
    { "BRIDGEPLAY_SCALING_FILTER", qs_filter },
};

// The frame rate limit slider's whole numbers, 15 to 360, written without a leading zero.
static int qs_limit(const char *value) {
    size_t n = strlen(value);
    if (n < 2 || n > 3 || value[0] == '0') return 0;
    int v = 0;
    for (size_t i = 0; i < n; i++) {
        if (value[i] < '0' || value[i] > '9') return 0;
        v = v * 10 + (value[i] - '0');
    }
    return v >= 15 && v <= 360;
}

int np_quick_settings_allowed(const char *key, const char *value) {
    if (strcmp(key, "BRIDGEPLAY_FPS_LIMIT") == 0) return qs_limit(value);
    for (size_t i = 0; i < sizeof(qs_keys) / sizeof(qs_keys[0]); i++) {
        if (strcmp(key, qs_keys[i].key) != 0) continue;
        for (const char *const *v = qs_keys[i].values; *v; v++)
            if (strcmp(value, *v) == 0) return 1;
        return 0;
    }
    return 0;
}

static int qs_appid(const char *name, char *out, size_t cap) {
    size_t n = strlen(name);
    if (n < 6 || n - 5 >= cap || n - 5 > 10 || strcmp(name + n - 5, ".conf") != 0) return 0;
    for (size_t i = 0; i < n - 5; i++)
        if (name[i] < '0' || name[i] > '9') return 0;
    if (name[0] == '0') return 0;
    memcpy(out, name, n - 5);
    out[n - 5] = '\0';
    return 1;
}

static int qs_append(char *json, size_t cap, size_t *len, const char *text) {
    size_t n = strlen(text);
    if (*len + n + 1 >= cap) return 0;
    memcpy(json + *len, text, n + 1);
    *len += n;
    return 1;
}

// One file's accepted pairs as "KEY":"VALUE",...; returns how many.
static int qs_read_file(int fd, char *pairs, size_t cap) {
    char buf[1024];
    ssize_t got = read(fd, buf, sizeof(buf) - 1);
    if (got <= 0) return 0;
    buf[got] = '\0';
    int count = 0;
    size_t len = 0;
    pairs[0] = '\0';
    for (char *line = strtok(buf, "\n"); line; line = strtok(NULL, "\n")) {
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = '\0';
        char *value = eq + 1;
        size_t vl = strlen(value);
        while (vl && (value[vl - 1] == '\r' || value[vl - 1] == ' ')) value[--vl] = '\0';
        if (!np_quick_settings_allowed(line, value)) continue;
        char pair[96];
        snprintf(pair, sizeof pair, "%s\"%s\":\"%s\"", count ? "," : "", line, value);
        if (!qs_append(pairs, cap, &len, pair)) break;
        count++;
    }
    return count;
}

int np_quick_settings_take(const char *dir, time_t since, char *json, size_t cap, int *stale) {
    size_t len = 0;
    if (stale) *stale = 0;
    if (cap < 3) return -1;
    json[0] = '\0';
    qs_append(json, cap, &len, "{");
    DIR *d = opendir(dir);
    int apps = 0;
    if (d) {
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            char appid[16], path[1024], taken[1100];
            if (!qs_appid(e->d_name, appid, sizeof appid)) continue;
            snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
            // Claimed by renaming first, so a change the game writes meanwhile lands in a new
            // file for the next poll rather than being deleted unread.
            snprintf(taken, sizeof taken, "%s.taking", path);
            if (rename(path, taken) != 0) continue;
            int fd = open(taken, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
            char pairs[512];
            struct stat st;
            int regular = fd >= 0 && fstat(fd, &st) == 0 && S_ISREG(st.st_mode);
            int fresh = regular && st.st_mtime >= since;
            if (regular && !fresh && stale) (*stale)++;
            int count = fresh ? qs_read_file(fd, pairs, sizeof pairs) : 0;
            if (fd >= 0) close(fd);
            unlink(taken);
            if (!count) continue;
            char entry[600];
            snprintf(entry, sizeof entry, "%s\"%s\":{%s}", apps ? "," : "", appid, pairs);
            if (!qs_append(json, cap, &len, entry)) break;
            apps++;
        }
        closedir(d);
    }
    if (!qs_append(json, cap, &len, "}")) return -1;
    return apps;
}
