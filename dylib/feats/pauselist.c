// The signed pause list. See pauselist.h.
#include "pauselist.h"
#include "pauselist_key.h"
#include "breaker.h"
#include "../util/file.h"
#include "../util/log.h"
#include "cJSON.h"
#include "ed25519/ed25519.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

// Tests point these at a scratch key, a stub curl and a fake address.
static const char *g_pl_key = NP_PAUSE_LIST_PUBLIC_KEY;
static const char *g_pl_curl = "/usr/bin/curl";
static const char *g_pl_url = NP_PAUSE_LIST_URL;

#define NP_PL_MAX_NUMBER 9007199254740991.0  // 2^53 - 1, exact in a JSON double

const char *np_pl_status_name(np_pl_status_t status) {
    switch (status) {
        case NP_PL_IGNORED: return "ignored";
        case NP_PL_NONE:    return "none";
        case NP_PL_OK:      return "ok";
        case NP_PL_EXPIRED: return "expired";
        case NP_PL_INVALID: return "invalid";
        default:            return "unkeyed";
    }
}

static int b64_value(unsigned char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

// Standard base64 with its padding; the decoded length, or -1.
int np_pl_base64(const char *in, size_t len, uint8_t *out, size_t cap) {
    if (!in || len == 0 || len % 4 != 0)
        return -1;
    size_t pad = (in[len - 1] == '=') + (in[len - 1] == '=' && in[len - 2] == '=');
    size_t n = len / 4 * 3 - pad;
    if (n > cap)
        return -1;
    size_t o = 0;
    for (size_t i = 0; i < len; i += 4) {
        uint32_t w = 0;
        for (size_t k = 0; k < 4; k++) {
            int v = i + 4 == len && k >= 4 - pad ? 0 : b64_value((unsigned char)in[i + k]);
            if (v < 0)
                return -1;
            w = w << 6 | (uint32_t)v;
        }
        uint8_t b[3] = { (uint8_t)(w >> 16), (uint8_t)(w >> 8), (uint8_t)w };
        for (int k = 0; k < 3 && o < n; k++)
            out[o++] = b[k];
    }
    return (int)n;
}

static int blank(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

// "<base64 signature> <length>", the .sig format the installer release uses.
int np_pl_parse_sig(const char *text, size_t len, uint8_t sig[64], size_t *length) {
    const char *p = text, *end = text + len;
    while (p < end && blank(*p)) p++;
    const char *b = p;
    while (p < end && !blank(*p)) p++;
    const char *b_end = p;
    while (p < end && blank(*p)) p++;
    const char *d = p;
    while (p < end && !blank(*p)) p++;
    const char *d_end = p;
    while (p < end && blank(*p)) p++;
    if (!text || p != end || b == b_end || d == d_end || d_end - d > 6)
        return -1;
    size_t n = 0;
    for (const char *q = d; q < d_end; q++) {
        if (*q < '0' || *q > '9')
            return -1;
        n = n * 10 + (size_t)(*q - '0');
    }
    if (n == 0 || n > NP_PL_MAX_BYTES || np_pl_base64(b, (size_t)(b_end - b), sig, 64) != 64)
        return -1;
    *length = n;
    return 0;
}

static int whole(const cJSON *v, double max, unsigned long long *out) {
    if (!cJSON_IsNumber(v))
        return 0;
    double d = v->valuedouble;
    if (!(d >= 0) || d > max || d != floor(d))
        return 0;
    *out = (unsigned long long)d;
    return 1;
}

// Shown to the player: printable, no control characters.
static int copy_text(const cJSON *v, char *dst, size_t cap) {
    if (!cJSON_IsString(v) || strlen(v->valuestring) >= cap)
        return 0;
    for (const unsigned char *p = (const unsigned char *)v->valuestring; *p; p++)
        if (*p < 0x20 || *p == 0x7f)
            return 0;
    snprintf(dst, cap, "%s", v->valuestring);
    return 1;
}

static int copy_word(const cJSON *v, char *dst, size_t cap, const char *extra) {
    if (!cJSON_IsString(v) || !v->valuestring[0] || strlen(v->valuestring) >= cap)
        return 0;
    for (const char *p = v->valuestring; *p; p++) {
        char c = *p;
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
              strchr(extra, c)))
            return 0;
    }
    snprintf(dst, cap, "%s", v->valuestring);
    return 1;
}

