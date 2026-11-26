// Compat tool hooks
#include "hooks.h"
#include "../feats/compat.h"
#include "../feats/compatsvc.h"
#include "../feats/usershortcuts.h"
#include "../util/ptr.h"
#include "../util/log.h"
#include <stdint.h>
#include <stdbool.h>
#include <signal.h>
#include <string.h>

static void *orig_CCompatManager_Init = NULL;
typedef void *(*fn_CCompatManager_Init)(void *self, void *arg1);

// A failed DobbyHook leaves the target patched with no original. Every hook
// below gives up its feature on NULL rather than fault, for safety.
static void *hook_CCompatManager_Init(void *self, void *arg1) {
    fn_CCompatManager_Init orig = (fn_CCompatManager_Init)orig_CCompatManager_Init;
    if (!orig) {
        NP_ERR("hook_CCompatManager_Init: no original, cannot initialize the manager");
        return NULL;
    }
    void *ret = orig(self, arg1);

    np_compat_force_enable(self);

    return ret;
}

static void *orig_CCompatManager_BIsEnabled = NULL;
typedef bool (*fn_CCompatManager_BIsEnabled)(void *self, uint32_t appid);

// Runs on every compat query, forcing the global switch on. Native Mac
// apps are not routed through a compatibility tool.
static bool hook_CCompatManager_BIsEnabled(void *self, uint32_t appid) {
    fn_CCompatManager_BIsEnabled orig = (fn_CCompatManager_BIsEnabled)orig_CCompatManager_BIsEnabled;
    if (!orig) {
        NP_ERR("hook_CCompatManager_BIsEnabled: no original, reporting compat disabled");
        return false;
    }
    np_compat_force_enable(self);
    np_compat_register_crossover(self);
    np_compat_note_app(self, appid);
    return orig(self, appid);
}

void np_hooks_compat_set_helpers(uintptr_t yld_register_tool,
                                 uintptr_t get_valid_platforms,
                                 uintptr_t find_tool_for_target_app,
                                 uintptr_t set_compat_tool_mapping,
                                 uintptr_t find_mapping,
                                 uintptr_t get_wildcard_mapping) {
    np_compat_set_register_fn(yld_register_tool);
    np_compat_set_valid_platforms_fn(get_valid_platforms);
    np_compat_set_find_tool_fn(find_tool_for_target_app);
    np_compat_set_mapping_fn(set_compat_tool_mapping);
    np_compat_set_app_mapping_fn(find_mapping);
    np_compat_set_wildcard_fn(get_wildcard_mapping);
}

static void *orig_FindToolForTargetApp = NULL;
typedef void *(*fn_FindToolForTargetApp)(void *self, uint32_t appid);

// An unmapped windows-only app resolves to no tool ("Install on Windows").
// Those are defaulted to CrossOver for quality UX.
static void *hook_FindToolForTargetApp(void *self, uint32_t appid) {
    fn_FindToolForTargetApp orig = (fn_FindToolForTargetApp)orig_FindToolForTargetApp;
    if (!orig) {
        NP_ERR("hook_FindToolForTargetApp: no original, resolving no tool for appID %u",
               appid);
        return NULL;
    }
    void *tool = orig(self, appid);

    if (tool || appid == 0)
        return tool;

    // The NP_COMPAT_TOOL_NONE sentinel is honored as an explicit refusal.
    const char *mapping = np_compat_app_mapping(self, appid);
    if (np_compat_is_none(mapping))
        return NULL;

    if (!np_compat_would_force(self, appid))
        return NULL;

    void *crossover = np_compat_registered_tool(self);
    if (crossover)
        NP_DBG("hook_FindToolForTargetApp: appID %u is windows-only, defaulting to CrossOver tool",
               appid);
    return crossover;
}

static void *orig_WindowsOnlyLookup = NULL;
// Returns a bool, but the whole register is passed through in case this resolves
// to the wrong function.
typedef uint64_t (*fn_WindowsOnlyLookup)(const void *map, const uint32_t *appid,
                                         const uint8_t *fallback);

