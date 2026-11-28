// Feeds a compat-gate-patched SteamUI chunk to the loopback reader. The bytes are
// rewritten in memory and handed back as an anonymous fd, so the on-disk file is
// not modified, to keep the Steam bootstrap happy.

#include "../feats/webpatch.h"
#include "../feats/breaker.h"
#include "../feats/compat.h"
#include "../feats/compatsvc.h"
#include "../util/file.h"
#include "../util/log.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <stdio.h>
#include <errno.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(uintptr_t)&_replacement, \
        (const void *)(uintptr_t)&_replacee \
    }


_Pragma("clang diagnostic push")
_Pragma("clang diagnostic ignored \"-Wdeprecated-declarations\"")
static int sys_open(const char *path, int oflag, mode_t mode) {
    return (int)syscall(SYS_open, path, oflag, mode);
}
static int sys_openat(int dirfd, const char *path, int oflag, mode_t mode) {
    return (int)syscall(SYS_openat, dirfd, path, oflag, mode);
}
_Pragma("clang diagnostic pop")

#define WEBPATCH_MAX_CHUNK (32 * 1024 * 1024)

static char *drain_fd(int fd, size_t *out_len) {
    struct stat st;
    if (fstat(fd, &st) != 0)
        return NULL;
    if (st.st_size <= 0 || st.st_size > WEBPATCH_MAX_CHUNK)
        return NULL;

    size_t total = (size_t)st.st_size;
    char *buf = malloc(total);
    if (!buf)
        return NULL;

    for (size_t done = 0; done < total; ) {
        ssize_t n = read(fd, buf + done, total - done);
        if (n <= 0) {
            free(buf);
            return NULL;
        }
        done += (size_t)n;
    }
    *out_len = total;
    return buf;
}

