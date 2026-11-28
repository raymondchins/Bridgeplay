// Crash-loop breaker, Pause and the health files. See breaker.h.
#include "breaker.h"
#include "pauselist.h"
#include "../version.h"
#include "../util/file.h"
#include "../util/log.h"
#include "cJSON.h"

#include <dirent.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <pthread.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

#define NP_STEAM_PACKAGE_DIR "/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/package"

static void set_str(char *dst, size_t cap, const char *src) {
    snprintf(dst, cap, "%s", src ? src : "");
}

static int stage_is(const np_boot_t *s, const char *stage) {
    return strcmp(s->stage, stage) == 0;
}

const char *np_mode_name(np_mode_t mode) {
    switch (mode) {
        case NP_MODE_PASSIVE: return "passive";
        case NP_MODE_OFF:     return "off";
        default:              return "active";
    }
}

// The previous start is counted bad when it never reached healthy or a clean exit. The stub
// in /Applications execs the client in the same pid, so that second constructor is the same
// start (a hand-off), told apart from a reused pid by the process start time.
np_boot_verdict_t np_boot_decide(const np_boot_t *prev, const np_boot_env_t *env,
                                 np_boot_t *next, np_mode_t *mode, int *notify) {
    *notify = 0;
    if (env->paused) {
        *mode = NP_MODE_OFF;
        return NP_BOOT_PAUSED;
    }
    if (env->listed) {
        *mode = NP_MODE_PASSIVE;
        return NP_BOOT_LISTED;
    }

    int have = prev && prev->key[0];
    int same_key = have && strcmp(prev->key, env->key) == 0;
    int handoff = have && prev->pid == env->pid && prev->t0 + 1 >= env->own_start;

    if (have && !handoff && env->prev_running) {
        *mode = same_key && prev->strikes >= NP_BOOT_STRIKES_MAX ? NP_MODE_PASSIVE
                                                                  : NP_MODE_ACTIVE;
        return NP_BOOT_SECOND;
    }

    np_boot_t s;
    memset(&s, 0, sizeof s);
    if (same_key) {
        s = *prev;
        if (!handoff && (stage_is(prev, NP_STAGE_BOOT) || stage_is(prev, NP_STAGE_CLIENT)) &&
            s.strikes < NP_BOOT_STRIKES_MAX)
            s.strikes++;
    }
    set_str(s.key, sizeof s.key, env->key);
    s.pid = env->pid;
    s.t0 = env->now;
    if (s.strikes >= NP_BOOT_STRIKES_MAX) {
        set_str(s.stage, sizeof s.stage, NP_STAGE_PASSIVE);
        *mode = NP_MODE_PASSIVE;
        if (!s.notified) {
            s.notified = 1;
            *notify = 1;
        }
    } else {
        set_str(s.stage, sizeof s.stage, NP_STAGE_BOOT);
        *mode = NP_MODE_ACTIVE;
    }
    *next = s;
    return NP_BOOT_RECORD;
}

int np_boot_advance(np_boot_t *s, int pid, const char *stage) {
    if (!s->key[0] || s->pid != pid)
        return 0;
    if (strcmp(stage, NP_STAGE_CLIENT) == 0) {
        if (!stage_is(s, NP_STAGE_BOOT))
            return 0;
    } else if (strcmp(stage, NP_STAGE_HEALTHY) == 0) {
        if (!stage_is(s, NP_STAGE_BOOT) && !stage_is(s, NP_STAGE_CLIENT))
            return 0;
        s->strikes = 0;
        s->notified = 0;
    } else if (strcmp(stage, NP_STAGE_EXITED) == 0) {
        if (stage_is(s, NP_STAGE_PASSIVE) || stage_is(s, NP_STAGE_EXITED))
            return 0;
    } else {
        return 0;
    }
    set_str(s->stage, sizeof s->stage, stage);
    return 1;
}

static double num_field(const cJSON *root, const char *name) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(root, name);
    return cJSON_IsNumber(v) ? v->valuedouble : 0;
}

