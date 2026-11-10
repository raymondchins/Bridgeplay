// CompatManager WebUI service.
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <unistd.h>

#include "compatsvc.h"
#include "compat.h"
#include "prefixstate.h"
#include "quicksettings.h"
#include "webui.h"
#include "../resolver/anchor.h"
#include "../util/file.h"
#include "../util/log.h"

// Route names carry the interface version the page asks for.
#define ROUTE_GET_COMPAT_TOOLS     "CompatManager.GetCompatTools#1"
#define ROUTE_SPECIFY_COMPAT_TOOL  "CompatManager.SpecifyCompatTool#1"
#define ROUTE_NOTIFY_STATE_CHANGED "CompatManager.NotifyStateChanged#1"
// Our own route. It borrows the GetCompatTools types, and the answer is JSON in
// default_tool_identifier, so the page needs no message class of its own.
#define ROUTE_PREFIX_STATE         "NotProton.PrefixState#1"
#define ROUTE_REBUILD              "NotProton.RebuildPrefix#1"
#define ROUTE_BACKUP_REBUILD       "NotProton.BackupAndRebuildPrefix#1"
#define ROUTE_OPEN_LOG             "NotProton.OpenPrefixLog#1"
// Changes from the in-game quick settings sidebar, for the page to write to launch options.
#define ROUTE_TAKE_QUICK_SETTINGS  "NotProton.TakeQuickSettings#1"

// Mangled RTTI names of the message types. A client that builds the CompatManager
// page compiles these without registering the service, so the vtables are there to
// be found. A client whose page specifies the tool directly carries none of them.
#define TYPE_GET_REQUEST      "37CCompatManager_GetCompatTools_Request"
#define TYPE_GET_RESPONSE     "38CCompatManager_GetCompatTools_Response"
#define TYPE_SPECIFY_REQUEST  "40CCompatManager_SpecifyCompatTool_Request"
#define TYPE_SPECIFY_RESPONSE "41CCompatManager_SpecifyCompatTool_Response"
#define TYPE_STATE_CHANGED    "40CCompatManager_StateChanged_Notification"

// CCompatManager_GetCompatTools_Request.
#define REQ_HAS_BITS_OFF 16
#define REQ_APPID_OFF    24
#define REQ_HAS_APPID    1

// CCompatManager_SpecifyCompatTool_Request. An unset name field points at the
// shared empty string, which clears the mapping back to its default.
#define SPECIFY_TOOL_NAME_OFF 24
#define SPECIFY_APPID_OFF     32
#define SPECIFY_HAS_APPID     2

// Result the page reads as success, and the one it reads as failure.
#define RESULT_OK   1
#define RESULT_FAIL 2

// Field numbers of the two messages, from the interface the page is built against.
#define TOOL_NAME            1
#define TOOL_DISPLAY_NAME    2
#define TOOL_IS_DEFAULT      3
#define TOOL_IS_ACTIVE       4
#define TOOL_IS_LEGACY       5
#define TOOL_IS_INCOMPATIBLE 6

#define RESP_TOOLS    1
#define RESP_SELECTED 3
#define RESP_DEFAULT  4

// Wire types this writes.
#define WIRE_VARINT 0
#define WIRE_BYTES  2

#define TOOL_MAX  512

// No appid equals the global Steam Play setting, answered with windows.
#define PLATFORMS_UNSCOPED COMPAT_PLATFORM_WINDOWS

// A tool's own appid gets this result instead of a list.
#define RESULT_IS_A_TOOL 128

// Display label for the "no tool" entry.
#define TOOL_NONE_LABEL "No Compatibility Tool"

// Protobuf writer.
typedef struct {
    uint8_t *buf;
    size_t   cap;
    size_t   len;
    int      ok;
} np_pb_t;

static void pb_byte(np_pb_t *w, uint8_t b) {
    if (w->len >= w->cap) { w->ok = 0; return; }
    w->buf[w->len++] = b;
}

static void pb_varint(np_pb_t *w, uint64_t v) {
    do {
        uint8_t b = (uint8_t)(v & 0x7f);
        v >>= 7;
        pb_byte(w, v ? (uint8_t)(b | 0x80) : b);
    } while (v && w->ok);
}