static int spill_to_temp(const char *bytes, size_t len) {
    const char *home = np_home_dir();
    if (!home)
        return -1;

    char dir[1024];
    np_support_path(dir, sizeof(dir), home, NULL);
    mkdir(dir, 0755);

    char tmpl[1100];
    snprintf(tmpl, sizeof(tmpl), "%s/webpatch.XXXXXX", dir);
    int fd = mkstemp(tmpl);
    if (fd < 0)
        return -1;
    unlink(tmpl);

    for (size_t done = 0; done < len; ) {
        ssize_t n = write(fd, bytes + done, len - done);
        if (n <= 0) {
            close(fd);
            return -1;
        }
        done += (size_t)n;
    }

    if (lseek(fd, 0, SEEK_SET) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

// Read `path`, apply the compat gates, and return a rewound anonymous fd holding
// the patched bytes. -1 falls the caller through to the real file, which happens
// when the read fails or the gates are absent/missing. Safety.
static int open_patched(const char *path) {
    np_log_attach();

    int in = sys_open(path, O_RDONLY, 0);
    if (in < 0)
        return -1;

    size_t raw_len = 0;
    char *raw = drain_fd(in, &raw_len);
    if (!raw) {
        struct stat st;
        if (fstat(in, &st) == 0 && st.st_size > WEBPATCH_MAX_CHUNK)
            NP_ERR("webpatch: %s holds %lld bytes, past the %d byte ceiling, so the "
                   "compat UI stays unpatched", path, (long long)st.st_size,
                   WEBPATCH_MAX_CHUNK);
        close(in);
        return -1;
    }
    close(in);

    np_webpatch_set_fallback_tool(np_compat_fallback_tool_name());
    const char *fex[NP_WEBPATCH_FEX_TOOLS_MAX];
    np_webpatch_set_fex_tools(fex, np_compat_fex_tools(fex, NP_WEBPATCH_FEX_TOOLS_MAX));
    size_t patched_len = 0;
    const char *shape = NULL;
    char *patched = np_webpatch_transform((const uint8_t *)raw, raw_len, &patched_len,
                                          &shape);
    free(raw);
    size_t live = 0, total = 0;
    int drifted = 0;
    if (shape)
        np_webpatch_last_gates(&live, &total, &drifted);
    if (!patched) {
        if (shape)
            np_health_web(shape, live, total, drifted);
        return -1;
    }

    // Only this page pays for an unregistered service, and only here is it known that the
    // page arrived. UNTRIED is not a miss: the chunk can precede the first route lookup.
    if (shape && (strcmp(shape, NP_SHAPE_SELECTTOOL) == 0 ||
                  strcmp(shape, NP_SHAPE_SELECTTOOL_VITE) == 0) &&
        np_compatsvc_routes() == NP_COMPATSVC_ABSENT)
        NP_ERR("webpatch: the compat page sources its tools from CompatManager and this "
               "client cannot answer, so the list will be empty");

    int fd = spill_to_temp(patched, patched_len);
    free(patched);
    // The gates count as applied only once the patched bytes are what the client reads.
    if (shape)
        np_health_web(shape, fd < 0 ? 0 : live, total, drifted);
    if (fd < 0) {
        NP_ERR("webpatch: patched %s but staging the bytes failed, so the client reads "
               "the chunk Valve shipped", path);
        return -1;
    }

    NP_LOG_FIRST("webpatch: served patched compat chunk (%s) to %s pid %d",
                 path, getprogname(), getpid());
    return fd;
}

static const int WRITE_INTENT = O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND;

static int try_serve(const char *path, int oflag) {
    if (oflag & WRITE_INTENT)
        return -1;
    if (!np_webpatch_should_patch(path))
        return -1;
    if (np_breaker_mode() != NP_MODE_ACTIVE)
        return -1;
    return open_patched(path);
}

static mode_t creat_mode(int oflag, va_list ap) {
    if (oflag & O_CREAT)
        return (mode_t)va_arg(ap, int);
    return 0;
}

static int np_open(const char *path, int oflag, ...) {
    va_list ap; va_start(ap, oflag);
    mode_t mode = creat_mode(oflag, ap);
    va_end(ap);

    int served = try_serve(path, oflag);
    if (served >= 0)
        return served;
    return sys_open(path, oflag, mode);
}

static int np_openat(int dirfd, const char *path, int oflag, ...) {
    va_list ap; va_start(ap, oflag);
    mode_t mode = creat_mode(oflag, ap);
    va_end(ap);

    if (path && path[0] == '/') {
        int served = try_serve(path, oflag);
        if (served >= 0)
            return served;
    }
    return sys_openat(dirfd, path, oflag, mode);
}

static int mode_string_flags(const char *mode) {
    if (!mode || !mode[0])
        return -1;

    int oflag;
    switch (mode[0]) {
        case 'r': oflag = O_RDONLY; break;
        case 'w': oflag = O_WRONLY | O_CREAT | O_TRUNC; break;
        case 'a': oflag = O_WRONLY | O_CREAT | O_APPEND; break;
        default:  return -1;
    }
    for (const char *p = mode + 1; *p; p++) {
        switch (*p) {
            case '+': oflag = (oflag & ~(O_RDONLY | O_WRONLY)) | O_RDWR; break;
            case 'x': oflag |= O_EXCL;    break;
            case 'e': oflag |= O_CLOEXEC; break;
            default: break;
        }
    }
    return oflag;
}

static FILE *np_fopen(const char *path, const char *mode) {
    int oflag = mode_string_flags(mode);
    if (!path || oflag < 0) {
        errno = EINVAL;
        return NULL;
    }

    int served = try_serve(path, oflag);
    if (served >= 0) {
        FILE *fp = fdopen(served, mode);
        if (fp)
            return fp;
        close(served);
    }

    int fd = sys_open(path, oflag, 0666);
    if (fd < 0)
        return NULL;
    FILE *fp = fdopen(fd, mode);
    if (!fp) {
        int e = errno;
        close(fd);
        errno = e;
    }
    return fp;
}

DYLD_INTERPOSE(np_open, open);
DYLD_INTERPOSE(np_openat, openat);
DYLD_INTERPOSE(np_fopen, fopen);