int np_boot_read(const char *path, np_boot_t *out) {
    memset(out, 0, sizeof *out);
    size_t len = 0;
    uint8_t *raw = np_read_whole_file(path, &len);
    if (!raw)
        return -1;
    cJSON *root = cJSON_ParseWithLength((const char *)raw, len);
    free(raw);

    const cJSON *key = cJSON_GetObjectItemCaseSensitive(root, "key");
    const cJSON *stage = cJSON_GetObjectItemCaseSensitive(root, "stage");
    int ok = cJSON_IsObject(root) && cJSON_IsString(key) && cJSON_IsString(stage) &&
             key->valuestring[0] && strlen(key->valuestring) < sizeof out->key &&
             strlen(stage->valuestring) < sizeof out->stage;
    if (ok) {
        set_str(out->key, sizeof out->key, key->valuestring);
        set_str(out->stage, sizeof out->stage, stage->valuestring);
        out->pid = (int)num_field(root, "pid");
        out->t0 = (long long)num_field(root, "t0");
        out->strikes = (int)num_field(root, "strikes");
        out->notified = num_field(root, "notified") != 0;
    } else {
        memset(out, 0, sizeof *out);
    }
    cJSON_Delete(root);
    return ok ? 0 : -1;
}

static int write_json(const char *path, cJSON *root) {
    char *text = root ? cJSON_PrintUnformatted(root) : NULL;
    cJSON_Delete(root);
    if (!text)
        return -1;
    size_t len = strlen(text);
    text[len] = '\n';
    int rc = np_write_atomic(path, text, len + 1);
    free(text);
    return rc;
}

int np_boot_write(const char *path, const np_boot_t *s) {
    cJSON *root = cJSON_CreateObject();
    if (!root)
        return -1;
    cJSON_AddStringToObject(root, "key", s->key);
    cJSON_AddNumberToObject(root, "pid", s->pid);
    cJSON_AddNumberToObject(root, "t0", (double)s->t0);
    cJSON_AddStringToObject(root, "stage", s->stage);
    cJSON_AddNumberToObject(root, "strikes", s->strikes);
    cJSON_AddNumberToObject(root, "notified", s->notified);
    return write_json(path, root);
}

int np_write_atomic(const char *path, const char *bytes, size_t len) {
    static unsigned serial;
    char tmp[PATH_MAX];
    int n = snprintf(tmp, sizeof tmp, "%s.%d.%u.tmp", path, (int)getpid(),
                     __atomic_fetch_add(&serial, 1, __ATOMIC_RELAXED));
    if (n < 0 || (size_t)n >= sizeof tmp)
        return -1;
    int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0644);
    if (fd < 0)
        return -1;
    for (size_t done = 0; done < len; ) {
        ssize_t w = write(fd, bytes + done, len - done);
        if (w < 0 && errno == EINTR)
            continue;
        if (w <= 0) {
            close(fd);
            unlink(tmp);
            return -1;
        }
        done += (size_t)w;
    }
    if (close(fd) != 0 || rename(tmp, path) != 0) {
        unlink(tmp);
        return -1;
    }
    return 0;
}

// "version" directly inside the manifest's top block, digits only.
static int manifest_version(const char *text, size_t len, char *out, size_t cap) {
    int depth = 0;
    int want_value = 0;
    for (size_t i = 0; i < len; i++) {
        char c = text[i];
        if (c == '{') { depth++; want_value = 0; continue; }
        if (c == '}') { depth--; want_value = 0; continue; }
        if (c != '"')
            continue;
        size_t start = ++i;
        while (i < len && text[i] != '"')
            i++;
        if (i >= len)
            return -1;
        size_t tlen = i - start;
        if (want_value) {
            if (tlen == 0 || tlen >= cap || tlen > 20)
                return -1;
            for (size_t k = 0; k < tlen; k++)
                if (text[start + k] < '0' || text[start + k] > '9')
                    return -1;
            memcpy(out, text + start, tlen);
            out[tlen] = '\0';
            return 0;
        }
        want_value = depth == 1 && tlen == 7 && memcmp(text + start, "version", 7) == 0;
    }
    return -1;
}