static int copy_url(const cJSON *v, char *dst, size_t cap) {
    if (!cJSON_IsString(v) || strncmp(v->valuestring, "https://", 8) != 0 ||
        strlen(v->valuestring) >= cap)
        return 0;
    for (const unsigned char *p = (const unsigned char *)v->valuestring; *p; p++)
        if (*p <= 0x20 || *p >= 0x7f || strchr("\"'<>\\`", *p))
            return 0;
    snprintf(dst, cap, "%s", v->valuestring);
    return 1;
}

enum {
    SEEN_EXACT = 1, SEEN_MIN = 2, SEEN_MAX = 4, SEEN_CHANNEL = 8, SEEN_PATCH = 16,
    SEEN_NOTE = 32, SEEN_FIXED = 64, SEEN_URL = 128,
};

// An entry with a key this build doesn't know, a wrong type or a repeated key is dropped:
// it never matches, so a newer list can't pause more than it meant to on an older build.
static int parse_entry(const cJSON *e, np_pl_entry_t *out) {
    memset(out, 0, sizeof *out);
    if (!cJSON_IsObject(e))
        return 0;
    unsigned seen = 0;
    for (const cJSON *f = e->child; f; f = f->next) {
        const char *k = f->string;
        unsigned long long n = 0;
        unsigned bit;
        int ok;
        if (!k) return 0;
        if (strcmp(k, "steam_build") == 0) {
            bit = SEEN_EXACT;
            ok = whole(f, NP_PL_MAX_NUMBER, &n) && n > 0;
            out->has_min = out->has_max = 1;
            out->steam_min = out->steam_max = n;
        } else if (strcmp(k, "steam_build_min") == 0) {
            bit = SEEN_MIN;
            ok = whole(f, NP_PL_MAX_NUMBER, &n) && n > 0;
            out->has_min = 1;
            out->steam_min = n;
        } else if (strcmp(k, "steam_build_max") == 0) {
            bit = SEEN_MAX;
            ok = whole(f, NP_PL_MAX_NUMBER, &n) && n > 0;
            out->has_max = 1;
            out->steam_max = n;
        } else if (strcmp(k, "channel") == 0) {
            bit = SEEN_CHANNEL;
            ok = copy_word(f, out->channel, sizeof out->channel, "_-.");
        } else if (strcmp(k, "patch_build_max") == 0) {
            bit = SEEN_PATCH;
            ok = whole(f, INT_MAX, &n);
            out->has_patch_max = 1;
            out->patch_max = (int)n;
        } else if (strcmp(k, "note") == 0) {
            bit = SEEN_NOTE;
            ok = copy_text(f, out->note, sizeof out->note);
        } else if (strcmp(k, "fixed_in") == 0) {
            bit = SEEN_FIXED;
            ok = copy_word(f, out->fixed_in, sizeof out->fixed_in, ".-+");
        } else if (strcmp(k, "url") == 0) {
            bit = SEEN_URL;
            ok = copy_url(f, out->url, sizeof out->url);
        } else {
            return 0;
        }
        if (!ok || (seen & bit))
            return 0;
        seen |= bit;
    }
    if ((seen & SEEN_EXACT) && (seen & (SEEN_MIN | SEEN_MAX)))
        return 0;
    if (!out->has_min && !out->has_max && !out->channel[0])
        return 0;
    return !(out->has_min && out->has_max && out->steam_min > out->steam_max);
}

int np_pl_parse(const char *json, size_t len, np_pl_list_t *out) {
    memset(out, 0, sizeof *out);
    cJSON *root = cJSON_ParseWithLength(json, len);
    const cJSON *entries = cJSON_GetObjectItemCaseSensitive(root, "entries");
    unsigned long long version = 0, serial = 0, issued = 0, expires = 0;
    int ok = cJSON_IsObject(root) &&
             whole(cJSON_GetObjectItemCaseSensitive(root, "version"), 1e6, &version) && version == 1 &&
             whole(cJSON_GetObjectItemCaseSensitive(root, "serial"), NP_PL_MAX_NUMBER, &serial) &&
             serial > 0 &&
             whole(cJSON_GetObjectItemCaseSensitive(root, "issued"), NP_PL_MAX_NUMBER, &issued) &&
             whole(cJSON_GetObjectItemCaseSensitive(root, "expires"), NP_PL_MAX_NUMBER, &expires) &&
             cJSON_IsArray(entries);
    if (ok) {
        out->serial = serial;
        out->issued = (long long)issued;
        out->expires = (long long)expires;
        int dropped = 0;
        for (const cJSON *e = entries->child; e; e = e->next) {
            if (out->count < NP_PL_MAX_ENTRIES && parse_entry(e, &out->entries[out->count]))
                out->count++;
            else
                dropped++;
        }
        if (dropped)
            NP_WARN("pause list: %d entries this build can't read, left out", dropped);
    }
    cJSON_Delete(root);
    if (!ok)
        memset(out, 0, sizeof *out);
    return ok ? 0 : -1;
}