static void pb_tag(np_pb_t *w, uint32_t field, uint32_t wire) {
    pb_varint(w, ((uint64_t)field << 3) | wire);
}

static void pb_blob(np_pb_t *w, uint32_t field, const uint8_t *bytes, size_t len) {
    pb_tag(w, field, WIRE_BYTES);
    pb_varint(w, len);
    for (size_t i = 0; i < len && w->ok; i++)
        pb_byte(w, bytes[i]);
}

static void pb_string(np_pb_t *w, uint32_t field, const char *str) {
    if (!str) return;
    pb_blob(w, field, (const uint8_t *)str, strlen(str));
}

static void pb_bool(np_pb_t *w, uint32_t field, int set) {
    pb_tag(w, field, WIRE_VARINT);
    pb_varint(w, set ? 1 : 0);
}

static void pb_tool(np_pb_t *w, uint32_t resp_field,
                    const char *name, const char *display,
                    int is_active, int is_incompatible) {
    uint8_t item[TOOL_MAX];
    np_pb_t t = { item, sizeof item, 0, 1 };
    pb_string(&t, TOOL_NAME, name);
    pb_string(&t, TOOL_DISPLAY_NAME, display);
    pb_bool(&t, TOOL_IS_DEFAULT, 0);
    pb_bool(&t, TOOL_IS_ACTIVE, is_active);
    pb_bool(&t, TOOL_IS_LEGACY, 0);
    pb_bool(&t, TOOL_IS_INCOMPATIBLE, is_incompatible);
    if (t.ok)
        pb_blob(w, resp_field, item, t.len);
    else
        w->ok = 0;
}

static int offered(const uint8_t *tool, uint32_t platforms, int bypass) {
    uint32_t converts_from =
        *(const uint32_t *)(tool + np_compat_tool_off(COMPAT_TOOL_PLATFORM_OFF));
    uint32_t gate = *(const uint32_t *)(tool + COMPAT_TOOL_GATE_FLAGS_OFF);

    if (!(platforms & converts_from)) return 0;
    if ((gate & COMPAT_TOOL_GATE_HIDDEN) && !bypass) return 0;
    return 1;
}

static const char *tool_name(const void *tool) {
    if (!tool) return NULL;
    return *(const char *const *)((const uint8_t *)tool + COMPAT_TOOL_NAME_OFF);
}

