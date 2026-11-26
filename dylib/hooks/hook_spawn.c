// Strips DYLD_INSERT_LIBRARIES and the SDL block list from child processes
#include "hooks.h"
#include "../util/log.h"

#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern int   DobbyHook(void *address, void *replace_call, void **origin_call);
extern void *DobbySymbolResolver(const char *image_name, const char *symbol_name);

typedef int (*fn_execve)(const char *path, char *const argv[], char *const envp[]);
typedef int (*fn_posix_spawn)(pid_t *pid, const char *path,
                             const posix_spawn_file_actions_t *fa,
                             const posix_spawnattr_t *attr,
                             char *const argv[], char *const envp[]);

static fn_execve      orig_execve;
static fn_posix_spawn orig_posix_spawn;
static fn_posix_spawn orig_posix_spawnp;

#define NP_INSERT_KEY "DYLD_INSERT_LIBRARIES="

// The SDL block list stops Steam from seeing a second, generic copy of the Steam Controller.
// This solves double input issues.
// SDL_HIDAPI_LIBUSB=0 khusus untuk proses Steam agar game/Wine tetap dapat memakai libusb bila diperlukan.
static const char *const np_steam_only_keys[] = {
    NP_INSERT_KEY,
    "SDL_JOYSTICK_BLACKLIST_DEVICES=",
    "SDL_HIDAPI_LIBUSB=",
};

static int np_is_steam_only(const char *entry) {
    for (size_t k = 0; k < sizeof(np_steam_only_keys) / sizeof(np_steam_only_keys[0]); k++) {
        if (strncmp(entry, np_steam_only_keys[k], strlen(np_steam_only_keys[k])) == 0)
            return 1;
    }
    return 0;
}

// steam_osx re-execs itself and needs the insert for hooks. Steam Helper runs
// CEF and needs it for the webpatch fopen interpose, strips elsewhere
static int np_target_keeps_insert(const char *path) {
    if (!path)
        return 1;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    return strcmp(base, "steam_osx") == 0
        || strcmp(base, "Steam Helper") == 0;
}

// LaunchServices hands the caller's environment to every app it opens, so the insert
// lives here instead and only goes back into steam_osx and Steam Helper
static char *np_insert_entry;

static int np_is_insert(const char *entry) {
    return strncmp(entry, NP_INSERT_KEY, strlen(NP_INSERT_KEY)) == 0;
}

static char **np_with_insert(char *const envp[]) {
    if (!np_insert_entry)
        return NULL;

    int count = 0;
    if (envp) {
        for (; envp[count]; count++) {
            if (np_is_insert(envp[count]))
                return NULL;
        }
    }

    char **full = malloc(sizeof(char *) * (size_t)(count + 2));
    if (!full) {
        NP_WARN("[spawn] cannot allocate an environment with the insert, child starts without it");
        return NULL;
    }
    for (int i = 0; i < count; i++)
        full[i] = envp[i];
    full[count] = np_insert_entry;
    full[count + 1] = NULL;
    return full;
}

static void np_take_insert(void) {
    const char *value = getenv("DYLD_INSERT_LIBRARIES");
    if (!value || np_insert_entry)
        return;

    size_t len = strlen(NP_INSERT_KEY) + strlen(value) + 1;
    np_insert_entry = malloc(len);
    if (!np_insert_entry) {
        NP_WARN("[spawn] cannot hold the insert, apps opened from here inherit it");
        return;
    }
    snprintf(np_insert_entry, len, "%s%s", NP_INSERT_KEY, value);
    unsetenv("DYLD_INSERT_LIBRARIES");
    NP_LOG("[spawn] insert taken out of the environment");
}

