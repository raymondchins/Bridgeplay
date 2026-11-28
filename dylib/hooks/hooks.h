// Hook definitions, Dobby installation, and shared hook infrastructure.
#ifndef NOTPROTON_HOOKS_HOOKS_H
#define NOTPROTON_HOOKS_HOOKS_H

#include <stdint.h>
#include <stddef.h>
#include "../resolver/resolver.h"

typedef enum {
    NP_PATCH_REPLACE = 0,   // swap in a replacement, keep the original callable
    NP_PATCH_PREHOOK = 1,   // run before the target, may rewrite registers
} np_patch_mode_t;

// Register state a prehook is handed, in Dobby's layout.
typedef struct { uint64_t _d0, sp, _d1; struct { uint64_t x[29]; } general; } np_arm64_ctx_t;

typedef struct {
    const char      *label;
    const char      *signature;
    // Target for a hook that lands somewhere a signature cannot name, such as an
    // instruction inside a function.
    uintptr_t        address;
    void            *entry;
    void           **trampoline;
    np_patch_mode_t  mode;
} np_patch_entry_t;

int               np_hooks_compat_count(void);
np_patch_entry_t *np_hooks_compat_defs(void);

void np_hooks_compat_publish_originals(void);
// Points the compat manager's switch getter (vtable slot 0) at one that turns the layer on
// first. Returns 1 when it did. See np_compat_vtable_slot0.
int np_hooks_compat_enabled_slot(const struct mach_header_64 *mh, intptr_t slide,
                                 uintptr_t bis_enabled);

void np_hooks_compat_set_helpers(uintptr_t yld_register_tool,
                                 uintptr_t get_valid_platforms,
                                 uintptr_t find_tool_for_target_app,
                                 uintptr_t set_compat_tool_mapping,
                                 uintptr_t find_mapping,
                                 uintptr_t get_wildcard_mapping);

int               np_hooks_webui_count(void);
np_patch_entry_t *np_hooks_webui_defs(void);

void np_hooks_webui_bind(const struct mach_header_64 *mh, intptr_t slide,
                         uintptr_t register_fn, uintptr_t dispatch_fn);

int               np_hooks_launch_count(void);
np_patch_entry_t *np_hooks_launch_defs(void);

int               np_hooks_shortcut_count(void);
np_patch_entry_t *np_hooks_shortcut_defs(void);

int               np_hooks_icon_count(void);
np_patch_entry_t *np_hooks_icon_defs(void);

int               np_hooks_shortcut_bundle_count(void);
np_patch_entry_t *np_hooks_shortcut_bundle_defs(void);

void np_hooks_shortcut_bundle_bind(const struct mach_header_64 *steamui);

int np_hooks_install_all(const struct mach_header_64 *mh, intptr_t slide,
                         np_resolve_result_t *resolved, int *total_out);

int np_hooks_install_steamui(const struct mach_header_64 *mh, intptr_t slide,
                             np_resolve_result_t *resolved, int *total_out);

// True when `label` is one entry of the comma-separated value of env var `var`.
// NOTPROTON_DISABLE uses this to skip named hooks.
int np_hooks_env_lists_label(const char *var, const char *label);

void np_hooks_launch_install(const struct mach_header_64 *mh, intptr_t slide);

// Resolved from libc rather than the signature database, and installed before the client
// can spawn anything, so this one does not wait for steamclient the way the rest do.
void np_hooks_spawn_install(void);

void np_hooks_activate_install(void);

#endif // NOTPROTON_HOOKS_HOOKS_H