typedef struct {
    char            name[256];
    struct timespec mtime;
} installed_t;

static int newer(const installed_t *a, const installed_t *b) {
    if (a->mtime.tv_sec != b->mtime.tv_sec)
        return a->mtime.tv_sec > b->mtime.tv_sec;
    return a->mtime.tv_nsec > b->mtime.tv_nsec;
}

// The "version" in the manifest beside the newest package/*.installed. A newest one with no
// readable manifest gives way to the next.
int np_steam_build(const char *package_dir, char *out, size_t cap) {
    set_str(out, cap, "0");
    DIR *dh = opendir(package_dir);
    if (!dh)
        return -1;

    installed_t found[16];
    int count = 0;
    struct dirent *e;
    while ((e = readdir(dh)) != NULL && count < (int)(sizeof found / sizeof found[0])) {
        size_t len = strlen(e->d_name);
        if (len <= 10 || len >= sizeof found[0].name ||
            strcmp(e->d_name + len - 10, ".installed") != 0)
            continue;
        char path[PATH_MAX];
        struct stat st;
        snprintf(path, sizeof path, "%s/%s", package_dir, e->d_name);
        if (stat(path, &st) != 0 || !S_ISREG(st.st_mode))
            continue;
        set_str(found[count].name, sizeof found[count].name, e->d_name);
        found[count].mtime = st.st_mtimespec;
        count++;
    }
    closedir(dh);

    for (int i = 1; i < count; i++)
        for (int j = i; j > 0 && newer(&found[j], &found[j - 1]); j--) {
            installed_t t = found[j];
            found[j] = found[j - 1];
            found[j - 1] = t;
        }

    for (int i = 0; i < count; i++) {
        char path[PATH_MAX];
        size_t base = strlen(found[i].name) - 10;
        snprintf(path, sizeof path, "%s/%.*s.manifest", package_dir, (int)base, found[i].name);
        size_t len = 0;
        uint8_t *text = np_read_whole_file(path, &len);
        if (!text)
            continue;
        int rc = manifest_version((const char *)text, len, out, cap);
        free(text);
        if (rc == 0)
            return 0;
    }
    set_str(out, cap, "0");
    return -1;
}

// package/beta names the beta branch Steam is on; no file means the stable client.
void np_steam_channel(const char *package_dir, char *out, size_t cap) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/beta", package_dir);
    size_t len = 0, kept = 0;
    int odd = 0;
    uint8_t *text = np_read_whole_file(path, &len);
    for (size_t i = 0; text && i < len && !odd; i++) {
        char c = (char)text[i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
            c == '_' || c == '-' || c == '.') {
            if (kept + 1 >= cap || kept >= 63)
                odd = 1;
            else
                out[kept++] = c;
        } else if (c != '\n' && c != '\r' && c != ' ' && c != '\t')
            odd = 1;
    }
    free(text);
    if (odd)
        set_str(out, cap, "unknown");
    else if (kept == 0)
        set_str(out, cap, "stable");
    else
        out[kept] = '\0';
}

char *np_health_format(const np_health_t *h) {
    cJSON *root = cJSON_CreateObject();
    if (!root)
        return NULL;
    cJSON_AddNumberToObject(root, "written", (double)h->written);
    cJSON_AddNumberToObject(root, "pid", h->pid);
    cJSON_AddNumberToObject(root, "patch_build", h->patch_build);
    cJSON_AddNumberToObject(root, "steam_build", (double)h->steam_build);
    cJSON_AddStringToObject(root, "channel", h->channel);
    cJSON_AddNumberToObject(root, "sigdb_build", (double)h->sigdb_build);
    cJSON_AddStringToObject(root, "mode", np_mode_name(h->mode));
    cJSON_AddNumberToObject(root, "strikes", h->strikes);
    cJSON_AddNumberToObject(root, "signatures_resolved", h->signatures_resolved);
    cJSON_AddNumberToObject(root, "signatures_required", h->signatures_required);
    cJSON_AddNumberToObject(root, "hooks_installed", h->hooks_installed);
    cJSON_AddNumberToObject(root, "hooks_total", h->hooks_total);
    cJSON_AddBoolToObject(root, "layout_known", h->layout_known != 0);
    cJSON_AddStringToObject(root, "mode_reason", h->reason);
    cJSON_AddStringToObject(root, "pause_list", h->pause_list);
    cJSON_AddNumberToObject(root, "pause_list_serial", (double)h->pause_serial);
    cJSON_AddNumberToObject(root, "pause_list_expires", (double)h->pause_expires);
    cJSON_AddStringToObject(root, "pause_note", h->pause_note);
    cJSON_AddStringToObject(root, "pause_fixed_in", h->pause_fixed_in);
    cJSON_AddStringToObject(root, "pause_url", h->pause_url);
    char *text = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    return text;
}