static int get_compat_tools(uintptr_t request, uintptr_t response) {
    uint32_t has_bits = *(const uint32_t *)(request + REQ_HAS_BITS_OFF);
    uint32_t appid    = (has_bits & REQ_HAS_APPID)
                      ? *(const uint32_t *)(request + REQ_APPID_OFF) : 0;

    uint8_t *mgr = (uint8_t *)np_compat_manager();
    if (!mgr) {
        // An empty list is a valid answer, and the page renders it as no dropdown
        // rather than as an error.
        NP_WARN("compatsvc: app %u asked for tools before any manager was seen, so "
                "the page gets an empty list", appid);
        return RESULT_OK;
    }

    const uint8_t *array = *(const uint8_t **)(mgr + COMPAT_MANAGER_TOOL_ARRAY_OFF);
    uint32_t count       = *(const uint32_t *)(mgr + COMPAT_MANAGER_TOOL_COUNT_OFF);
    if (!array || count > np_compat_manager_tools_max()) {
        NP_ERR("compatsvc: the manager reports %u tool(s) at %p, which is not a list "
               "this reads", count, (const void *)array);
        return RESULT_FAIL;
    }

    int bypass = mgr[np_compat_enabled_off() + 2] != 0;
    if (appid && !bypass) {
        for (uint32_t i = 0; i < count; i++) {
            const uint8_t *tool = array + (size_t)i * np_compat_tool_stride();
            if (*(const uint32_t *)(tool + np_compat_tool_off(COMPAT_TOOL_APPID_OFF)) != appid)
                continue;
            NP_LOG("compatsvc: app %u is itself a compatibility tool, so it is "
                   "offered none", appid);
            return RESULT_IS_A_TOOL;
        }
    }

    uint32_t platforms = appid ? np_compat_valid_platforms(mgr, appid)
                               : PLATFORMS_UNSCOPED;
    // The resolved tool and the raw mapping.
    const char *active = tool_name(np_compat_tool_for_app(mgr, appid));
    // Raw mapping, including names that resolve to no installed tool.
    const char *chosen = appid ? np_compat_app_mapping(mgr, appid)
                               : tool_name(np_compat_chosen_tool(mgr, 0));
    const bool  holds_none = np_compat_is_none(chosen);
    // The fallback tool for when no choice is made. The wildcard covers apps the
    // client will not run natively (Windows stuff). Left unset where nothing carries the app,
    // so the "Default" entry shows no name.
    const char *fallback = np_compat_wildcard_mapping(mgr, appid);
    if (!fallback && (appid == 0 || np_compat_would_force(mgr, appid)))
        fallback = tool_name(np_compat_registered_tool(mgr));

    int32_t best = 0;
    for (uint32_t i = 0; i < count; i++) {
        int32_t prio = *(const int32_t *)(array + (size_t)i * np_compat_tool_stride()
                                          + COMPAT_TOOL_PRIORITY_OFF);
        if (prio > best) best = prio;
    }

    // Every tool plus the none entry and the selected and default names.
    size_t   room   = ((size_t)count + 3) * TOOL_MAX;
    uint8_t *body   = malloc(room);
    if (!body) {
        NP_ERR("compatsvc: no memory for the reply to app %u", appid);
        return RESULT_FAIL;
    }
    np_pb_t  w      = { body, room, 0, 1 };
    int      result = RESULT_FAIL;
    uint32_t listed = 0;

    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *tool = array + (size_t)i * np_compat_tool_stride();
        if (!offered(tool, platforms, bypass)) continue;

        const char *name = tool_name(tool);
        if (!name) continue;

        int32_t prio = *(const int32_t *)(tool + COMPAT_TOOL_PRIORITY_OFF);
        pb_tool(&w, RESP_TOOLS, name,
                *(const char *const *)(tool + COMPAT_TOOL_DISPLAY_OFF),
                active && strcmp(active, name) == 0,
                best != 0 && prio != best && prio > 0);
        if (!w.ok) {
            NP_ERR("compatsvc: tool %s does not fit the reply", name);
            goto done;
        }
        listed++;
    }

    // "No tool" entry.
    if (appid && (fallback || holds_none)) {
        pb_tool(&w, RESP_TOOLS, NP_COMPAT_TOOL_NONE, TOOL_NONE_LABEL,
                holds_none, 0);
        if (!w.ok) {
            NP_ERR("compatsvc: the entry for using no tool does not fit the reply");
            goto done;
        }
        listed++;
    }

    pb_string(&w, RESP_SELECTED, chosen ? chosen : "");

    // The page renders this as "Default".
    if (fallback)
        pb_string(&w, RESP_DEFAULT, fallback);

    if (!w.ok) {
        NP_ERR("compatsvc: %u tool(s) do not fit the reply to app %u", listed, appid);
        goto done;
    }
    if (!np_webui_parse_into(response, body, (uint32_t)w.len)) {
        NP_ERR("compatsvc: the client rejected the %zu byte reply built for app %u",
               w.len, appid);
        goto done;
    }

    NP_LOG("compatsvc: app %u is offered %u entr(ies) from %u tool(s) on platforms "
           "0x%x, mapped to %s, running under %s, defaulting to %s", appid, listed,
           count, platforms, chosen ? chosen : "no tool",
           active ? active : "no tool", fallback ? fallback : "no tool");
    result = RESULT_OK;
done:
    free(body);
    return result;
}

// Reads a protobuf string field.
static const char *string_field(uintptr_t field) {
    uintptr_t str = *(const uintptr_t *)field & ~(uintptr_t)1;
    if (!str) return "";

    const int8_t *bytes = (const int8_t *)str;
    return bytes[23] < 0 ? *(const char *const *)str : (const char *)str;
}

// The page takes the result code as the answer and refetches the tool list.
static int specify_compat_tool(uintptr_t request, uintptr_t response) {
    uint32_t has_bits = *(const uint32_t *)(request + REQ_HAS_BITS_OFF);
    uint32_t appid    = (has_bits & SPECIFY_HAS_APPID)
                      ? *(const uint32_t *)(request + SPECIFY_APPID_OFF) : 0;
    const char *tool  = string_field(request + SPECIFY_TOOL_NAME_OFF);
    (void)response;

    uint8_t *mgr = (uint8_t *)np_compat_manager();
    if (!mgr) {
        NP_ERR("compatsvc: app %u cannot be mapped to %s before any manager was seen",
               appid, *tool ? tool : "its default");
        return RESULT_FAIL;
    }

    np_compat_map_tool(mgr, appid, tool);
    NP_LOG("compatsvc: app %u now maps to %s", appid, *tool ? tool : "its default");
    return RESULT_OK;
}

