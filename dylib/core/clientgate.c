#include "clientgate.h"

#include <stdatomic.h>
#include <unistd.h>

static _Atomic int g_state = NP_GATE_IDLE;
static _Thread_local int t_installing;

int np_gate_state(void) {
    return atomic_load(&g_state);
}

int np_gate_run(const struct mach_header_64 *mh, intptr_t slide, np_gate_install_fn install,
                int wait_ms) {
    if (atomic_load(&g_state) == NP_GATE_DONE || t_installing || !install)
        return 0;
    int idle = NP_GATE_IDLE;
    if (atomic_compare_exchange_strong(&g_state, &idle, NP_GATE_INSTALLING)) {
        t_installing = 1;
        install(mh, slide);
        t_installing = 0;
        atomic_store(&g_state, NP_GATE_DONE);
        return 1;
    }
    // Bounded, so a lookup made while the installer waits on something this thread holds
    // only delays Steam.
    for (int waited = 0; waited < wait_ms && atomic_load(&g_state) != NP_GATE_DONE; waited++)
        usleep(1000);
    return 0;
}

void np_gate_wait_done(void) {
    while (atomic_load(&g_state) != NP_GATE_DONE)
        usleep(10 * 1000);
}