// ---- Runtime ------------------------------------------------------------------------

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static char        g_boot_path[PATH_MAX];
static char        g_health_path[PATH_MAX];
static np_health_t g_health;
static int         g_owner;      // this process counts the start and writes health.json
static int         g_decided;    // steam_osx: g_mode holds this start's decision
static np_mode_t   g_mode = NP_MODE_ACTIVE;
static int         g_exited;

static int support_dir(char *buf, size_t cap) {
    const char *home = np_home_dir();
    if (!home)
        return -1;
    np_support_path(buf, cap, home, NULL);
    mkdir(buf, 0755);
    return buf[0] ? 0 : -1;
}

static int support_file(char *buf, size_t cap, const char *name) {
    char dir[PATH_MAX];
    if (support_dir(dir, sizeof dir) != 0)
        return -1;
    int n = snprintf(buf, cap, "%s/%s", dir, name);
    return n < 0 || (size_t)n >= cap ? -1 : 0;
}

static int is_paused(void) {
    char path[PATH_MAX];
    struct stat st;
    return support_file(path, sizeof path, NP_PAUSED_FILE) == 0 && lstat(path, &st) == 0;
}

static void package_dir(char *buf, size_t cap) {
    const char *home = np_home_dir();
    snprintf(buf, cap, "%s" NP_STEAM_PACKAGE_DIR, home ? home : "/nonexistent");
}

static long long proc_start(int pid, char *comm, size_t cap) {
    struct proc_bsdinfo bi;
    if (pid <= 0 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) != (int)sizeof bi)
        return -1;
    if (comm)
        set_str(comm, cap, bi.pbi_comm);
    return (long long)bi.pbi_start_tvsec;
}

// Another steam_osx with that pid, started no later than the time it wrote.
static int steam_running(int pid, long long t0) {
    if (pid <= 0 || pid == getpid())
        return 0;
    char comm[MAXCOMLEN + 1] = "";
    long long started = proc_start(pid, comm, sizeof comm);
    return started >= 0 && strcmp(comm, "steam_osx") == 0 && (t0 <= 0 || started <= t0 + 1);
}

// The health file of another steam_osx that is still running is not this start's to replace.
static int health_owned_elsewhere(void) {
    size_t len = 0;
    uint8_t *raw = np_read_whole_file(g_health_path, &len);
    if (!raw)
        return 0;
    cJSON *root = cJSON_ParseWithLength((const char *)raw, len);
    free(raw);
    int pid = (int)num_field(root, "pid");
    long long written = (long long)num_field(root, "written");
    cJSON_Delete(root);
    return steam_running(pid, written);
}

static void health_write_locked(void) {
    if (!g_owner || !g_health_path[0])
        return;
    g_health.written = (long long)time(NULL);
    char *text = np_health_format(&g_health);
    if (!text)
        return;
    if (np_write_atomic(g_health_path, text, strlen(text)) != 0)
        NP_WARN("breaker: could not write %s", g_health_path);
    free(text);
}

// Two steam_osx starting at once must not both read no record and both count the start, so
// the read, the decision and the write happen under one lock across processes. The lock is
// waited on for at most NP_BOOT_LOCK_MS; past that the start goes on without it.
#define NP_BOOT_LOCK_FILE "boot.lock"
#define NP_BOOT_LOCK_MS   2000

