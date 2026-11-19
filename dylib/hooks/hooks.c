// Hook registration and Dobby installation.

#include "hooks.h"
#include "../core/macho.h"
#include "../feats/webui.h"
#include "../feats/compat.h"
#include "../feats/usershortcuts.h"
#include "../util/log.h"
#include <stdlib.h>
#include <string.h>

extern int DobbyHook(void *address, void *replace_call, void **origin_call);
typedef void (*np_prehook_fn)(void *address, void *ctx);
extern int DobbyInstrument(void *address, np_prehook_fn pre_handler);
extern int DobbyCodePatch(void *address, uint8_t *buffer, uint32_t buffer_size);

// The longest trampoline Dobby writes on arm64: LDR, BR and an 8-byte literal.
#define NP_TRAMPOLINE_MAX 16

int np_hooks_env_lists_label(const char *var, const char *label) {
    const char *list = getenv(var);
    if (!list || !list[0] || !label)
        return 0;

    size_t label_len = strlen(label);
    while (*list) {
        const char *comma = strchr(list, ',');
        size_t field_len = comma ? (size_t)(comma - list) : strlen(list);
        if (field_len == label_len && memcmp(list, label, label_len) == 0)
            return 1;
        if (!comma)
            break;
        list = comma + 1;
    }
    return 0;
}

typedef struct {
    const char        *group;
    int              (*count)(void);
    np_patch_entry_t *(*entries)(void);
} np_hook_group_t;

// webpatch reaches the client through a dyld interpose table, not a resolved
// address, so it has no row here.
static const np_hook_group_t np_groups[] = {
    { "compat", np_hooks_compat_count, np_hooks_compat_defs },
    { "webui",  np_hooks_webui_count,  np_hooks_webui_defs  },
    { "launch", np_hooks_launch_count, np_hooks_launch_defs },
};

static const np_hook_group_t np_steamui_groups[] = {
    { "shortcut", np_hooks_shortcut_count,        np_hooks_shortcut_defs        },
    { "icon",     np_hooks_icon_count,            np_hooks_icon_defs            },
    { "bundle",   np_hooks_shortcut_bundle_count, np_hooks_shortcut_bundle_defs },
};

// Installs one entry. Returns 1 when the patch lands, 0 when it is skipped or fails.
static int np_apply_entry(np_resolve_result_t *resolved, const char *group,
                          np_patch_entry_t *e) {
    if (np_hooks_env_lists_label("NOTPROTON_DISABLE", e->label)) {
        NP_WARN("[%s] %s: DISABLED via NOTPROTON_DISABLE", group, e->label);
        return 0;
    }

    uintptr_t addr = e->address ? e->address
                   : e->signature ? np_lookup_address(resolved, e->signature) : 0;
    if (!addr) {
        NP_WARN("[%s] %s: unresolved, cannot install", group, e->label);
        return 0;
    }

    uint8_t before[NP_TRAMPOLINE_MAX];
    memcpy(before, (const void *)addr, sizeof(before));

    int prehook = (e->mode == NP_PATCH_PREHOOK);
    int rc = prehook ? DobbyInstrument((void *)addr, (np_prehook_fn)e->entry)
                     : DobbyHook((void *)addr, e->entry, e->trampoline);
    if (rc == 0) {
        NP_LOG("[%s] %s: %s @ %p", group, e->label,
               prehook ? "instrumented" : "hooked", (void *)addr);
        return 1;
    }

    // Dobby writes the trampoline even when relocating the original failed, then
    // returns an error with no original and no registered entry. Put the bytes back
    // so Steam runs its own code; if that fails the hook degrades instead.
    int patched = memcmp((const void *)addr, before, sizeof(before)) != 0;
    int restored = patched && DobbyCodePatch((void *)addr, before, sizeof(before)) == 0
        && memcmp((const void *)addr, before, sizeof(before)) == 0;
    NP_ERR("[%s] %s: %s failed (ret=%d) @ %p, %s", group, e->label,
           prehook ? "DobbyInstrument" : "DobbyHook", rc, (void *)addr,
           !patched ? "target untouched"
           : restored ? "original bytes restored"
           : "target stays patched with no original, the hook degrades instead");
    return 0;
}

static int install_groups(const np_hook_group_t *groups, size_t n_groups,
                          np_resolve_result_t *resolved, int *total_out) {
    int total  = 0;
    int landed = 0;

    for (size_t g = 0; g < n_groups; g++) {
        const np_hook_group_t *group = &groups[g];
        np_patch_entry_t *entries = group->entries();
        int n = group->count();
        for (int i = 0; i < n; i++) {
            total++;
            landed += np_apply_entry(resolved, group->group, &entries[i]);
        }
    }

    if (total_out)
        *total_out = total;
    return landed;
}

int np_hooks_install_steamui(const struct mach_header_64 *mh, intptr_t slide,
                             np_resolve_result_t *resolved, int *total_out) {
    (void)slide;
    np_hooks_shortcut_bundle_bind(mh);

    int total  = 0;
    int landed = install_groups(np_steamui_groups,
                                sizeof(np_steamui_groups) / sizeof(np_steamui_groups[0]),
                                resolved, &total);

    if (total_out)
        *total_out = total;
    NP_LOG("hooks: steamui %d/%d installed", landed, total);
    return landed;
}

int np_hooks_install_all(const struct mach_header_64 *mh, intptr_t slide,
                         np_resolve_result_t *resolved, int *total_out) {
    np_hooks_compat_set_helpers(
        np_lookup_address(resolved, "CCompatManager::YldRegisterTool"),
        np_lookup_address(resolved, "CCompatManager::GetValidPlatforms"),
        np_lookup_address(resolved, "CCompatManager::FindToolForTargetApp"),
        np_lookup_address(resolved, "CCompatManager::SetCompatToolMapping"),
        np_lookup_address(resolved, "CCompatManager::FindMapping"),
        np_lookup_address(resolved, "CCompatManager::GetWildcardMapping"));

    np_compat_probe_tool_head(
        np_lookup_address(resolved, "CCompatManager::YldRegisterTool"));
    np_compat_probe_tool_layout(
        np_lookup_address(resolved, "CCompatManager::ResolveCompatToolForApp.local_redirect"),
        np_lookup_address(resolved, "CCompatManager::GetOSListOverrideForApp.oslist_gate"));
    np_compat_probe_enabled_off(
        np_lookup_address(resolved, "CCompatManager::BIsCompatibilityToolEnabled"));
    np_compat_probe_windows_only_off(
        np_lookup_address(resolved, "CCompatManager::GetWildcardMapping"),
        np_lookup_address(resolved, "CCompatManager::WindowsOnlyLookup"));
    np_usershortcuts_bind(mh, slide,
        np_lookup_address(resolved, "CUserShortcuts::SetShortcutExe"));

    uintptr_t register_fn = np_lookup_address(resolved,
                                             "CWebUIJobDispatcher::RegisterHandler");
    uintptr_t dispatch_fn = np_lookup_address(resolved, "CWebUITransport::DispatchJob");

    np_webui_init(mh, slide, register_fn, dispatch_fn,
                  np_lookup_address(resolved, "CWebUIMsgJob::SendResponse"));
    np_webui_dump_routes();
    np_hooks_webui_bind(mh, slide, register_fn, dispatch_fn);

    int total  = 0;
    int landed = install_groups(np_groups, sizeof(np_groups) / sizeof(np_groups[0]),
                                resolved, &total);

    np_hooks_compat_publish_originals();

    if (total_out)
        *total_out = total;
    NP_LOG("hooks: %d/%d installed", landed, total);
    return landed;
}