static char **np_without_insert(char *const envp[]) {
    if (!envp)
        return NULL;

    int count = 0;
    int found = 0;
    for (int i = 0; envp[i]; i++) {
        if (np_is_steam_only(envp[i]))
            found = 1;
        count++;
    }
    if (!found)
        return NULL;

    char **clean = malloc(sizeof(char *) * (size_t)(count + 1));
    if (!clean) {
        NP_WARN("[spawn] cannot allocate a stripped environment, insert passed through");
        return NULL;
    }

    int j = 0;
    for (int i = 0; envp[i]; i++) {
        if (!np_is_steam_only(envp[i]))
            clean[j++] = envp[i];
    }
    clean[j] = NULL;
    return clean;
}

static int np_hook_execve(const char *path, char *const argv[], char *const envp[]) {
    int keep = np_target_keeps_insert(path);
    char **clean = keep ? np_with_insert(envp) : np_without_insert(envp);
    if (!clean)
        return orig_execve(path, argv, envp);

    NP_DBG("[spawn] execve '%s' %s the insert", path, keep ? "with" : "without");
    int rc = orig_execve(path, argv, (char *const *)clean);
    // Only reached when the exec failed, since a successful one replaced this image.
    free(clean);
    return rc;
}

static int np_spawn_filtered(fn_posix_spawn orig, const char *api,
                                   pid_t *pid, const char *path,
                                   const posix_spawn_file_actions_t *fa,
                                   const posix_spawnattr_t *attr,
                                   char *const argv[], char *const envp[]) {
    int keep = np_target_keeps_insert(path);
    char **clean = keep ? np_with_insert(envp) : np_without_insert(envp);
    if (!clean)
        return orig(pid, path, fa, attr, argv, envp);

    NP_DBG("[spawn] %s '%s' %s the insert", api, path, keep ? "with" : "without");
    int rc = orig(pid, path, fa, attr, argv, (char *const *)clean);
    free(clean);
    return rc;
}

static int np_hook_posix_spawn(pid_t *pid, const char *path,
                               const posix_spawn_file_actions_t *fa,
                               const posix_spawnattr_t *attr,
                               char *const argv[], char *const envp[]) {
    return np_spawn_filtered(orig_posix_spawn, "posix_spawn",
                                   pid, path, fa, attr, argv, envp);
}

static int np_hook_posix_spawnp(pid_t *pid, const char *path,
                                const posix_spawn_file_actions_t *fa,
                                const posix_spawnattr_t *attr,
                                char *const argv[], char *const envp[]) {
    return np_spawn_filtered(orig_posix_spawnp, "posix_spawnp",
                                   pid, path, fa, attr, argv, envp);
}

static int np_hook_symbol(const char *sym, void *repl, void **orig) {
    void *addr = DobbySymbolResolver("libsystem_kernel.dylib", sym);
    if (!addr)
        addr = DobbySymbolResolver(NULL, sym);
    if (!addr) {
        NP_WARN("[spawn] %s: unresolved, children keep the insert", sym);
        return 0;
    }

    int rc = DobbyHook(addr, repl, orig);
    if (rc == 0) {
        NP_LOG("[spawn] %s: hooked @ %p", sym, addr);
        return 1;
    }
    NP_WARN("[spawn] %s: DobbyHook failed rc=%d, children keep the insert", sym, rc);
    return 0;
}

void np_hooks_spawn_install(void) {
    if (np_hooks_env_lists_label("NOTPROTON_DISABLE", "spawn")) {
        NP_WARN("[spawn] DISABLED via NOTPROTON_DISABLE, children keep the insert");
        return;
    }

    int hooked = np_hook_symbol("execve",       (void *)np_hook_execve,       (void **)&orig_execve)
               + np_hook_symbol("posix_spawn",  (void *)np_hook_posix_spawn,  (void **)&orig_posix_spawn)
               + np_hook_symbol("posix_spawnp", (void *)np_hook_posix_spawnp, (void **)&orig_posix_spawnp);

    // Without every hook in place, a steam_osx re-exec could start without the dylib
    if (hooked == 3)
        np_take_insert();
}
