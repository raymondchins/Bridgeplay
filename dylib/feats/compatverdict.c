// Reads compat-verdicts.tsv for the page. Line 1 is
//   bridgeplay-compat-verdicts <TAB> 1 <TAB> <export time, Unix seconds>
// and each line after it
//   appid <TAB> verdict <TAB> n <TAB> p <TAB> i <TAB> b <TAB> since <TAB> anti-cheat
// verdict: o one report, s broken since, p playable, d doesn't run, m mixed, - none.
// since: a Bridgeplay version (0.7.66), s<Steam build>, or -. anti-cheat: ids from the list
// below, comma separated, or -.
#include "compatverdict.h"
#include "../util/file.h"
#include "../util/log.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define FIELDS     8
#define FIELD_MAX  64
#define ANTICHEATS 4

static const char *const g_anticheat_ids[] = {
    "eac", "battleye", "ricochet", "vanguard", "ace", "xigncode3", "nprotect", "javelin",
    "denuvo", "vac", "other",
};

static int all_digits(const char *s, size_t len, size_t max) {
    if (len == 0 || len > max) return 0;
    for (size_t i = 0; i < len; i++)
        if (s[i] < '0' || s[i] > '9') return 0;
    return 1;
}

static int is_anticheat(const char *s, size_t len) {
    for (size_t i = 0; i < sizeof(g_anticheat_ids) / sizeof(g_anticheat_ids[0]); i++)
        if (strlen(g_anticheat_ids[i]) == len && memcmp(g_anticheat_ids[i], s, len) == 0) return 1;
    return 0;
}

// 0.7.66, 3.0.0: digit groups of up to 4, at most 4 of them.
static int is_version(const char *s, size_t len) {
    if (len == 0 || len > 19) return 0;
    size_t groups = 0, run = 0;
    for (size_t i = 0; i < len; i++) {
        if (s[i] == '.') {
            if (run == 0) return 0;
            groups++;
            run = 0;
        } else if (s[i] >= '0' && s[i] <= '9') {
            if (++run > 4) return 0;
        } else {
            return 0;
        }
    }
    return run > 0 && groups < 4;
}

static int is_since(const char *s, size_t len) {
    if (len == 1 && s[0] == '-') return 1;
    if (len >= 2 && s[0] == 's') return all_digits(s + 1, len - 1, 12);
    return is_version(s, len);
}

static int is_anticheat_list(const char *s, size_t len) {
    if (len == 1 && s[0] == '-') return 1;
    size_t start = 0, count = 0;
    for (size_t i = 0; i <= len; i++) {
        if (i < len && s[i] != ',') continue;
        if (i == start || !is_anticheat(s + start, i - start) || ++count > ANTICHEATS) return 0;
        start = i + 1;
    }
    return count > 0;
}

typedef struct { const char *at; size_t len; } field_t;

// Splits one line on tabs into exactly FIELDS fields.
static int split(const char *line, size_t len, field_t *f) {
    size_t n = 0, start = 0;
    for (size_t i = 0; i <= len; i++) {
        if (i < len && line[i] != '\t') continue;
        if (n == FIELDS || i - start > FIELD_MAX) return 0;
        f[n].at = line + start;
        f[n].len = i - start;
        n++;
        start = i + 1;
    }
    return n == FIELDS;
}

static int valid_line(const field_t *f) {
    if (!all_digits(f[0].at, f[0].len, 10) || f[0].at[0] == '0') return 0;
    if (f[0].len == 10 && memcmp(f[0].at, "4294967295", 10) > 0) return 0;
    if (f[1].len != 1 || !strchr("ospdm-", f[1].at[0])) return 0;
    for (int i = 2; i <= 5; i++)
        if (!all_digits(f[i].at, f[i].len, 6)) return 0;
    return is_since(f[6].at, f[6].len) && is_anticheat_list(f[7].at, f[7].len);
}

typedef struct { char *buf; size_t len, cap; int ok; } out_t;

