// Dylib entry point into steamclient.dylib
#include "../version.h"
#include "../util/log.h"
#include "../util/file.h"
#include "../resolver/resolver.h"
#include "../resolver/sigdb.h"
#include "../core/macho.h"
#include "../hooks/hooks.h"
#include "../feats/compat.h"
#include "../feats/input_access.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <stdint.h>
#include <dirent.h>
#include <mach-o/dyld.h>
#include <crt_externs.h>
#include <libgen.h>

#define STEAMCLIENT_DYLIB "steamclient.dylib"
#define STEAMUI_DYLIB     "steamui.dylib"

// The bootstrapper can take a while before the real client dylib appears...
#define WAIT_TIMEOUT_MS 60000

static void drop_marker_file(const char *dir, const char *name) {
    char path[1024];
    int len = snprintf(path, sizeof(path), "%s/%s", dir, name);
    if (len < 0 || len >= (int)sizeof(path))
        return;
    if (unlink(path) == 0)
        NP_LOG("removed marker %s", path);
}

// A leftover 'marker' makes the client redownload and rewrite Info.plist, which is bad.
static void clear_relaunch_markers(void) {
    char exe[1024];
    uint32_t cap = sizeof(exe);
    if (_NSGetExecutablePath(exe, &cap) != 0) {
        NP_WARN("could not read own executable path");
        return;
    }

    char scratch[1024];
    snprintf(scratch, sizeof(scratch), "%s", exe);
    const char *dir = dirname(scratch);

    drop_marker_file(dir, ".crash");
    drop_marker_file(dir, ".forceupdate");
}

static int pick_latest_sigdb(const char *dir, char *buf, size_t buf_size) {
    DIR *dh = opendir(dir);
    if (!dh)
        return -1;

    uint64_t top = 0;
    int found = 0;
    struct dirent *e;
    while ((e = readdir(dh)) != NULL) {
        size_t len = strlen(e->d_name);
        if (len < 6 || strcmp(e->d_name + len - 5, ".json") != 0)
            continue;

        char *stop = NULL;
        uint64_t build = strtoull(e->d_name, &stop, 10);
        if (build == 0 || stop != e->d_name + len - 5)
            continue;

        if (!found || build >= top) {
            top = build;
            found = 1;
            snprintf(buf, buf_size, "%s/%s", dir, e->d_name);
        }
    }
    closedir(dh);

    return found ? 0 : -1;
}

static void sigdb_path_for(char *buf, size_t buf_size) {
    const char *env = getenv("NOTPROTON_SIG");
    if (env && env[0]) {
        snprintf(buf, buf_size, "%s", env);
        return;
    }

    const char *home = np_home_dir();
    if (!home) {
        snprintf(buf, buf_size, "<no-home>/<none>.json");
        return;
    }

    char dir[512];
    np_support_path(dir, sizeof(dir), home, "signatures/macos.arm64");

    if (pick_latest_sigdb(dir, buf, buf_size) == 0)
        return;

    snprintf(buf, buf_size, "%s/<none>.json", dir);
}

static pthread_t g_install;
static int       g_install_started;
static int       g_active;

static void install_steamui(np_sigdb_t *sigdb) {
    int required = np_required_for_module(sigdb, STEAMUI_DYLIB);
    if (required == 0) {
        NP_DBG("install_thread: no %s signatures in this database", STEAMUI_DYLIB);
        return;
    }

    const struct mach_header_64 *mh = NULL;
    intptr_t slide = 0;

    if (np_await_image(STEAMUI_DYLIB, WAIT_TIMEOUT_MS, &mh, &slide) != 0) {
        NP_WARN("install_thread: %s absent after %d ms, its hooks stay off",
                STEAMUI_DYLIB, WAIT_TIMEOUT_MS);
        return;
    }

    np_resolve_result_t resolved = {0};
    int count = np_resolve_signatures(mh, slide, sigdb, STEAMUI_DYLIB, &resolved);
    NP_LOG("install_thread: %s signatures %d/%d resolved", STEAMUI_DYLIB, count, required);

    if (count < required)
        NP_WARN("install_thread: %s %d/%d signatures resolved; the hooks that did "
                "resolve still install, the rest stay off", STEAMUI_DYLIB, count,
                required);

    int total = 0;
    int installed = np_hooks_install_steamui(mh, slide, &resolved, &total);

    NP_LOG("install_thread: %s ready, %d/%d hooks installed",
           STEAMUI_DYLIB, installed, total);

    np_free_resolution(&resolved);
}

