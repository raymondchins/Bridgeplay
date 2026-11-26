// Prefix state for the Compatibility page. Mirrors the run script's checks
// (prefix_machine, notproton-build) so the page can say what a launch would say.
#include "prefixstate.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <signal.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define LIBRARIES_MAX 16
#define LINE_MAX_LEN  2048
#define FIELD_MAX     NP_PREFIX_FIELD_MAX

// A rebuild the dylib started but the app has not reported on yet.
#define STARTING_GRACE_SECONDS 30
// A result nobody saw while it was fresh says nothing about the prefix any more.
#define FINISHED_SHOWN_SECONDS 600

// PE machine words in system32/ntdll.dll.
#define MACHINE_AMD64 0x8664
#define MACHINE_ARM64 0xaa64
#define MACHINE_I386  0x014c

// Anything further in is not a header Wine wrote.
#define PE_OFFSET_MAX 0x1000

typedef struct {
    char paths[LIBRARIES_MAX][PATH_MAX];
    int  count;
} libraries_t;

static int is_dir(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static int is_file(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

// Next quoted VDF token on the line, with Steam's escapes decoded.
static const char *vdf_token(const char *p, char *out, size_t cap) {
    while (*p && *p != '"') p++;
    if (*p != '"') return NULL;
    p++;
    size_t n = 0;
    for (; *p && *p != '"'; p++) {
        char c = *p;
        if (c == '\\' && p[1]) {
            p++;
            c = *p == 'n' ? '\n' : *p == 't' ? '\t' : *p;
        }
        if (n + 1 < cap) out[n++] = c;
    }
    out[n] = '\0';
    return *p == '"' ? p + 1 : NULL;
}

static void add_library(libraries_t *libs, const char *path) {
    if (!*path || libs->count >= LIBRARIES_MAX) return;
    for (int i = 0; i < libs->count; i++)
        if (strcmp(libs->paths[i], path) == 0) return;
    snprintf(libs->paths[libs->count++], PATH_MAX, "%s", path);
}

static void read_libraries(const char *steam_root, libraries_t *libs) {
    libs->count = 0;
    char vdf[PATH_MAX];
    snprintf(vdf, sizeof vdf, "%s/steamapps/libraryfolders.vdf", steam_root);
    FILE *f = fopen(vdf, "r");
    if (f) {
        char line[LINE_MAX_LEN], key[FIELD_MAX], value[PATH_MAX];
        while (fgets(line, sizeof line, f)) {
            const char *rest = vdf_token(line, key, sizeof key);
            if (!rest || strcmp(key, "path") != 0) continue;
            if (vdf_token(rest, value, sizeof value)) add_library(libs, value);
        }
        fclose(f);
    }
    // A missing or empty file still means the default library, as in PrefixStore.
    if (libs->count == 0) add_library(libs, steam_root);
}

// compatdata/<appid> of the library holding the game. A shortcut has no manifest,
// so its prefix is wherever one already exists.
static int find_compatdata(uint32_t appid, const libraries_t *libs, char *out, size_t cap) {
    char probe[PATH_MAX];
    for (int i = 0; i < libs->count; i++) {
        snprintf(probe, sizeof probe, "%s/steamapps/appmanifest_%u.acf", libs->paths[i], appid);
        if (!is_file(probe)) continue;
        snprintf(out, cap, "%s/steamapps/compatdata/%u", libs->paths[i], appid);
        return 1;
    }
    for (int i = 0; i < libs->count; i++) {
        snprintf(probe, sizeof probe, "%s/steamapps/compatdata/%u/pfx", libs->paths[i], appid);
        if (!is_dir(probe)) continue;
        snprintf(out, cap, "%s/steamapps/compatdata/%u", libs->paths[i], appid);
        return 1;
    }
    return 0;
}

static int prefix_machine(const char *compatdata, uint16_t *machine) {
    char dll[PATH_MAX];
    snprintf(dll, sizeof dll, "%s/pfx/drive_c/windows/system32/ntdll.dll", compatdata);
    int fd = open(dll, O_RDONLY);
    if (fd < 0) return 0;
    uint32_t off = 0;
    uint8_t pe[6];
    int ok = pread(fd, &off, 4, 0x3c) == 4 && off < PE_OFFSET_MAX
          && pread(fd, pe, 6, off) == 6 && memcmp(pe, "PE\0\0", 4) == 0;
    close(fd);
    if (ok) *machine = (uint16_t)(pe[4] | pe[5] << 8);
    return ok;
}

static const char *machine_arch(uint16_t machine) {
    switch (machine) {
    case MACHINE_AMD64: return "rosetta";
    case MACHINE_ARM64: return "fex";
    case MACHINE_I386:  return "32-bit";
    default:            return "";
    }
}

static void chomp(char *s) {
    size_t n = strlen(s);
    while (n && (s[n - 1] == '\n' || s[n - 1] == '\r')) s[--n] = '\0';
}

// notproton-build is the build on one line and its display name on the next.
static void read_build_record(const char *compatdata, char *build, char *display) {
    build[0] = display[0] = '\0';
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/notproton-build", compatdata);
    FILE *f = fopen(path, "r");
    if (!f) return;
    if (fgets(build, FIELD_MAX, f)) chomp(build);
    if (fgets(display, FIELD_MAX, f)) chomp(display);
    fclose(f);
}

// The tools file is name, build, flavor and display, one tool per tab separated line.
static void read_tool(const char *support_root, np_prefix_state_t *st) {
    st->tool_build[0] = st->tool_flavor[0] = st->tool_display[0] = '\0';
    if (!st->tool[0]) return;
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/tools", support_root);
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[LINE_MAX_LEN];
    while (fgets(line, sizeof line, f)) {
        chomp(line);
        char *fields[4] = { line, NULL, NULL, NULL };
        for (int i = 1; i < 4; i++) {
            char *tab = fields[i - 1] ? strchr(fields[i - 1], '\t') : NULL;
            if (!tab) break;
            *tab = '\0';
            fields[i] = tab + 1;
        }
        if (!fields[3] || strcmp(fields[0], st->tool) != 0) continue;
        snprintf(st->tool_build, FIELD_MAX, "%s", fields[1]);
        snprintf(st->tool_flavor, FIELD_MAX, "%s", fields[2]);
        snprintf(st->tool_display, FIELD_MAX, "%s", fields[3]);
        break;
    }
    fclose(f);
}

// Wine's server for a prefix lives in server-<dev>-<ino> and holds a write lock on its
// lock file for as long as it runs. F_GETLK sees another process's lock without taking one.
static int server_running(const char *server_root, const char *compatdata) {
    char pfx[PATH_MAX], lock[PATH_MAX];
    struct stat st;
    snprintf(pfx, sizeof pfx, "%s/pfx", compatdata);
    if (!server_root || stat(pfx, &st) != 0) return 0;
    snprintf(lock, sizeof lock, "%s/server-%llx-%llx/lock", server_root,
             (unsigned long long)st.st_dev, (unsigned long long)st.st_ino);
    int fd = open(lock, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return 0;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != getuid()) {
        close(fd);
        return 0;
    }
    struct flock fl = { .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 1 };
    int held = fcntl(fd, F_GETLK, &fl) == 0 && fl.l_type != F_UNLCK;
    close(fd);
    return held;
}

static int is_phase(const char *p, const char *const *set) {
    for (; *set; set++)
        if (strcmp(p, *set) == 0) return 1;
    return 0;
}

static const char *const ACTIVE_PHASES[] = { "setup", "copy", "finish", NULL };
static const char *const DONE_PHASES[]   = { "done", "done-backup", "failed", NULL };

// notproton-rebuild is the phase on one line and the app's pid on the next. A pid of 0 is
// a rebuild the dylib just started, before the app has written anything.
static void read_rebuild(const char *compatdata, char *phase, size_t cap) {
    phase[0] = '\0';
    char path[PATH_MAX], line[FIELD_MAX], pid_text[FIELD_MAX] = "";
    snprintf(path, sizeof path, "%s/notproton-rebuild", compatdata);
    struct stat st;
    FILE *f = fopen(path, "r");
    if (!f) return;
    int ok = fgets(line, sizeof line, f) != NULL;
    if (ok && !fgets(pid_text, sizeof pid_text, f)) pid_text[0] = '\0';
    int have_stat = fstat(fileno(f), &st) == 0;
    fclose(f);
    if (!ok) return;
    chomp(line);
    if (is_phase(line, DONE_PHASES)) {
        if (have_stat && time(NULL) - st.st_mtime < FINISHED_SHOWN_SECONDS)
            snprintf(phase, cap, "%s", line);
        return;
    }
    if (!is_phase(line, ACTIVE_PHASES)) return;

    char lock_path[PATH_MAX];
    snprintf(lock_path, sizeof lock_path, "%s/.notproton-rebuild.lock", compatdata);
    int fd = open(lock_path, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
    int held = fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK;
    if (fd >= 0) close(fd);
    int alive = held || (strcmp(pid_text, "0\n") == 0 && have_stat
                        && time(NULL) - st.st_mtime < STARTING_GRACE_SECONDS);
    snprintf(phase, cap, "%s", alive ? line : "failed");
}

static void read_app(const char *support_root, char *out, size_t cap) {
    out[0] = '\0';
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/app-executable", support_root);
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[PATH_MAX];
    int ok = fgets(line, sizeof line, f) != NULL;
    fclose(f);
    if (!ok) return;
    chomp(line);
    if (line[0] == '/' && access(line, X_OK) == 0) snprintf(out, cap, "%s", line);
}

typedef struct {
    char  *buf;
    size_t cap;
    size_t len;
    int    ok;
} json_t;

static void json_raw(json_t *j, const char *s) {
    size_t n = strlen(s);
    if (!j->ok || j->len + n >= j->cap) { j->ok = 0; return; }
    memcpy(j->buf + j->len, s, n + 1);
    j->len += n;
}

static void json_string(json_t *j, const char *key, const char *value) {
    char piece[16];
    json_raw(j, j->len > 1 ? ",\"" : "\"");
    json_raw(j, key);
    json_raw(j, "\":\"");
    for (const unsigned char *p = (const unsigned char *)value; *p && j->ok; p++) {
        if (*p == '"' || *p == '\\') {
            piece[0] = '\\'; piece[1] = (char)*p; piece[2] = '\0';
        } else if (*p < 0x20) {
            snprintf(piece, sizeof piece, "\\u%04x", *p);
        } else {
            piece[0] = (char)*p; piece[1] = '\0';
        }
        json_raw(j, piece);
    }
    json_raw(j, "\"");
}

static void json_bool(json_t *j, const char *key, int value) {
    json_raw(j, j->len > 1 ? ",\"" : "\"");
    json_raw(j, key);
    json_raw(j, value ? "\":true" : "\":false");
}

size_t np_prefix_installed_apps(const char *steam_root, uint32_t *appids, size_t max) {
    libraries_t libs;
    read_libraries(steam_root, &libs);
    size_t n = 0;
    for (int i = 0; i < libs.count && n < max; i++) {
        char dir[PATH_MAX];
        snprintf(dir, sizeof dir, "%s/steamapps", libs.paths[i]);
        DIR *d = opendir(dir);
        if (!d) continue;
        struct dirent *e;
        while (n < max && (e = readdir(d))) {
            const char *digits = e->d_name + sizeof "appmanifest_" - 1;
            if (strncmp(e->d_name, "appmanifest_", sizeof "appmanifest_" - 1) != 0 ||
                *digits < '0' || *digits > '9') continue;
            char *end;
            errno = 0;
            unsigned long id = strtoul(digits, &end, 10);
            if (errno || strcmp(end, ".acf") != 0 || !id || id > UINT32_MAX) continue;
            appids[n++] = (uint32_t)id;
        }
        closedir(d);
    }
    return n;
}

void np_prefix_state(uint32_t appid, const char *tool, const np_prefix_roots_t *roots,
                     np_prefix_state_t *st) {
    memset(st, 0, sizeof *st);
    snprintf(st->tool, sizeof st->tool, "%s", tool ? tool : "");

    libraries_t libs;
    read_libraries(roots->steam_root, &libs);
    int found = find_compatdata(appid, &libs, st->compatdata, sizeof st->compatdata);
    if (!found) st->compatdata[0] = '\0';

    uint16_t machine = 0;
    if (found) {
        if (prefix_machine(st->compatdata, &machine)) {
            st->has_prefix = 1;
            snprintf(st->prefix_arch, sizeof st->prefix_arch, "%s", machine_arch(machine));
        }
        read_build_record(st->compatdata, st->last_build, st->last_display);
        read_rebuild(st->compatdata, st->rebuild, sizeof st->rebuild);
        st->running = server_running(roots->server_root, st->compatdata);
    }

    read_tool(roots->support_root, st);
    if (strcmp(st->tool_flavor, "fex") != 0 && strcmp(st->tool_flavor, "rosetta") != 0)
        st->tool_flavor[0] = '\0';
    read_app(roots->support_root, st->app, sizeof st->app);

    st->needs_rebuild = st->has_prefix && st->tool_flavor[0] && st->prefix_arch[0]
                     && strcmp(st->prefix_arch, st->tool_flavor) != 0;
}

int np_prefix_rebuilding(const np_prefix_state_t *st) {
    return is_phase(st->rebuild, ACTIVE_PHASES);
}

int np_prefix_state_json(uint32_t appid, const np_prefix_state_t *st, char *out, size_t cap) {
    char appid_text[16];
    snprintf(appid_text, sizeof appid_text, "%u", appid);

    json_t j = { out, cap, 0, cap > 0 };
    json_raw(&j, "{\"appid\":");
    json_raw(&j, appid_text);
    json_string(&j, "tool", st->tool);
    json_string(&j, "toolDisplay", st->tool_display);
    json_string(&j, "toolArch", st->tool_flavor);
    json_bool(&j, "prefix", st->has_prefix);
    json_string(&j, "prefixArch", st->prefix_arch);
    json_string(&j, "lastBuild", st->last_build);
    json_string(&j, "lastDisplay", st->last_display);
    json_bool(&j, "needsRebuild", st->needs_rebuild);
    json_bool(&j, "running", st->running);
    json_string(&j, "rebuild", st->rebuild);
    json_bool(&j, "app", st->app[0] != '\0');
    json_raw(&j, "}");
    return j.ok ? (int)j.len : -1;
}