static void put(out_t *o, const char *s, size_t n) {
    if (!o->ok) return;
    if (o->len + n + 1 > o->cap) {
        size_t want = o->cap ? o->cap : 4096;
        while (want < o->len + n + 1) want *= 2;
        char *grown = realloc(o->buf, want);
        if (!grown) { o->ok = 0; return; }
        o->buf = grown;
        o->cap = want;
    }
    memcpy(o->buf + o->len, s, n);
    o->len += n;
    o->buf[o->len] = '\0';
}

static void puts_(out_t *o, const char *s) { put(o, s, strlen(s)); }

char *np_compatverdict_from(const char *text, size_t len) {
    const char *end = text + len, *nl = memchr(text, '\n', len);
    size_t head_len = nl ? (size_t)(nl - text) : len;
    field_t h[3];
    size_t n = 0, start = 0;
    for (size_t i = 0; i <= head_len && n < 3; i++) {
        if (i < head_len && text[i] != '\t') continue;
        h[n].at = text + start;
        h[n].len = i - start;
        n++;
        start = i + 1;
    }
    if (n != 3 || start <= head_len || h[0].len != strlen(NP_VERDICT_HEADER) ||
        memcmp(h[0].at, NP_VERDICT_HEADER, h[0].len) != 0 || h[1].len != 1 || h[1].at[0] != '1' ||
        !all_digits(h[2].at, h[2].len, 12)) {
        NP_WARN("compatverdict: the file has no header this build reads, so no verdicts are shown");
        return NULL;
    }

    out_t o = { NULL, 0, 0, 1 };
    // Steam's chunks end in a source map comment, so this starts a line of its own.
    puts_(&o, "\n;globalThis.MSCXVerdicts={\"u\":");
    put(&o, h[2].at, h[2].len);
    puts_(&o, ",\"g\":\"");
    size_t kept = 0, skipped = 0;
    for (const char *line = nl ? nl + 1 : end; line < end; ) {
        const char *stop = memchr(line, '\n', (size_t)(end - line));
        size_t ll = stop ? (size_t)(stop - line) : (size_t)(end - line);
        if (ll && line[ll - 1] == '\r') ll--;
        field_t f[FIELDS];
        if (ll == 0) {
            // A blank line is not counted as bad.
        } else if (!split(line, ll, f) || !valid_line(f)) {
            skipped++;
        } else {
            if (kept++) put(&o, ";", 1);
            put(&o, f[0].at, f[0].len);
            put(&o, ":", 1);
            for (int i = 1; i < FIELDS; i++) {
                if (i > 1) put(&o, ",", 1);
                if (i >= 6 && f[i].len == 1 && f[i].at[0] == '-') continue;
                if (i == 7) {
                    // Ids are joined with + so the record's commas stay unambiguous.
                    for (size_t c = 0; c < f[i].len; c++) put(&o, f[i].at[c] == ',' ? "+" : f[i].at + c, 1);
                } else {
                    put(&o, f[i].at, f[i].len);
                }
            }
        }
        line = stop ? stop + 1 : end;
    }
    puts_(&o, "\"};");
    if (!o.ok) {
        free(o.buf);
        NP_WARN("compatverdict: no memory for %zu verdicts", kept);
        return NULL;
    }
    if (skipped)
        NP_WARN("compatverdict: skipped %zu line(s) this build does not read", skipped);
    NP_LOG("compatverdict: %zu game(s) handed to the page", kept);
    return o.buf;
}

char *np_compatverdict_javascript(const char *home) {
    if (!home || !*home) return NULL;
    char path[1024];
    np_support_path(path, sizeof(path), home, NP_VERDICT_FILE);
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        if (errno != ENOENT) NP_WARN("compatverdict: cannot open %s (%d)", path, errno);
        return NULL;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0 ||
        (unsigned long long)st.st_size > NP_VERDICT_FILE_MAX) {
        NP_WARN("compatverdict: %s is not a regular file up to %u bytes, so no verdicts are shown",
                path, NP_VERDICT_FILE_MAX);
        close(fd);
        return NULL;
    }
    size_t size = (size_t)st.st_size, got = 0;
    char *text = malloc(size);
    while (text && got < size) {
        ssize_t r = read(fd, text + got, size - got);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        got += (size_t)r;
    }
    close(fd);
    char *js = text && got == size ? np_compatverdict_from(text, size) : NULL;
    free(text);
    return js;
}
