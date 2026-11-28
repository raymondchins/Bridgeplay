// Runs the steamclient install exactly once, from whichever comes first: the loader thread
// that found the image, or Steam's first symbol lookup after the image is mapped. The lookup
// waits for the install, so no code in steamclient.dylib runs before the hooks are in.
//
// The loader thread alone polls for the image every 100 ms and races Steam's start, so a hook
// that has to be in before Steam first configures the installed apps (the compat switch
// getter, see np_compat_vtable_slot0) could land after that pass.
#ifndef NOTPROTON_CORE_CLIENTGATE_H
#define NOTPROTON_CORE_CLIENTGATE_H

#include <stdint.h>

struct mach_header_64;

typedef void (*np_gate_install_fn)(const struct mach_header_64 *mh, intptr_t slide);

enum { NP_GATE_IDLE = 0, NP_GATE_INSTALLING, NP_GATE_DONE };

// Runs `install` unless it ran or is running. A caller that finds it running waits up to
// `wait_ms` for it to finish. A call made from inside `install` on the same thread returns
// at once. Returns 1 when this call ran the install.
int np_gate_run(const struct mach_header_64 *mh, intptr_t slide, np_gate_install_fn install,
                int wait_ms);

int np_gate_state(void);

#endif // NOTPROTON_CORE_CLIENTGATE_H