np_pl_status_t np_pl_check(const uint8_t *json, size_t len, const char *sig, size_t sig_len,
                           const uint8_t key[32], long long now, np_pl_list_t *out) {
    memset(out, 0, sizeof *out);
    uint8_t s[64];
    size_t length = 0;
    if (!json || !sig || len == 0 || len > NP_PL_MAX_BYTES ||
        np_pl_parse_sig(sig, sig_len, s, &length) != 0 || length != len ||
        !ed25519_verify(s, json, len, key) || np_pl_parse((const char *)json, len, out) != 0)
        return NP_PL_INVALID;
    if (out->expires < out->issued || out->expires - out->issued > NP_PL_MAX_LIFETIME) {
        memset(out, 0, sizeof *out);
        return NP_PL_INVALID;
    }
    return now > out->expires ? NP_PL_EXPIRED : NP_PL_OK;
}

// A Steam build that couldn't be read (0) matches no entry that names builds.
const np_pl_entry_t *np_pl_match(const np_pl_list_t *list, unsigned long long steam_build,
                                 const char *channel, int patch_build) {
    for (int i = 0; list && i < list->count; i++) {
        const np_pl_entry_t *e = &list->entries[i];
        if ((e->has_min || e->has_max) && steam_build == 0) continue;
        if (e->has_min && steam_build < e->steam_min) continue;
        if (e->has_max && steam_build > e->steam_max) continue;
        if (e->channel[0] && (!channel || strcmp(channel, e->channel) != 0)) continue;
        if (e->has_patch_max && patch_build > e->patch_max) continue;
        return e;
    }
    return NULL;
}

// ---- Runtime ------------------------------------------------------------------------

typedef struct {
    long long checked;
    char      notified[96];
} pl_state_t;

static int join(char *buf, size_t cap, const char *dir, const char *name) {
    int n = snprintf(buf, cap, "%s/%s", dir, name);
    return n < 0 || (size_t)n >= cap ? -1 : 0;
}

static uint8_t *read_in(const char *dir, const char *name, size_t *len) {
    char path[PATH_MAX];
    *len = 0;
    return join(path, sizeof path, dir, name) == 0 ? np_read_whole_file(path, len) : NULL;
}

static void drop_in(const char *dir, const char *name) {
    char path[PATH_MAX];
    if (join(path, sizeof path, dir, name) == 0)
        unlink(path);
}

static void state_read(const char *dir, pl_state_t *s) {
    memset(s, 0, sizeof *s);
    size_t len = 0;
    uint8_t *raw = read_in(dir, NP_PL_STATE_FILE, &len);
    if (!raw)
        return;
    cJSON *root = cJSON_ParseWithLength((const char *)raw, len);
    free(raw);
    const cJSON *checked = cJSON_GetObjectItemCaseSensitive(root, "checked");
    const cJSON *notified = cJSON_GetObjectItemCaseSensitive(root, "notified");
    if (cJSON_IsNumber(checked))
        s->checked = (long long)checked->valuedouble;
    if (cJSON_IsString(notified))
        snprintf(s->notified, sizeof s->notified, "%s", notified->valuestring);
    cJSON_Delete(root);
}

static void state_write(const char *dir, const pl_state_t *s) {
    char path[PATH_MAX];
    cJSON *root = cJSON_CreateObject();
    char *text = NULL;
    if (root) {
        cJSON_AddNumberToObject(root, "checked", (double)s->checked);
        cJSON_AddStringToObject(root, "notified", s->notified);
        text = cJSON_PrintUnformatted(root);
        cJSON_Delete(root);
    }
    if (!text || join(path, sizeof path, dir, NP_PL_STATE_FILE) != 0 ||
        np_write_atomic(path, text, strlen(text)) != 0)
        NP_WARN("pause list: could not write %s", NP_PL_STATE_FILE);
    free(text);
}