static int boot_lock(void) {
    char path[PATH_MAX];
    if (support_file(path, sizeof path, NP_BOOT_LOCK_FILE) != 0)
        return -1;
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0)
        return -1;
    for (int waited = 0; flock(fd, LOCK_EX | LOCK_NB) != 0; waited += 10) {
        if ((errno != EWOULDBLOCK && errno != EINTR) || waited >= NP_BOOT_LOCK_MS) {
            NP_WARN("breaker: %s stayed locked, counting this start without it", path);
            close(fd);
            return -1;
        }
        struct timespec pause = { 0, 10 * 1000 * 1000 };
        nanosleep(&pause, NULL);
    }
    return fd;
}

static void boot_unlock(int fd) {
    if (fd >= 0)
        close(fd);
}

void np_breaker_drop_insert(void) {
    unsetenv("DYLD_INSERT_LIBRARIES");
    unsetenv("SDL_JOYSTICK_BLACKLIST_DEVICES");
}

// Posted by the app, so it carries Bridgeplay's name. sh backgrounds open and exits at once,
// so Steam's start never waits on LaunchServices.
static void post_notification(const char *subtitle, const char *body) {
    char *const argv[] = {
        "/bin/sh", "-c",
        "/usr/bin/open -n -g -b com.bridgeplay.Bridgeplay --args --notify \"$1\" \"$2\" \"$3\""
        " </dev/null >/dev/null 2>&1 &",
        "sh", "Bridgeplay", (char *)subtitle, (char *)body,
        NULL,
    };
    pid_t pid;
    if (posix_spawn(&pid, "/bin/sh", NULL, NULL, argv, environ) != 0) {
        NP_WARN("breaker: could not post the notification");
        return;
    }
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
}

// Tests swap this out so nothing reaches the real app.
static void (*g_notify)(const char *subtitle, const char *body) = post_notification;

static void notify(const char *subtitle, const char *body) {
    const char *quiet = getenv("BRIDGEPLAY_BREAKER_QUIET");
    if (quiet && quiet[0] && strcmp(quiet, "0") != 0)
        return;
    g_notify(subtitle, body);
}

static void notify_trip(void) {
    notify("Steam opened without Bridgeplay",
           "Steam stopped twice soon after starting, so it opens without Bridgeplay until Steam "
           "or Bridgeplay updates. Open Bridgeplay to try again.");
}

static void notify_listed(const np_pl_entry_t *e) {
    char body[512];
    const char *gap = e->note[0] ? " " : "";
    if (e->fixed_in[0])
        snprintf(body, sizeof body, "%s%sFixed in Bridgeplay %s. Open Bridgeplay to update, "
                 "then restart Steam.", e->note, gap, e->fixed_in);
    else
        snprintf(body, sizeof body, "%s%sSteam opens without Bridgeplay until a fix ships, so "
                 "Windows games won't run yet.", e->note, gap);
    notify("Paused for this Steam build", body);
}

static int g_off_modes = NP_BREAKER_OFF_MODES;

// With the off modes disabled a start the breaker would have made passive stays active, and is
// recorded as a normal start, so a healthy one clears its strikes.
static void keep_active(np_boot_verdict_t verdict, np_boot_t *next, np_mode_t *mode,
                        int *first_trip) {
    if (*mode == NP_MODE_ACTIVE)
        return;
    NP_WARN("breaker: %s start kept active, the off modes are disabled",
            *mode == NP_MODE_OFF ? "a paused" : "a passive");
    *mode = NP_MODE_ACTIVE;
    *first_trip = 0;
    if (verdict == NP_BOOT_RECORD && stage_is(next, NP_STAGE_PASSIVE))
        set_str(next->stage, sizeof next->stage, NP_STAGE_BOOT);
}