static void *install_thread(void *unused) {
    (void)unused;

    NP_LOG("install_thread: waiting for %s", STEAMCLIENT_DYLIB);

    const struct mach_header_64 *mh = NULL;
    intptr_t slide = 0;

    if (np_await_image(STEAMCLIENT_DYLIB, WAIT_TIMEOUT_MS, &mh, &slide) != 0) {
        // The Steam bootstraper does this
        NP_LOG("install_thread: %s absent after %d ms, hooks will install in the "
               "relaunched client", STEAMCLIENT_DYLIB, WAIT_TIMEOUT_MS);
        return NULL;
    }

    np_input_access_check();

    uintptr_t text_base = 0;
    size_t text_size = 0;

    if (np_find_segment(mh, slide, "__TEXT", &text_base, &text_size) != 0) {
        NP_ERR("install_thread: no __TEXT segment in %s", STEAMCLIENT_DYLIB);
        return NULL;
    }

    NP_LOG("install_thread: %s __TEXT @ 0x%lx (%zu bytes) slide=0x%lx",
           STEAMCLIENT_DYLIB, (unsigned long)text_base, text_size,
           (unsigned long)slide);

    np_sigdb_t sigdb = {0};

    char sig_path[512];
    sigdb_path_for(sig_path, sizeof(sig_path));

    if (np_load_profile(sig_path, &sigdb) != 0) {
        NP_ERR("install_thread: cannot load signature database from %s", sig_path);
        return NULL;
    }

    np_resolve_result_t resolved = {0};

    int resolved_count = np_resolve_signatures(mh, slide, &sigdb, STEAMCLIENT_DYLIB,
                                               &resolved);
    int required = np_required_for_module(&sigdb, STEAMCLIENT_DYLIB);
    NP_LOG("install_thread: signatures %d/%d resolved", resolved_count, required);

    // Safety feature :)
    if (resolved_count < required) {
        NP_ERR("install_thread: %d/%d signatures resolved, installing nothing; "
               "the signature database is out of date for this Steam build",
               resolved_count, required);
        np_free_resolution(&resolved);
        np_free_profile(&sigdb);
        return NULL;
    }

    np_hooks_launch_install(mh, slide);

    int total = 0;
    int installed = np_hooks_install_all(mh, slide, &resolved, &total);

    NP_LOG("install_thread: ready, %d/%d hooks installed", installed, total);

    if (installed == 0)
        NP_WARN("install_thread: no hooks installed, check the signature database");
    else if (installed < total)
        NP_WARN("install_thread: only %d of %d hooks installed, compat support is "
                "incomplete for this client build", installed, total);

    np_free_resolution(&resolved);

    install_steamui(&sigdb);

    np_free_profile(&sigdb);

    return NULL;
}

static void np_log_platform_overrides(void) {
    static const char *const vars[] = {
        "SteamOverridePlatform",
        "SteamPlatform",
        "STEAM_FORCE_OS",
        "STEAMOS",
        "SteamOS",
        "SteamOverrideOSType",
        "STEAM_COMPAT_FORCE_PLATFORM",
    };

    int found = 0;
    for (size_t i = 0; i < sizeof(vars) / sizeof(vars[0]); i++) {
        const char *val = getenv(vars[i]);
        if (val) {
            NP_LOG("np_init: platform override present %s=%s", vars[i], val);
            found = 1;
        }
    }
    if (!found)
        NP_LOG("np_init: no platform override env set, client reports as macOS");
}

// Steam Helper runs /usr/bin/profiles at startup. If a user has SIP disabled, profiles would inherit the insert and crash, yikes.
static int is_main_helper(const char *pn) {
    if (strcmp(pn, "Steam Helper") != 0)
        return 0;
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "--type=", 7) == 0)
            return 0;
    }
    return 1;
}

__attribute__((constructor))
static void np_init(void) {
    const char *pn = getprogname();
    if (!pn)
        return;
    if (is_main_helper(pn)) {
        np_log_attach();
        np_hooks_spawn_install();
        return;
    }
    if (strcmp(pn, "steam_osx") != 0)
        return;

    np_log_init();
    g_active = 1;

    clear_relaunch_markers();

    NP_LOG("np_init: loaded into %s (pid %d) Bridgeplay %s (%d), NotProton %s",
           pn, getpid(), BRIDGEPLAY_VERSION, BRIDGEPLAY_BUILD, NOTPROTON_VERSION);

    np_log_platform_overrides();
    np_compat_export_tools_path();
    // Steam scans compatibilitytools.d at startup, so the tool directories have to exist
    // before that occurs.
    np_compat_ensure_tool_manifest();
    np_hooks_spawn_install();
    np_hooks_activate_install();

    if (pthread_create(&g_install, NULL, install_thread, NULL) == 0)
        g_install_started = 1;
    else
        NP_ERR("np_init: cannot create loader thread");
}

__attribute__((destructor))
static void np_fini(void) {
    if (!g_active)
        return;

    if (g_install_started) {
        np_await_stop();
        pthread_join(g_install, NULL);
    }

    NP_LOG("np_fini: unloading, hooks left in place for the OS to reclaim");
}