#define STATE_JSON_MAX 2048

// Every path and tool is worked out here from the appid alone, since any page can call
// these routes and two of them start processes.
static int read_state(uint32_t appid, np_prefix_state_t *st) {
    const char *home = np_home_dir();
    uint8_t *mgr     = (uint8_t *)np_compat_manager();
    if (!appid || !home || !mgr) {
        NP_WARN("compatsvc: no prefix state for app %u without %s", appid,
                !appid ? "an appid" : !home ? "a home folder" : "a manager");
        return 0;
    }
    char steam[PATH_MAX], support[PATH_MAX], server[PATH_MAX];
    snprintf(steam, sizeof steam, "%s/Library/Application Support/Steam", home);
    np_support_path(support, sizeof support, home, NULL);
    snprintf(server, sizeof server, "/tmp/.wine-%u", (unsigned)getuid());
    np_prefix_roots_t roots = { steam, support, server };
    np_prefix_state(appid, tool_name(np_compat_tool_for_app(mgr, appid)), &roots, st);
    return 1;
}

static uint32_t request_appid(uintptr_t request) {
    uint32_t has_bits = *(const uint32_t *)(request + REQ_HAS_BITS_OFF);
    return (has_bits & REQ_HAS_APPID) ? *(const uint32_t *)(request + REQ_APPID_OFF) : 0;
}

static int answer_json(uintptr_t response, uint32_t appid, const char *json) {
    uint8_t body[STATE_JSON_MAX + 8];
    np_pb_t w = { body, sizeof body, 0, 1 };
    pb_string(&w, RESP_DEFAULT, json);
    if (!w.ok || !np_webui_parse_into(response, body, (uint32_t)w.len)) {
        NP_ERR("compatsvc: the client rejected the answer for app %u", appid);
        return RESULT_FAIL;
    }
    return RESULT_OK;
}

// JSON for the CrossOver panel, in default_tool_identifier.
static int prefix_state(uintptr_t request, uintptr_t response) {
    uint32_t appid = request_appid(request);
    np_prefix_state_t st;
    if (!read_state(appid, &st)) return RESULT_FAIL;

    char json[STATE_JSON_MAX];
    if (np_prefix_state_json(appid, &st, json, sizeof json) < 0) {
        NP_ERR("compatsvc: the prefix state for app %u does not fit %d bytes", appid,
               STATE_JSON_MAX);
        return RESULT_FAIL;
    }
    NP_DBG("compatsvc: app %u prefix state %s", appid, json);
    return answer_json(response, appid, json);
}