np_mode_t np_breaker_start(void) {
    g_decided = 1;
    g_mode = NP_MODE_ACTIVE;
    if (support_file(g_boot_path, sizeof g_boot_path, NP_BOOT_FILE) != 0 ||
        support_file(g_health_path, sizeof g_health_path, NP_HEALTH_FILE) != 0) {
        g_boot_path[0] = g_health_path[0] = '\0';
        NP_WARN("breaker: no support folder, starts are not counted");
        return g_mode;
    }

    char pkg[PATH_MAX], build[24], key[64], channel[64], dir[PATH_MAX] = "";
    package_dir(pkg, sizeof pkg);
    np_steam_build(pkg, build, sizeof build);
    np_steam_channel(pkg, channel, sizeof channel);
    snprintf(key, sizeof key, "%s:%d", build, BRIDGEPLAY_BUILD);

    long long now = (long long)time(NULL);
    int paused = g_off_modes && is_paused();
    np_pl_result_t list = { .status = NP_PL_UNKEYED };
    if (g_off_modes && support_dir(dir, sizeof dir) == 0)
        np_pause_list_start(dir, strtoull(build, NULL, 10), channel, BRIDGEPLAY_BUILD, paused,
                            now, &list);

    int lock = boot_lock();
    np_boot_t prev;
    int have = np_boot_read(g_boot_path, &prev) == 0;
    np_boot_env_t env = {
        .key = key,
        .pid = getpid(),
        .now = now,
        .own_start = proc_start(getpid(), NULL, 0),
        .paused = paused,
        .listed = list.matched,
        .prev_running = have && steam_running(prev.pid, prev.t0),
    };
    if (env.own_start < 0)
        env.own_start = 0;

    np_boot_t next;
    int first_trip = 0;
    np_mode_t mode;
    np_boot_verdict_t verdict = np_boot_decide(have ? &prev : NULL, &env, &next, &mode, &first_trip);
    if (!g_off_modes)
        keep_active(verdict, &next, &mode, &first_trip);
    int strikes = have && strcmp(prev.key, key) == 0 ? prev.strikes : 0;
    if (verdict == NP_BOOT_RECORD) {
        strikes = next.strikes;
        if (np_boot_write(g_boot_path, &next) != 0)
            NP_WARN("breaker: could not write %s, this start is not counted", g_boot_path);
    }
    boot_unlock(lock);

    pthread_mutex_lock(&g_lock);
    g_mode = mode;
    g_owner = verdict == NP_BOOT_RECORD ||
              ((verdict == NP_BOOT_PAUSED || verdict == NP_BOOT_LISTED) && !health_owned_elsewhere());
    memset(&g_health, 0, sizeof g_health);
    g_health.pid = getpid();
    g_health.patch_build = BRIDGEPLAY_BUILD;
    g_health.steam_build = strtoull(build, NULL, 10);
    set_str(g_health.channel, sizeof g_health.channel, channel);
    g_health.mode = mode;
    g_health.strikes = strikes;
    set_str(g_health.reason, sizeof g_health.reason,
            mode == NP_MODE_OFF ? NP_REASON_PAUSED
            : verdict == NP_BOOT_LISTED ? NP_REASON_PAUSE_LIST
            : mode == NP_MODE_PASSIVE ? NP_REASON_STRIKES : "");
    set_str(g_health.pause_list, sizeof g_health.pause_list, np_pl_status_name(list.status));
    g_health.pause_serial = list.serial;
    g_health.pause_expires = list.expires;
    if (verdict == NP_BOOT_LISTED) {
        set_str(g_health.pause_note, sizeof g_health.pause_note, list.entry.note);
        set_str(g_health.pause_fixed_in, sizeof g_health.pause_fixed_in, list.entry.fixed_in);
        set_str(g_health.pause_url, sizeof g_health.pause_url, list.entry.url);
    }
    health_write_locked();
    pthread_mutex_unlock(&g_lock);

    if (verdict == NP_BOOT_LISTED)
        NP_ERR("breaker: the pause list names Steam %s (%s) with Bridgeplay build %d, so "
               "Steam starts without Bridgeplay%s%s", build, channel, BRIDGEPLAY_BUILD,
               list.entry.fixed_in[0] ? "; fixed in " : "", list.entry.fixed_in);
    else switch (mode) {
        case NP_MODE_PASSIVE:
            NP_ERR("breaker: %d bad starts on Steam %s with Bridgeplay build %d, so Steam "
                   "starts without Bridgeplay until either updates or Try Again in the app",
                   strikes, build, BRIDGEPLAY_BUILD);
            break;
        case NP_MODE_OFF:
            NP_LOG("breaker: paused in the app, Steam starts without Bridgeplay");
            break;
        default:
            NP_LOG("breaker: Steam %s (%s), %d bad start(s) on this build%s", build,
                   g_health.channel, strikes,
                   verdict == NP_BOOT_SECOND ? ", another Steam owns the count" : "");
            break;
    }

    if (mode != NP_MODE_ACTIVE) {
        np_breaker_drop_insert();
        if (verdict == NP_BOOT_LISTED) {
            if (np_pause_list_announce(dir, key, &list.entry))
                notify_listed(&list.entry);
        } else if (first_trip) {
            notify_trip();
        }
    }
    return mode;
}