static uint64_t hook_WindowsOnlyLookup(const void *map, const uint32_t *appid,
                                       const uint8_t *fallback) {
    fn_WindowsOnlyLookup orig = (fn_WindowsOnlyLookup)orig_WindowsOnlyLookup;
    if (!orig) {
        static const char once = 0;
        if (np_log_first_hit(&once, 0))
            NP_ERR("hook_WindowsOnlyLookup: no original, reporting every key missing");
        return fallback ? *fallback : 0;
    }
    uint64_t found = orig(map, appid, fallback);
    if ((uint32_t)found || !appid)
        return found;
    void *mgr = np_compat_manager();
    if (!np_compat_is_windows_only_table(mgr, map))
        return found;
    return np_usershortcuts_runs_exe(np_compat_user(mgr), *appid);
}

static void *orig_InternalSpecifyCompatTool = NULL;
typedef uint64_t (*fn_InternalSpecifyCompatTool)(void *self, uint64_t appid,
                                                 const char *name, void *config,
                                                 int priority);

// Every mapping change arrives here (global default/per-app), so this is
// where the page is notified.
static uint64_t hook_InternalSpecifyCompatTool(void *self, uint64_t appid,
                                               const char *name, void *config,
                                               int priority) {
    fn_InternalSpecifyCompatTool orig =
        (fn_InternalSpecifyCompatTool)orig_InternalSpecifyCompatTool;
    if (!orig) {
        NP_ERR("hook_InternalSpecifyCompatTool: no original, so appID %u keeps the "
               "mapping it had", (uint32_t)appid);
        return 0;
    }

    uint64_t result = orig(self, appid, name, config, priority);
    np_compatsvc_state_changed();
    return result;
}

// The trampoline is the client's own resolution without the CrossOver default.
void np_hooks_compat_publish_originals(void) {
    np_compat_set_chosen_tool_fn((uintptr_t)orig_FindToolForTargetApp);
}

// Proton converts is only for Linux, so the oslist match fails on macOS and the
// app shows "Install on Windows". Forcing x0 non-zero takes the from_oslist
// write path.
static void instrument_oslist_override_gate(void *address, void *ctx_) {
    (void)address;
    np_arm64_ctx_t *ctx = (np_arm64_ctx_t *)ctx_;
    if (ctx->general.x[0] != 0)
        return;
    ctx->general.x[0] = 1;
    uint64_t tool = ctx->general.x[21];
    uint32_t appid = (tool && np_plausible_ptr(tool) && np_compat_layout_known())
                     ? *(uint32_t *)(tool + np_compat_tool_off(COMPAT_TOOL_APPID_OFF)) : 0;
    NP_LOG("instrument_oslist_override_gate: appid=%u install platform forced to tool from_oslist", appid);
}

//
#define TOOL_VERSION_OFF      0x04
#define TOOL_COMMANDLINE_OFF  0x18
#define TOOL_DEPENDENCY_OFF   0x20

// Proton targets linux with no macOS depot, so the depot lookup fails. Rewriting
// the tool to appid zero points the launch builder at the local CrossOver
// directory.
static void instrument_resolver_local_redirect(void *address, void *ctx_) {
    (void)address;
    np_arm64_ctx_t *ctx = (np_arm64_ctx_t *)ctx_;

    uint64_t tool = ctx->general.x[0];
    if (!tool || !np_plausible_ptr(tool))
        return;
    if (!np_compat_layout_known()) {
        static const char once = 0;
        if (np_log_first_hit(&once, 0))
            NP_ERR("instrument_resolver_local_redirect: this client's tool layout was not "
                   "confirmed, so no tool is routed to Bridgeplay");
        return;
    }

    uint32_t tool_appid = *(uint32_t *)(tool + np_compat_tool_off(COMPAT_TOOL_APPID_OFF));
    if (tool_appid == 0)
        return;

    const char *tool_dir = np_compat_tool_dir();
    if (!tool_dir)
        return;

    *(uint32_t *)(tool + TOOL_VERSION_OFF)     = 2;
    *(uint32_t *)(tool + TOOL_DEPENDENCY_OFF)  = 0;
    *(uint32_t *)(tool + np_compat_tool_off(COMPAT_TOOL_APPID_OFF)) = 0;
    *(const char **)(tool + np_compat_tool_off(COMPAT_TOOL_INSTALL_OFF)) = tool_dir;
    *(const char **)(tool + TOOL_COMMANDLINE_OFF) = np_compat_tool_commandline();

    NP_LOG("instrument_resolver_local_redirect: tool %u routed to local CrossOver tool at %s",
           tool_appid, tool_dir);
}