// pause-list.cache: the signature line, a newline, then the list's bytes as published.
static np_pl_status_t check_cache(const char *dir, const uint8_t key[32], long long now,
                                  np_pl_list_t *list) {
    memset(list, 0, sizeof *list);
    size_t len = 0;
    uint8_t *raw = read_in(dir, NP_PL_CACHE_FILE, &len);
    if (!raw)
        return NP_PL_NONE;
    uint8_t *nl = memchr(raw, '\n', len);
    np_pl_status_t status = nl ? np_pl_check(nl + 1, len - (size_t)(nl + 1 - raw), (char *)raw,
                                             (size_t)(nl - raw), key, now, list)
                               : NP_PL_INVALID;
    free(raw);
    return status;
}

// Takes the pair the last fetch left when it is signed and newer than the cache; a list with
// a serial at or below the cached one is a rollback and is dropped. The fetch moves the
// signature in first, so a lone signature is a fetch still landing and stays.
static int promote(const char *dir, const uint8_t key[32], long long now,
                   unsigned long long cached) {
    size_t json_len = 0, sig_len = 0;
    uint8_t *json = read_in(dir, NP_PL_NEW_FILE, &json_len);
    if (!json)
        return 0;
    uint8_t *sig = read_in(dir, NP_PL_NEW_SIG, &sig_len);
    np_pl_list_t *fresh = calloc(1, sizeof *fresh);
    np_pl_status_t status = sig && fresh ? np_pl_check(json, json_len, (char *)sig, sig_len,
                                                       key, now, fresh)
                                         : NP_PL_INVALID;
    int taken = 0;
    if ((status == NP_PL_OK || status == NP_PL_EXPIRED) && fresh->serial > cached) {
        while (sig_len && blank((char)sig[sig_len - 1]))
            sig_len--;
        size_t total = sig_len + 1 + json_len;
        char *joined = malloc(total);
        char path[PATH_MAX];
        if (joined && join(path, sizeof path, dir, NP_PL_CACHE_FILE) == 0) {
            memcpy(joined, sig, sig_len);
            joined[sig_len] = '\n';
            memcpy(joined + sig_len + 1, json, json_len);
            taken = np_write_atomic(path, joined, total) == 0;
        }
        free(joined);
        if (taken)
            NP_LOG("pause list: took serial %llu (was %llu)", fresh->serial, cached);
        else
            NP_WARN("pause list: could not write %s", NP_PL_CACHE_FILE);
    } else if (status == NP_PL_OK || status == NP_PL_EXPIRED) {
        NP_LOG("pause list: fetched serial %llu is not newer than %llu, kept the cache",
               fresh->serial, cached);
    } else {
        NP_WARN("pause list: the fetched list failed its checks, kept the cache");
    }
    free(fresh);
    free(json);
    free(sig);
    drop_in(dir, NP_PL_NEW_FILE);
    drop_in(dir, NP_PL_NEW_SIG);
    return taken;
}

// The fetch outlives this process (the stub execs the client right after) and Steam never
// waits on it: sh backgrounds the work and exits at once. curl gets no ~/.curlrc (-q), HTTPS
// only, 3 s to connect and 8 s per file.
static const char g_fetch_script[] =
    "c=$1 d=$2 u=$3 t=\"$2/pause-list.fetch.$$\"\n"
    "get() { \"$c\" -q -fsSL --proto =https --proto-redir =https --tlsv1.2 --connect-timeout 3"
    " --max-time 8 --max-filesize 65536 -A 'Bridgeplay pause list' -o \"$2\" \"$1\"; }\n"
    "(\n"
    "  if get \"$u\" \"$t.json\" && get \"$u.sig\" \"$t.sig\"; then\n"
    "    mv -f \"$t.sig\" \"$d/" NP_PL_NEW_SIG "\" && mv -f \"$t.json\" \"$d/" NP_PL_NEW_FILE "\"\n"
    "  fi\n"
    "  rm -f \"$t.json\" \"$t.sig\"\n"
    ") </dev/null >/dev/null 2>&1 &\n";

// A fetch killed halfway (logout, shutdown) leaves its temp files behind.
static void drop_stale_fetches(const char *dir, long long now) {
    DIR *dh = opendir(dir);
    struct dirent *e;
    while (dh && (e = readdir(dh)) != NULL) {
        char path[PATH_MAX];
        struct stat st;
        if (strncmp(e->d_name, "pause-list.fetch.", 17) == 0 &&
            join(path, sizeof path, dir, e->d_name) == 0 && lstat(path, &st) == 0 &&
            S_ISREG(st.st_mode) && now - (long long)st.st_mtime > 60)
            unlink(path);
    }
    if (dh)
        closedir(dh);
}