static pthread_once_t g_peek_once = PTHREAD_ONCE_INIT;
static np_mode_t      g_peek_mode = NP_MODE_ACTIVE;

// Steam Helper follows the start steam_osx recorded; anything unreadable means active.
static void peek_mode(void) {
    if (!g_off_modes)
        return;
    if (is_paused()) {
        g_peek_mode = NP_MODE_OFF;
        return;
    }
    char path[PATH_MAX];
    size_t len = 0;
    uint8_t *raw = support_file(path, sizeof path, NP_HEALTH_FILE) == 0
                   ? np_read_whole_file(path, &len) : NULL;
    if (!raw)
        return;
    cJSON *root = cJSON_ParseWithLength((const char *)raw, len);
    free(raw);
    const cJSON *mode = cJSON_GetObjectItemCaseSensitive(root, "mode");
    if (cJSON_IsString(mode)) {
        if (strcmp(mode->valuestring, "passive") == 0)
            g_peek_mode = NP_MODE_PASSIVE;
        else if (strcmp(mode->valuestring, "off") == 0)
            g_peek_mode = NP_MODE_OFF;
    }
    cJSON_Delete(root);
}

np_mode_t np_breaker_mode(void) {
    if (g_decided)
        return g_mode;
    pthread_once(&g_peek_once, peek_mode);
    return g_peek_mode;
}

static void mark(const char *stage) {
    pthread_mutex_lock(&g_lock);
    int exiting = strcmp(stage, NP_STAGE_EXITED) == 0;
    np_boot_t s;
    int lock = g_owner && !g_exited && g_boot_path[0] ? boot_lock() : -1;
    if (g_owner && !g_exited && g_boot_path[0] && np_boot_read(g_boot_path, &s) == 0 &&
        np_boot_advance(&s, getpid(), stage)) {
        if (np_boot_write(g_boot_path, &s) == 0)
            NP_LOG("breaker: this start reached %s", stage);
        if (strcmp(stage, NP_STAGE_HEALTHY) == 0 && g_health.strikes) {
            g_health.strikes = 0;
            health_write_locked();
        }
    }
    boot_unlock(lock);
    if (exiting)
        g_exited = 1;
    pthread_mutex_unlock(&g_lock);
}

void np_breaker_client_seen(void) {
    mark(NP_STAGE_CLIENT);
}

void np_breaker_exit(void) {
    mark(NP_STAGE_EXITED);
}

static void *healthy_after(void *unused) {
    (void)unused;
    struct timespec left = { NP_BOOT_HEALTHY_SECONDS, 0 };
    while (nanosleep(&left, &left) != 0 && errno == EINTR) {}
    mark(NP_STAGE_HEALTHY);
    return NULL;
}

static struct timespec g_armed_at;