static void *orig_TerminateProcessByPid = NULL;
typedef int (*fn_TerminateProcessByPid)(int pid);

static int hook_TerminateProcessByPid(int pid) {
    fn_TerminateProcessByPid orig = (fn_TerminateProcessByPid)orig_TerminateProcessByPid;
    int ret = orig ? orig(pid) : 0;
    if (!orig)
        NP_ERR("hook_TerminateProcessByPid: no original, signalling pid %d directly", pid);
    if (ret == 0 && pid > 0) {
        if (kill(pid, SIGTERM) == 0) {
            NP_LOG("hook_TerminateProcessByPid: pid %d has no running application, "
                   "sent SIGTERM to run script for prefix teardown", pid);
            return 1;
        }
    }
    return ret;
}

static np_patch_entry_t g_hooks[] = {
    {
        .label    = "CCompatManager::Init",
        .signature = "CCompatManager::Init",
        .entry    = (void *)hook_CCompatManager_Init,
        .trampoline = &orig_CCompatManager_Init,
    },
    {
        .label    = "CCompatManager::BIsCompatibilityToolEnabled",
        .signature = "CCompatManager::BIsCompatibilityToolEnabled",
        .entry    = (void *)hook_CCompatManager_BIsEnabled,
        .trampoline = &orig_CCompatManager_BIsEnabled,
    },
    {
        .label    = "CCompatManager::FindToolForTargetApp",
        .signature = "CCompatManager::FindToolForTargetApp",
        .entry    = (void *)hook_FindToolForTargetApp,
        .trampoline = &orig_FindToolForTargetApp,
    },
    {
        .label    = "CCompatManager::WindowsOnlyLookup",
        .signature = "CCompatManager::WindowsOnlyLookup",
        .entry    = (void *)hook_WindowsOnlyLookup,
        .trampoline = &orig_WindowsOnlyLookup,
    },
    {
        .label    = "CCompatManager::InternalSpecifyCompatTool",
        .signature = "CCompatManager::InternalSpecifyCompatTool",
        .entry    = (void *)hook_InternalSpecifyCompatTool,
        .trampoline = &orig_InternalSpecifyCompatTool,
    },
    {
        .label    = "CCompatManager::GetOSListOverrideForApp.oslist_gate",
        .signature = "CCompatManager::GetOSListOverrideForApp.oslist_gate",
        .entry    = (void *)instrument_oslist_override_gate,
        .trampoline = NULL,
        .mode     = NP_PATCH_PREHOOK,
    },
    {
        .label    = "CCompatManager::ResolveCompatToolForApp.local_redirect",
        .signature = "CCompatManager::ResolveCompatToolForApp.local_redirect",
        .entry    = (void *)instrument_resolver_local_redirect,
        .trampoline = NULL,
        .mode     = NP_PATCH_PREHOOK,
    },
    {
        .label    = "CAppManager::TerminateProcessByPid",
        .signature = "CAppManager::TerminateProcessByPid",
        .entry    = (void *)hook_TerminateProcessByPid,
        .trampoline = &orig_TerminateProcessByPid,
    },
};

int np_hooks_compat_count(void) {
    return (int)(sizeof(g_hooks) / sizeof(g_hooks[0]));
}

np_patch_entry_t *np_hooks_compat_defs(void) {
    return g_hooks;
}
