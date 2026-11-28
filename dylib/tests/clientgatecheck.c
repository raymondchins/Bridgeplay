// The steamclient install gate (core/clientgate.c): Steam's first lookup into the client must
// not return before the hooks are in, whichever thread installs them.
#include "../core/clientgate.c"

#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>

static int g_wrong;

static void wrong(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("WRONG: ", stdout);
    vprintf(fmt, ap);
    fputc('\n', stdout);
    va_end(ap);
    g_wrong = 1;
}

static void reset(void) {
    atomic_store(&g_state, NP_GATE_IDLE);
}

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static _Atomic int g_runs;
static _Atomic int g_hooks_in;
static _Atomic int g_started;

static void slow_install(const struct mach_header_64 *mh, intptr_t slide) {
    (void)mh; (void)slide;
    atomic_fetch_add(&g_runs, 1);
    atomic_store(&g_started, 1);
    usleep(200 * 1000);
    atomic_store(&g_hooks_in, 1);
}

static void *loader_thread(void *unused) {
    (void)unused;
    np_gate_run(NULL, 0, slow_install, 60000);
    return NULL;
}

// What Steam's thread sees: after the lookup returns, the hooks are in.
static void lookup_waits_for_loader_thread(void) {
    reset();
    atomic_store(&g_runs, 0);
    atomic_store(&g_hooks_in, 0);
    atomic_store(&g_started, 0);
    pthread_t t;
    pthread_create(&t, NULL, loader_thread, NULL);
    while (!atomic_load(&g_started)) usleep(1000);
    int ran = np_gate_run(NULL, 0, slow_install, 5000);
    if (ran) wrong("the lookup ran the install the loader thread had claimed");
    if (!atomic_load(&g_hooks_in))
        wrong("the lookup returned before the loader thread's install finished");
    pthread_join(t, NULL);
    if (atomic_load(&g_runs) != 1) wrong("install ran %d times, not once", atomic_load(&g_runs));
}

static void lookup_installs_first(void) {
    reset();
    atomic_store(&g_runs, 0);
    atomic_store(&g_hooks_in, 0);
    int ran = np_gate_run(NULL, 0, slow_install, 5000);
    if (!ran || !atomic_load(&g_hooks_in)) wrong("the first lookup did not install the hooks");
    if (np_gate_state() != NP_GATE_DONE) wrong("the gate is not done after the install");
    // The loader thread arrives later and must not install again.
    if (np_gate_run(NULL, 0, slow_install, 60000)) wrong("a second caller ran the install");
    if (atomic_load(&g_runs) != 1) wrong("install ran %d times, not once", atomic_load(&g_runs));
}

static int g_inner;

static void reentrant_install(const struct mach_header_64 *mh, intptr_t slide) {
    // A library the install calls looks a symbol up on the same thread.
    long long t0 = now_ms();
    g_inner = np_gate_run(mh, slide, reentrant_install, 5000);
    if (now_ms() - t0 > 100) wrong("a lookup from inside the install waited on itself");
}

static void reentry_does_not_wait(void) {
    reset();
    g_inner = -1;
    if (!np_gate_run(NULL, 0, reentrant_install, 5000)) wrong("the outer call did not install");
    if (g_inner != 0) wrong("the inner call ran the install again");
}

static void stuck_install(const struct mach_header_64 *mh, intptr_t slide) {
    (void)mh; (void)slide;
    atomic_store(&g_started, 1);
    while (atomic_load(&g_started) != 2) usleep(1000);
}

static void *stuck_thread(void *unused) {
    (void)unused;
    np_gate_run(NULL, 0, stuck_install, 0);
    return NULL;
}

// An install that never finishes delays a lookup by the bound, never hangs Steam.
static void wait_is_bounded(void) {
    reset();
    atomic_store(&g_started, 0);
    pthread_t t;
    pthread_create(&t, NULL, stuck_thread, NULL);
    while (!atomic_load(&g_started)) usleep(1000);
    long long t0 = now_ms();
    np_gate_run(NULL, 0, slow_install, 150);
    long long took = now_ms() - t0;
    if (took < 100 || took > 2000) wrong("a 150 ms bound waited %lld ms", took);
    atomic_store(&g_started, 2);
    pthread_join(t, NULL);
}

int main(void) {
    lookup_waits_for_loader_thread();
    lookup_installs_first();
    reentry_does_not_wait();
    wait_is_bounded();
    if (g_wrong) return 1;
    puts("clientgatecheck: ok");
    return 0;
}