// Runs argv with nothing of Steam's environment, so neither the insert nor Steam's own
// variables reach the child. Waits for it, which is short for everything started here.
static int run_detached(char *const argv[]) {
    const char *home = np_home_dir();
    char env_home[PATH_MAX + 8], env_tmp[PATH_MAX + 8];
    snprintf(env_home, sizeof env_home, "HOME=%s", home ? home : "/");
    snprintf(env_tmp, sizeof env_tmp, "TMPDIR=%s", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    char *envp[] = { env_home, env_tmp, "PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL };

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    if (posix_spawn_file_actions_init(&actions) != 0) return 0;
    if (posix_spawnattr_init(&attr) != 0) {
        posix_spawn_file_actions_destroy(&actions);
        return 0;
    }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawnattr_setsigmask(&attr, &none);
    posix_spawnattr_setsigdefault(&attr, &all);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF |
                                    POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);
    pid_t pid;
    int rc = posix_spawn(&pid, argv[0], &actions, &attr, argv, envp);
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    if (rc != 0) {
        NP_WARN("compatsvc: cannot run %s (%d)", argv[0], rc);
        return 0;
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

// The shell backgrounds the app and exits, so the rebuild belongs to launchd and outlives
// both the page and Steam.
#define REBUILD_SCRIPT \
    "log=$1; shift; \"$0\" --rebuild-prefix \"$@\" >> \"$log\" 2>&1 < /dev/null &"

// Any SteamUI page can call these routes, so a route never discards the original prefix:
// saves outside drive_c/users (registry, game folder) would go with it.
static int start_rebuild(uintptr_t request, uintptr_t response) {
    uint32_t appid = request_appid(request);
    np_prefix_state_t st;
    if (!read_state(appid, &st)) return RESULT_FAIL;

    const char *refused = !st.needs_rebuild ? "none"
                        : np_prefix_rebuilding(&st) ? "busy"
                        : st.running ? "running"
                        : !st.app[0] ? "app" : NULL;
    if (!refused) {
        char status[PATH_MAX], log[PATH_MAX], lock_path[PATH_MAX];
        snprintf(lock_path, sizeof lock_path, "%s/.notproton-rebuild.lock", st.compatdata);
        int claim = open(lock_path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
        // A page polling the state holds this for a moment to see whether a rebuild runs.
        int claimed = claim >= 0 && flock(claim, LOCK_EX | LOCK_NB) == 0;
        for (int i = 0; claim >= 0 && !claimed && errno == EWOULDBLOCK && i < 10; i++) {
            usleep(10000);
            claimed = flock(claim, LOCK_EX | LOCK_NB) == 0;
        }
        if (!claimed) {
            if (claim >= 0) close(claim);
            return answer_json(response, appid, "{\"error\":\"busy\"}");
        }
        snprintf(status, sizeof status, "%s/notproton-rebuild", st.compatdata);
        snprintf(log, sizeof log, "%s/bridgeplay-run.log", st.compatdata);
        int fd = open(status, O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
        struct stat info;
        int recorded = fd >= 0 && fstat(fd, &info) == 0 && S_ISREG(info.st_mode)
            && ftruncate(fd, 0) == 0 && write(fd, "setup\n0\n", 8) == 8;
        if (fd >= 0) close(fd);
        char *argv[] = { "/bin/sh", "-c", REBUILD_SCRIPT, st.app, log, st.compatdata,
                         st.tool, st.tool_build, st.tool_flavor, "keep-backup", NULL };
        if (!recorded) {
            refused = "spawn";
        } else if (!run_detached(argv)) {
            unlink(status);
            refused = "spawn";
        }
        close(claim);
    }
    if (refused)
        NP_WARN("compatsvc: app %u was not rebuilt (%s)", appid, refused);
    else
        NP_LOG("compatsvc: rebuilding app %u for %s, keeping the original", appid, st.tool);

    char json[64];
    snprintf(json, sizeof json, refused ? "{\"error\":\"%s\"}" : "{\"started\":true}",
             refused ? refused : "");
    return answer_json(response, appid, json);
}

static int rebuild_prefix(uintptr_t request, uintptr_t response) {
    return start_rebuild(request, response);
}

static int backup_and_rebuild_prefix(uintptr_t request, uintptr_t response) {
    return start_rebuild(request, response);
}

static int open_prefix_log(uintptr_t request, uintptr_t response) {
    uint32_t appid = request_appid(request);
    np_prefix_state_t st;
    if (!read_state(appid, &st) || !st.compatdata[0]) return RESULT_FAIL;
    char log[PATH_MAX];
    snprintf(log, sizeof log, "%s/bridgeplay-run.log", st.compatdata);
    // open waits on LaunchServices, which is not something Steam's WebUI thread should do.
    char *argv[] = { "/bin/sh", "-c", "/usr/bin/open -t \"$0\" &", log, NULL };
    struct stat info;
    int opened = lstat(log, &info) == 0 && S_ISREG(info.st_mode)
        && access(log, R_OK) == 0 && run_detached(argv);
    return answer_json(response, appid, opened ? "{\"opened\":true}" : "{\"error\":\"log\"}");
}

// When this Steam process started: a change a game left before then was written under an
// earlier Steam session, maybe another account's, so it is not saved into this one's.
static time_t steam_started(void) {
    static time_t started;
    if (!started) {
        struct kinfo_proc info;
        size_t size = sizeof info;
        int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
        started = sysctl(mib, 4, &info, &size, NULL, 0) == 0 && size == sizeof info
            ? info.kp_proc.p_starttime.tv_sec : time(NULL);
    }
    return started;
}

// Polled by the page every couple of seconds; any appid in the request is ignored.
static int take_quick_settings(uintptr_t request, uintptr_t response) {
    (void)request;
    const char *home = np_home_dir();
    if (!home) return RESULT_FAIL;
    char dir[PATH_MAX], json[STATE_JSON_MAX];
    np_support_path(dir, sizeof dir, home, "quick-settings");
    int stale = 0;
    int apps = np_quick_settings_take(dir, steam_started(), json, sizeof json, &stale);
    if (stale > 0) NP_LOG("compatsvc: dropped %d quick settings change(s) left from an earlier Steam session", stale);
    if (apps < 0) return RESULT_FAIL;
    if (apps > 0) NP_LOG("compatsvc: quick settings from %d game(s): %s", apps, json);
    return answer_json(response, 0, json);
}

static uintptr_t g_state_changed;
static int g_routes = NP_COMPATSVC_UNTRIED;

void np_compatsvc_state_changed(void) {
    if (!g_state_changed) return;
    np_webui_notify(ROUTE_NOTIFY_STATE_CHANGED, g_state_changed);
}

void np_compatsvc_register(const struct mach_header_64 *mh, intptr_t slide,
                           uintptr_t text_base, size_t text_size) {
    // Every path below settles g_routes, so it doubles as the once-only guard. A registry
    // that is not up yet leaves it untried, which is what brings the next lookup back.
    if (g_routes != NP_COMPATSVC_UNTRIED || !np_webui_registry()) return;

    uintptr_t request  = np_rtti_vptr(mh, slide, text_base, text_size, TYPE_GET_REQUEST);
    uintptr_t response = np_rtti_vptr(mh, slide, text_base, text_size, TYPE_GET_RESPONSE);
    if (!request || !response) {
        // A fact about the build, not a fault: every client whose page specifies the tool
        // directly lands here. hook_webpatch owns the error, where the cost is known.
        g_routes = NP_COMPATSVC_ABSENT;
        NP_LOG("compatsvc: the client has no message types for %s",
               ROUTE_GET_COMPAT_TOOLS);
        return;
    }

    np_webui_register_route(ROUTE_GET_COMPAT_TOOLS, request, response, get_compat_tools);

    uintptr_t specify_request  = np_rtti_vptr(mh, slide, text_base, text_size,
                                              TYPE_SPECIFY_REQUEST);
    uintptr_t specify_response = np_rtti_vptr(mh, slide, text_base, text_size,
                                              TYPE_SPECIFY_RESPONSE);
    if (!specify_request || !specify_response) {
        // Half a CompatManager. Unlike the case above this is not a shape any client
        // ships: the list can be read and nothing can be set from it.
        g_routes = NP_COMPATSVC_ABSENT;
        NP_ERR("compatsvc: the client answers %s but has no message types for %s",
               ROUTE_GET_COMPAT_TOOLS, ROUTE_SPECIFY_COMPAT_TOOL);
        return;
    }

    np_webui_register_route(ROUTE_SPECIFY_COMPAT_TOOL, specify_request,
                            specify_response, specify_compat_tool);

    g_routes = NP_COMPATSVC_READY;

    if (!np_webui_register_route(ROUTE_PREFIX_STATE, request, response, prefix_state)
        || !np_webui_register_route(ROUTE_REBUILD, request, response, rebuild_prefix)
        || !np_webui_register_route(ROUTE_BACKUP_REBUILD, request, response,
                                    backup_and_rebuild_prefix)
        || !np_webui_register_route(ROUTE_OPEN_LOG, request, response, open_prefix_log))
        NP_WARN("compatsvc: the Compatibility page cannot rebuild prefixes");
    if (!np_webui_register_route(ROUTE_TAKE_QUICK_SETTINGS, request, response, take_quick_settings))
        NP_WARN("compatsvc: changes made in a game's quick settings stay with that session");

    uintptr_t notification = np_rtti_vptr(mh, slide, text_base, text_size,
                                          TYPE_STATE_CHANGED);
    g_state_changed = notification ? np_webui_new_message(notification) : 0;
    if (!g_state_changed)
        NP_WARN("compatsvc: the page will show a stale tool until it is reopened");
}

int np_compatsvc_routes(void) {
    return g_routes;
}