// Logs once whether Steam's main queue drains. HYPOTHESIS (#4298): stamping healthy there
// would also catch a frozen Steam; this line is the evidence for or against it.
static void main_queue_answered(void *unused) {
    (void)unused;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    long ms = (long)(now.tv_sec - g_armed_at.tv_sec) * 1000 +
              (now.tv_nsec - g_armed_at.tv_nsec) / 1000000;
    NP_LOG("breaker: Steam's main queue answered %ld ms after the hooks installed", ms);
}

void np_breaker_arm_healthy(void) {
    static int armed;
    if (!g_owner || g_mode != NP_MODE_ACTIVE || __atomic_exchange_n(&armed, 1, __ATOMIC_ACQ_REL))
        return;

    pthread_attr_t attr;
    pthread_t thread;
    if (pthread_attr_init(&attr) != 0)
        return;
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&thread, &attr, healthy_after, NULL) != 0)
        NP_WARN("breaker: no timer thread, this start cannot count as healthy");
    pthread_attr_destroy(&attr);

    clock_gettime(CLOCK_MONOTONIC, &g_armed_at);
    dispatch_async_f(dispatch_get_main_queue(), NULL, main_queue_answered);
}

void np_health_signatures(int resolved, int required) {
    pthread_mutex_lock(&g_lock);
    g_health.signatures_resolved += resolved;
    g_health.signatures_required += required;
    pthread_mutex_unlock(&g_lock);
}

void np_health_hooks(int installed, int total) {
    pthread_mutex_lock(&g_lock);
    g_health.hooks_installed += installed;
    g_health.hooks_total += total;
    pthread_mutex_unlock(&g_lock);
}

void np_health_sigdb(uint64_t build) {
    pthread_mutex_lock(&g_lock);
    g_health.sigdb_build = build;
    pthread_mutex_unlock(&g_lock);
}

void np_health_layout(int known) {
    pthread_mutex_lock(&g_lock);
    g_health.layout_known = known != 0;
    pthread_mutex_unlock(&g_lock);
}

void np_health_flush(void) {
    pthread_mutex_lock(&g_lock);
    health_write_locked();
    pthread_mutex_unlock(&g_lock);
}

void np_health_web(const char *shape, size_t applied, size_t total, int drifted) {
    static char   last_shape[64];
    static size_t last_applied = (size_t)-1, last_total;
    static int    last_drifted;

    pthread_mutex_lock(&g_lock);
    int same = strcmp(last_shape, shape ? shape : "") == 0 && last_applied == applied &&
               last_total == total && last_drifted == drifted;
    char path[PATH_MAX];
    if (same || support_file(path, sizeof path, NP_HEALTH_WEB_FILE) != 0) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    char pkg[PATH_MAX], build[24], channel[64];
    package_dir(pkg, sizeof pkg);
    np_steam_build(pkg, build, sizeof build);
    np_steam_channel(pkg, channel, sizeof channel);

    cJSON *root = cJSON_CreateObject();
    if (root) {
        cJSON_AddNumberToObject(root, "written", (double)time(NULL));
        cJSON_AddNumberToObject(root, "pid", getpid());
        cJSON_AddNumberToObject(root, "patch_build", BRIDGEPLAY_BUILD);
        cJSON_AddNumberToObject(root, "steam_build", (double)strtoull(build, NULL, 10));
        cJSON_AddStringToObject(root, "channel", channel);
        cJSON_AddStringToObject(root, "mode", np_mode_name(np_breaker_mode()));
        cJSON_AddStringToObject(root, "shape", shape ? shape : "");
        cJSON_AddNumberToObject(root, "gates_applied", (double)applied);
        cJSON_AddNumberToObject(root, "gates_total", (double)total);
        cJSON_AddBoolToObject(root, "drifted", drifted != 0);
    }
    // Remembered only once written, so the same report is tried again after a failed write.
    if (write_json(path, root) != 0) {
        NP_WARN("breaker: could not write %s", path);
    } else {
        set_str(last_shape, sizeof last_shape, shape);
        last_applied = applied;
        last_total = total;
        last_drifted = drifted;
    }
    pthread_mutex_unlock(&g_lock);
}