static int spawn_fetch(const char *dir) {
    static const char *const keep[] = {
        "HOME=", "TMPDIR=", "http_proxy=", "https_proxy=", "HTTPS_PROXY=",
        "all_proxy=", "ALL_PROXY=", "no_proxy=", "NO_PROXY=",
    };
    char *envp[sizeof keep / sizeof keep[0] + 2];
    size_t n = 0;
    envp[n++] = "PATH=/usr/bin:/bin";
    for (size_t k = 0; k < sizeof keep / sizeof keep[0]; k++)
        for (char **e = environ; e && *e; e++)
            if (strncmp(*e, keep[k], strlen(keep[k])) == 0) {
                envp[n++] = *e;
                break;
            }
    envp[n] = NULL;

    char *argv[] = { "/bin/sh", "-c", (char *)g_fetch_script, "sh", (char *)g_pl_curl,
                     (char *)dir, (char *)g_pl_url, NULL };
    posix_spawn_file_actions_t fa;
    posix_spawnattr_t attr;
    if (posix_spawn_file_actions_init(&fa) != 0)
        return -1;
    if (posix_spawnattr_init(&attr) != 0) {
        posix_spawn_file_actions_destroy(&fa);
        return -1;
    }
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    // Only the three above reach the child, none of Steam's descriptors.
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);
    pid_t pid;
    int rc = posix_spawn(&pid, "/bin/sh", &fa, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) {
        NP_WARN("pause list: could not start the fetch (%d)", rc);
        return -1;
    }
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
    return 0;
}

void np_pause_list_start(const char *dir, unsigned long long steam_build, const char *channel,
                         int patch_build, int off, long long now, np_pl_result_t *out) {
    memset(out, 0, sizeof *out);
    const char *flag = getenv("BRIDGEPLAY_PAUSE_LIST");
    if (flag && strcmp(flag, "0") == 0) {
        out->status = NP_PL_IGNORED;
        NP_LOG("pause list: ignored (BRIDGEPLAY_PAUSE_LIST=0)");
        return;
    }
    uint8_t key[32];
    if (!g_pl_key || np_pl_base64(g_pl_key, strlen(g_pl_key), key, sizeof key) != 32) {
        out->status = NP_PL_UNKEYED;
        return;
    }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    np_pl_list_t *list = calloc(1, sizeof *list);
    if (!list) {
        out->status = NP_PL_NONE;
        return;
    }
    np_pl_status_t status = check_cache(dir, key, now, list);
    unsigned long long cached =
        status == NP_PL_OK || status == NP_PL_EXPIRED ? list->serial : 0;
    if (promote(dir, key, now, cached))
        status = check_cache(dir, key, now, list);

    out->status = status;
    if (status == NP_PL_OK || status == NP_PL_EXPIRED) {
        out->serial = list->serial;
        out->expires = list->expires;
    }
    const np_pl_entry_t *hit =
        status == NP_PL_OK ? np_pl_match(list, steam_build, channel, patch_build) : NULL;
    if (hit) {
        out->matched = 1;
        out->entry = *hit;
    }
    free(list);

    if (!off) {
        pl_state_t state;
        state_read(dir, &state);
        if (state.checked <= 0 || now < state.checked || now - state.checked >= NP_PL_FETCH_EVERY) {
            state.checked = now;
            state_write(dir, &state);
            drop_stale_fetches(dir, now);
            out->fetched = spawn_fetch(dir) == 0;
        }
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ms = (double)(t1.tv_sec - t0.tv_sec) * 1e3 + (double)(t1.tv_nsec - t0.tv_nsec) / 1e6;
    NP_LOG("pause list: %s, serial %llu%s%s, %.1f ms", np_pl_status_name(status), out->serial,
           out->matched ? ", this Steam build is on it" : "",
           out->fetched ? ", fetching for the next start" : "", ms);
}

int np_pause_list_announce(const char *dir, const char *key, const np_pl_entry_t *entry) {
    pl_state_t state;
    state_read(dir, &state);
    char tag[sizeof state.notified];
    snprintf(tag, sizeof tag, "%s|%s", key, entry->fixed_in);
    if (strcmp(state.notified, tag) == 0)
        return 0;
    snprintf(state.notified, sizeof state.notified, "%s", tag);
    state_write(dir, &state);
    return 1;
}
