// The compat service builds the protobuf replies the page draws its dropdown from.
// Including the unit reaches the two static handlers, and stubbing the compat layer below
// them sets up manager state without a live client. The reply bytes are decoded back here.
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>
#include <mach-o/loader.h>

// Stubs for the compat layer, set by each test before calling a handler. The check owns
// both sides, so what the handler includes and labels is under test, not the compat answers.

static uint8_t fake_manager[0x800];
static uint8_t fake_entries[8 * 0x200];
static int32_t stub_tool_shift;
static uint32_t stub_enabled_off_val;
static uint32_t stub_platforms_val;
static int stub_would_force_val;
static const char *stub_tool_for_app_name;
static const char *stub_chosen_tool_name;
static const char *stub_app_mapping_val;
static const char *stub_wildcard_val;
static void *stub_registered_tool_val;
static uint32_t last_map_appid;
static const char *last_map_tool;

void *np_compat_manager(void) { return fake_manager; }

uint32_t np_compat_tool_off(uint32_t ref) {
    if (ref < 0x58) return ref;
    return (uint32_t)((int32_t)ref + stub_tool_shift);
}

size_t np_compat_tool_stride(void) { return 0x130 + stub_tool_shift; }

uint32_t np_compat_enabled_off(void) { return stub_enabled_off_val; }

uint32_t np_compat_manager_tools_max(void) { return 40; }

uint32_t np_compat_valid_platforms(void *mgr, uint32_t appid) {
    (void)mgr; (void)appid;
    return stub_platforms_val;
}

bool np_compat_would_force(void *mgr, uint32_t appid) {
    (void)mgr; (void)appid;
    return stub_would_force_val;
}

static uint8_t stub_tool_for_app_entry[0x200];
void *np_compat_tool_for_app(void *mgr, uint32_t appid) {
    (void)mgr; (void)appid;
    if (!stub_tool_for_app_name) return NULL;
    memset(stub_tool_for_app_entry, 0, sizeof stub_tool_for_app_entry);
    *(const char **)(stub_tool_for_app_entry + 0x40) = stub_tool_for_app_name;
    return stub_tool_for_app_entry;
}

static uint8_t stub_chosen_entry[0x200];
void *np_compat_chosen_tool(void *mgr, uint32_t appid) {
    (void)mgr; (void)appid;
    if (!stub_chosen_tool_name) return NULL;
    memset(stub_chosen_entry, 0, sizeof stub_chosen_entry);
    *(const char **)(stub_chosen_entry + 0x40) = stub_chosen_tool_name;
    return stub_chosen_entry;
}

const char *np_compat_app_mapping(void *mgr, uint32_t appid) {
    (void)mgr; (void)appid;
    return stub_app_mapping_val;
}

const char *np_compat_wildcard_mapping(void *mgr, uint32_t appid) {
    (void)mgr; (void)appid;
    return stub_wildcard_val;
}

void *np_compat_registered_tool(void *mgr) {
    (void)mgr;
    return stub_registered_tool_val;
}

void np_compat_map_tool(void *mgr, uint32_t appid, const char *name) {
    (void)mgr;
    last_map_appid = appid;
    last_map_tool = name;
}

void np_compat_force_enable(void *mgr) { (void)mgr; }

const char *np_compat_tool_dir(void) { return "/fake/tool"; }
const char *np_compat_tool_commandline(void) { return "/fake/run %verb%"; }

// Stubs for the webui layer. np_webui_parse_into captures the protobuf bytes so the
// test can decode them.
static uint8_t captured_pb[8192];
static uint32_t captured_pb_len;
static int parse_into_ok = 1;

int np_webui_parse_into(uintptr_t message, const void *bytes, uint32_t len) {
    (void)message;
    if (len <= sizeof captured_pb) {
        memcpy(captured_pb, bytes, len);
        captured_pb_len = len;
    }
    return parse_into_ok;
}

uintptr_t np_webui_registry(void) { return 1; }

int np_webui_register_route(const char *name, uintptr_t req, uintptr_t resp,
                            int (*handler)(uintptr_t, uintptr_t)) {
    (void)name; (void)req; (void)resp; (void)handler;
    return 1;
}

int np_webui_notify(const char *name, uintptr_t message) {
    (void)name; (void)message;
    return 1;
}

uintptr_t np_webui_new_message(uintptr_t vptr) {
    (void)vptr;
    return 1;
}

// A client that does not carry a message type reads as a vptr of 0. Naming a substring
// here is how a test spells "this build has no such type".
static const char *stub_absent_type;

uintptr_t np_rtti_vptr(const struct mach_header_64 *mh, intptr_t slide,
                       uintptr_t text_base, size_t text_size, const char *name) {
    (void)mh; (void)slide; (void)text_base; (void)text_size;
    if (stub_absent_type && strstr(name, stub_absent_type))
        return 0;
    return 1;
}

// Log stubs.
int   np_log_level = -1;
FILE *np_log_file  = NULL;

int np_log_first_hit(const void *anchor, unsigned long tag) {
    (void)anchor; (void)tag;
    return 1;
}

// The prefix state has its own check, so here it is whatever the test sets.
#include "../feats/prefixstate.h"
#include <spawn.h>
#include <sys/wait.h>
const char *np_home_dir(void) { return "/home"; }
void np_support_path(char *buf, size_t bufsz, const char *home, const char *rel) {
    snprintf(buf, bufsz, "%s/Library/Application Support/bridgeplay%s%s", home,
             rel && rel[0] ? "/" : "", rel ? rel : "");
}
static np_prefix_state_t stub_state;
static int stub_rebuilding;
void np_prefix_state(uint32_t appid, const char *tool, const np_prefix_roots_t *roots,
                     np_prefix_state_t *st) {
    (void)appid; (void)roots;
    *st = stub_state;
    snprintf(st->tool, sizeof st->tool, "%s", tool ? tool : "");
}
int np_prefix_rebuilding(const np_prefix_state_t *st) { (void)st; return stub_rebuilding; }
int np_prefix_state_json(uint32_t appid, const np_prefix_state_t *st, char *out, size_t cap) {
    return snprintf(out, cap, "{\"appid\":%u,\"tool\":\"%s\"}", appid, st->tool);
}

// Spawns are recorded instead of run, so the routes that start processes are checked by
// what they would have started.
#define SPAWN_ARGS_MAX 16
static char spawned[SPAWN_ARGS_MAX][1024];
static int spawned_count;
static int spawn_result;
static int stub_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
                            const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    (void)path; (void)fa; (void)attr; (void)envp;
    spawned_count = 0;
    for (; argv[spawned_count] && spawned_count < SPAWN_ARGS_MAX; spawned_count++)
        snprintf(spawned[spawned_count], sizeof spawned[0], "%s", argv[spawned_count]);
    *pid = 4242;
    return spawn_result;
}
static pid_t stub_waitpid(pid_t pid, int *status, int options) {
    (void)options;
    *status = 0;
    return pid;
}
#define posix_spawn stub_posix_spawn
#define waitpid stub_waitpid

#include "../feats/quicksettings.c"
#include "../feats/compatsvc.c"

// Minimal protobuf decoder for the captured reply. Enough to find field values.
typedef struct {
    const uint8_t *p;
    const uint8_t *end;
} pb_reader_t;

static uint64_t pb_read_varint(pb_reader_t *r) {
    uint64_t val = 0;
    int shift = 0;
    while (r->p < r->end) {
        uint8_t b = *r->p++;
        val |= (uint64_t)(b & 0x7f) << shift;
        if (!(b & 0x80)) break;
        shift += 7;
    }
    return val;
}

typedef struct {
    uint32_t field;
    uint32_t wire;
    const uint8_t *bytes;
    size_t len;
    uint64_t varint;
} pb_field_t;

static int pb_next(pb_reader_t *r, pb_field_t *f) {
    if (r->p >= r->end) return 0;
    uint64_t tag = pb_read_varint(r);
    f->field = (uint32_t)(tag >> 3);
    f->wire  = (uint32_t)(tag & 7);
    f->bytes = NULL;
    f->len   = 0;
    f->varint = 0;
    if (f->wire == 0) {
        f->varint = pb_read_varint(r);
    } else if (f->wire == 2) {
        f->len = (size_t)pb_read_varint(r);
        f->bytes = r->p;
        r->p += f->len;
    }
    return 1;
}

// Copy a string field into `dst` of size `dsz`, null-terminated. Returns 1 if found.
static int pb_copy_string(const uint8_t *buf, size_t len, uint32_t field_num,
                          char *dst, size_t dsz) {
    pb_reader_t r = { buf, buf + len };
    pb_field_t f;
    while (pb_next(&r, &f)) {
        if (f.field == field_num && f.wire == 2) {
            size_t n = f.len < dsz - 1 ? f.len : dsz - 1;
            memcpy(dst, f.bytes, n);
            dst[n] = '\0';
            return 1;
        }
    }
    return 0;
}

static int pb_find_bool(const uint8_t *buf, size_t len, uint32_t field_num) {
    pb_reader_t r = { buf, buf + len };
    pb_field_t f;
    while (pb_next(&r, &f)) {
        if (f.field == field_num && f.wire == 0)
            return (int)f.varint;
    }
    return -1;
}

// Count tools in the reply, and collect their names / flags.
#define MAX_TOOLS 16
typedef struct {
    char name[64];
    char display[64];
    int is_active;
    int is_incompatible;
} reply_tool_t;

typedef struct {
    int count;
    reply_tool_t tools[MAX_TOOLS];
    char selected[64];
    char fallback[64];
} reply_t;

static void decode_reply(reply_t *out) {
    memset(out, 0, sizeof *out);
    pb_reader_t r = { captured_pb, captured_pb + captured_pb_len };
    pb_field_t f;
    while (pb_next(&r, &f)) {
        if (f.field == RESP_TOOLS && f.wire == 2 && out->count < MAX_TOOLS) {
            reply_tool_t *t = &out->tools[out->count];
            pb_copy_string(f.bytes, f.len, TOOL_NAME, t->name, sizeof t->name);
            pb_copy_string(f.bytes, f.len, TOOL_DISPLAY_NAME, t->display, sizeof t->display);
            t->is_active = pb_find_bool(f.bytes, f.len, TOOL_IS_ACTIVE);
            t->is_incompatible = pb_find_bool(f.bytes, f.len, TOOL_IS_INCOMPATIBLE);
            out->count++;
        } else if (f.field == RESP_SELECTED && f.wire == 2) {
            size_t l = f.len; if (l >= sizeof out->selected) l = sizeof out->selected - 1;
            memcpy(out->selected, f.bytes, l);
            out->selected[l] = '\0';
        } else if (f.field == RESP_DEFAULT && f.wire == 2) {
            size_t l = f.len; if (l >= sizeof out->fallback) l = sizeof out->fallback - 1;
            memcpy(out->fallback, f.bytes, l);
            out->fallback[l] = '\0';
        }
    }
}

static int failures;

static void check(int ok, const char *what) {
    if (!ok) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

// Reset all stubs to a clean state.
static void reset(void) {
    memset(fake_manager, 0, sizeof fake_manager);
    memset(fake_entries, 0, sizeof fake_entries);
    stub_tool_shift = 0;
    stub_enabled_off_val = 0x7B0;
    stub_platforms_val = COMPAT_PLATFORM_WINDOWS;
    stub_would_force_val = 1;
    stub_tool_for_app_name = NULL;
    stub_chosen_tool_name = NULL;
    stub_app_mapping_val = NULL;
    stub_wildcard_val = NULL;
    stub_registered_tool_val = NULL;
    last_map_appid = 0;
    last_map_tool = NULL;
    parse_into_ok = 1;
    captured_pb_len = 0;
    memset(captured_pb, 0, sizeof captured_pb);
}

// Build a fake manager with `count` tools, each carrying platform, priority, name, display
// and gate flags at the matching COMPAT_TOOL_*_OFF offsets.
typedef struct {
    const char *name;
    const char *display;
    uint32_t platform;
    int32_t priority;
    uint32_t gate_flags;
    uint32_t appid;
} tool_spec_t;

static void build_tools(const tool_spec_t *specs, int count) {
    size_t stride = np_compat_tool_stride();
    *(uint8_t **)(fake_manager + COMPAT_MANAGER_TOOL_ARRAY_OFF) = fake_entries;
    *(uint32_t *)(fake_manager + COMPAT_MANAGER_TOOL_COUNT_OFF) = (uint32_t)count;
    memset(fake_entries, 0, sizeof fake_entries);
    for (int i = 0; i < count; i++) {
        uint8_t *e = fake_entries + (size_t)i * stride;
        *(const char **)(e + COMPAT_TOOL_NAME_OFF) = specs[i].name;
        *(const char **)(e + COMPAT_TOOL_DISPLAY_OFF) = specs[i].display;
        *(uint32_t *)(e + np_compat_tool_off(COMPAT_TOOL_PLATFORM_OFF)) = specs[i].platform;
        *(int32_t *)(e + COMPAT_TOOL_PRIORITY_OFF) = specs[i].priority;
        *(uint32_t *)(e + COMPAT_TOOL_GATE_FLAGS_OFF) = specs[i].gate_flags;
        *(uint32_t *)(e + np_compat_tool_off(COMPAT_TOOL_APPID_OFF)) = specs[i].appid;
    }
}

// Build a request buffer with the given has-bits and appid.
static uint8_t request_buf[128];

static uintptr_t build_request(uint32_t has_bits, uint32_t appid) {
    memset(request_buf, 0, sizeof request_buf);
    *(uint32_t *)(request_buf + REQ_HAS_BITS_OFF) = has_bits;
    *(uint32_t *)(request_buf + REQ_APPID_OFF) = appid;
    return (uintptr_t)request_buf;
}

// string_field reads a pointer at `field`, clears the arena tag, then inspects byte 23 of
// the struct it reaches: negative means long form (first qword is a char *), non-negative
// means short form (the bytes are the characters). Long form here, tool names are allocated.
static uint8_t specify_string_struct[24];

static uintptr_t build_specify_request(uint32_t has_bits, uint32_t appid,
                                       const char *tool_name) {
    memset(request_buf, 0, sizeof request_buf);
    *(uint32_t *)(request_buf + REQ_HAS_BITS_OFF) = has_bits;
    *(uint32_t *)(request_buf + SPECIFY_APPID_OFF) = appid;
    memset(specify_string_struct, 0, sizeof specify_string_struct);
    *(const char **)specify_string_struct = tool_name ? tool_name : "";
    specify_string_struct[23] = 0xFF;
    *(uintptr_t *)(request_buf + SPECIFY_TOOL_NAME_OFF) = (uintptr_t)specify_string_struct;
    return (uintptr_t)request_buf;
}

// The response is not read by the handler, only passed to np_webui_parse_into.
static uint8_t response_buf[64];

static void offered_cases(void) {
    reset();
    tool_spec_t tools[] = {
        { "crossover", "CrossOver", COMPAT_PLATFORM_WINDOWS, 100, 0, 0 },
    };
    build_tools(tools, 1);
    stub_platforms_val = COMPAT_PLATFORM_WINDOWS;

    int rc = get_compat_tools(build_request(REQ_HAS_APPID, 7), (uintptr_t)response_buf);
    check(rc == RESULT_OK, "a windows-only app is answered");
    reply_t r;
    decode_reply(&r);
    check(r.count == 1, "one tool that converts from windows is offered");
    check(strcmp(r.tools[0].name, "crossover") == 0, "the offered tool is the one that converts from windows");

    // A tool that converts from linux is not offered to a windows-only app.
    reset();
    tool_spec_t linux_tool[] = {
        { "proton", "Proton", 0x10, 100, 0, 0 },
    };
    build_tools(linux_tool, 1);
    stub_platforms_val = COMPAT_PLATFORM_WINDOWS;
    rc = get_compat_tools(build_request(REQ_HAS_APPID, 7), (uintptr_t)response_buf);
    check(rc == RESULT_OK, "a tool for the wrong platform is answered without error");
    decode_reply(&r);
    check(r.count == 0, "a tool converting from a platform the app does not ship for is not offered");
}

static void hidden_cases(void) {
    reset();
    tool_spec_t tools[] = {
        { "crossover", "CrossOver", COMPAT_PLATFORM_WINDOWS, 100, COMPAT_TOOL_GATE_HIDDEN, 0 },
    };
    build_tools(tools, 1);
    stub_platforms_val = COMPAT_PLATFORM_WINDOWS;

    // The bypass byte sits at enabled_off + 2 in the manager.
    fake_manager[stub_enabled_off_val + 2] = 0;

    int rc = get_compat_tools(build_request(REQ_HAS_APPID, 7), (uintptr_t)response_buf);
    reply_t r;
    decode_reply(&r);
    check(r.count == 0, "a hidden tool is not offered when the bypass is off");

    fake_manager[stub_enabled_off_val + 2] = 1;
    rc = get_compat_tools(build_request(REQ_HAS_APPID, 7), (uintptr_t)response_buf);
    (void)rc;
    decode_reply(&r);
    check(r.count == 1, "a hidden tool is offered when the bypass is on");
}

static void is_a_tool_cases(void) {
    reset();
    tool_spec_t tools[] = {
        { "crossover", "CrossOver", COMPAT_PLATFORM_WINDOWS, 100, 0, 730 },
    };
    build_tools(tools, 1);
    stub_platforms_val = COMPAT_PLATFORM_WINDOWS;
    fake_manager[stub_enabled_off_val + 2] = 0;

    int rc = get_compat_tools(build_request(REQ_HAS_APPID, 730), (uintptr_t)response_buf);
    check(rc == RESULT_IS_A_TOOL, "a tool asked about its own appid is refused rather than listed");

    // The is-a-tool check is bypassed when compatibility is switched off.
    fake_manager[stub_enabled_off_val + 2] = 1;
    rc = get_compat_tools(build_request(REQ_HAS_APPID, 730), (uintptr_t)response_buf);
    check(rc == RESULT_OK, "the is-a-tool check is skipped when the bypass is on");
}

static void none_entry_cases(void) {
    reset();
    tool_spec_t tools[] = {
        { "crossover", "CrossOver", COMPAT_PLATFORM_WINDOWS, 100, 0, 0 },
    };
    build_tools(tools, 1);
    stub_platforms_val = COMPAT_PLATFORM_WINDOWS;

    // No fallback, no existing "none" mapping: the none entry does not appear.
    stub_wildcard_val = NULL;
    stub_would_force_val = 0;
    stub_registered_tool_val = NULL;
    stub_app_mapping_val = NULL;

    int rc = get_compat_tools(build_request(REQ_HAS_APPID, 7), (uintptr_t)response_buf);
    (void)rc;
    reply_t r;
    decode_reply(&r);
    int has_none = 0;
    for (int i = 0; i < r.count; i++)
        if (strcmp(r.tools[i].name, NP_COMPAT_TOOL_NONE) == 0) has_none = 1;
    check(!has_none, "the none entry is absent when neither fallback nor mapping names it");

    // A wildcard mapping creates a fallback, so the none entry appears.
    stub_wildcard_val = "crossover";
    rc = get_compat_tools(build_request(REQ_HAS_APPID, 7), (uintptr_t)response_buf);
    decode_reply(&r);
    has_none = 0;
    for (int i = 0; i < r.count; i++)
        if (strcmp(r.tools[i].name, NP_COMPAT_TOOL_NONE) == 0) has_none = 1;
    check(has_none, "the none entry appears when a wildcard mapping creates a fallback");

    // An app already holding the none name keeps the entry.
    stub_wildcard_val = NULL;
    stub_app_mapping_val = NP_COMPAT_TOOL_NONE;
    rc = get_compat_tools(build_request(REQ_HAS_APPID, 7), (uintptr_t)response_buf);
    decode_reply(&r);
    has_none = 0;
    for (int i = 0; i < r.count; i++)
        if (strcmp(r.tools[i].name, NP_COMPAT_TOOL_NONE) == 0) has_none = 1;
    check(has_none, "the none entry appears when the app already holds it");

    // The pre-3.0 none name is still the none choice, shown as selected.
    stub_app_mapping_val = NP_COMPAT_TOOL_NONE_LEGACY;
    rc = get_compat_tools(build_request(REQ_HAS_APPID, 7), (uintptr_t)response_buf);
    decode_reply(&r);
    has_none = 0;
    for (int i = 0; i < r.count; i++)
        if (strcmp(r.tools[i].name, NP_COMPAT_TOOL_NONE) == 0 && r.tools[i].is_active) has_none = 1;
    check(has_none, "the legacy none name selects the none entry");
    stub_app_mapping_val = NULL;

    // The none entry never appears for the global scope (appid 0).
    stub_wildcard_val = "crossover";
    rc = get_compat_tools(build_request(0, 0), (uintptr_t)response_buf);
    decode_reply(&r);
    has_none = 0;
    for (int i = 0; i < r.count; i++)
        if (strcmp(r.tools[i].name, NP_COMPAT_TOOL_NONE) == 0) has_none = 1;
    check(!has_none, "the none entry is absent for the global setting");
}

static void priority_cases(void) {
    reset();
    tool_spec_t tools[] = {
        { "proton8", "Proton 8", COMPAT_PLATFORM_WINDOWS, 200, 0, 0 },
        { "proton7", "Proton 7", COMPAT_PLATFORM_WINDOWS, 150, 0, 0 },
        { "custom",  "Custom",   COMPAT_PLATFORM_WINDOWS,   0, 0, 0 },
    };
    build_tools(tools, 3);
    stub_platforms_val = COMPAT_PLATFORM_WINDOWS;

    int rc = get_compat_tools(build_request(REQ_HAS_APPID, 7), (uintptr_t)response_buf);
    (void)rc;
    reply_t r;
    decode_reply(&r);
    check(r.count == 3, "all three platform-matching tools are listed");

    // The best priority is 200. proton7 at 150 should be incompatible, custom at 0 should not.
    int p8_incompat = -1, p7_incompat = -1, custom_incompat = -1;
    for (int i = 0; i < r.count; i++) {
        if (strcmp(r.tools[i].name, "proton8") == 0) p8_incompat = r.tools[i].is_incompatible;
        if (strcmp(r.tools[i].name, "proton7") == 0) p7_incompat = r.tools[i].is_incompatible;
        if (strcmp(r.tools[i].name, "custom") == 0) custom_incompat = r.tools[i].is_incompatible;
    }
    check(p8_incompat == 0, "the tool with the best priority is not incompatible");
    check(p7_incompat == 1, "a tool below the best priority is incompatible");
    check(custom_incompat == 0, "a tool with priority zero opts out of ranking");
}

static void selected_cases(void) {
    reset();
    tool_spec_t tools[] = {
        { "crossover", "CrossOver", COMPAT_PLATFORM_WINDOWS, 100, 0, 0 },
    };
    build_tools(tools, 1);
    stub_platforms_val = COMPAT_PLATFORM_WINDOWS;

    // A per-app query with a mapping reports the mapping as the selection.
    stub_app_mapping_val = "crossover";
    stub_tool_for_app_name = "crossover";
    int rc = get_compat_tools(build_request(REQ_HAS_APPID, 7), (uintptr_t)response_buf);
    (void)rc;
    reply_t r;
    decode_reply(&r);
    check(strcmp(r.selected, "crossover") == 0, "a mapped app reports its mapping as the selection");

    // No mapping reports the empty string, which is the "no choice" state.
    stub_app_mapping_val = NULL;
    stub_tool_for_app_name = "crossover";
    rc = get_compat_tools(build_request(REQ_HAS_APPID, 7), (uintptr_t)response_buf);
    decode_reply(&r);
    check(strcmp(r.selected, "") == 0, "an unmapped app reports the empty string as the selection");

    // The global query reads the chosen tool rather than the mapping.
    stub_chosen_tool_name = "crossover";
    rc = get_compat_tools(build_request(0, 0), (uintptr_t)response_buf);
    decode_reply(&r);
    check(strcmp(r.selected, "crossover") == 0, "the global setting reports the chosen tool");
}

static void fallback_cases(void) {
    reset();
    tool_spec_t tools[] = {
        { "crossover", "CrossOver", COMPAT_PLATFORM_WINDOWS, 100, 0, 0 },
    };
    build_tools(tools, 1);
    stub_platforms_val = COMPAT_PLATFORM_WINDOWS;

    // The wildcard names a fallback directly.
    stub_wildcard_val = "crossover";
    int rc = get_compat_tools(build_request(REQ_HAS_APPID, 7), (uintptr_t)response_buf);
    (void)rc;
    reply_t r;
    decode_reply(&r);
    check(strcmp(r.fallback, "crossover") == 0, "the wildcard mapping names the fallback");

    // No wildcard, but would_force + registered tool fills it in.
    stub_wildcard_val = NULL;
    stub_would_force_val = 1;
    stub_registered_tool_val = fake_entries;
    rc = get_compat_tools(build_request(REQ_HAS_APPID, 7), (uintptr_t)response_buf);
    decode_reply(&r);
    check(strcmp(r.fallback, "crossover") == 0,
          "a forced app with no wildcard falls back to the registered tool");

    // Global (appid 0) with no wildcard still falls back to the registered tool.
    stub_wildcard_val = NULL;
    stub_would_force_val = 0;
    stub_registered_tool_val = fake_entries;
    rc = get_compat_tools(build_request(0, 0), (uintptr_t)response_buf);
    decode_reply(&r);
    check(strcmp(r.fallback, "crossover") == 0,
          "the global setting with no wildcard falls back to the registered tool");

    // An app that would not be forced and has no wildcard gets no fallback.
    stub_wildcard_val = NULL;
    stub_would_force_val = 0;
    stub_registered_tool_val = fake_entries;
    rc = get_compat_tools(build_request(REQ_HAS_APPID, 7), (uintptr_t)response_buf);
    decode_reply(&r);
    check(r.fallback[0] == '\0', "an unforced app with no wildcard gets no fallback");
}

static void active_flag_cases(void) {
    reset();
    tool_spec_t tools[] = {
        { "crossover", "CrossOver", COMPAT_PLATFORM_WINDOWS, 100, 0, 0 },
        { "proton",    "Proton",    COMPAT_PLATFORM_WINDOWS, 200, 0, 0 },
    };
    build_tools(tools, 2);
    stub_platforms_val = COMPAT_PLATFORM_WINDOWS;
    stub_tool_for_app_name = "crossover";

    int rc = get_compat_tools(build_request(REQ_HAS_APPID, 7), (uintptr_t)response_buf);
    (void)rc;
    reply_t r;
    decode_reply(&r);
    int cx_active = -1, pt_active = -1;
    for (int i = 0; i < r.count; i++) {
        if (strcmp(r.tools[i].name, "crossover") == 0) cx_active = r.tools[i].is_active;
        if (strcmp(r.tools[i].name, "proton") == 0)    pt_active = r.tools[i].is_active;
    }
    check(cx_active == 1, "the tool the app runs under is flagged active");
    check(pt_active == 0, "a tool the app does not run under is not active");
}

static void specify_cases(void) {
    reset();

    // A request with appid and tool name maps the tool.
    last_map_appid = 0;
    last_map_tool = NULL;
    int rc = specify_compat_tool(
        build_specify_request(SPECIFY_HAS_APPID, 42, "crossover"),
        (uintptr_t)response_buf);
    check(rc == RESULT_OK, "a specify with a tool name succeeds");
    check(last_map_appid == 42, "the appid from the request reaches the mapping");
    check(last_map_tool && strcmp(last_map_tool, "crossover") == 0,
          "the tool name from the request reaches the mapping");

    // A request with no appid has-bit maps as appid zero (the global).
    last_map_appid = 99;
    rc = specify_compat_tool(
        build_specify_request(0, 42, "crossover"),
        (uintptr_t)response_buf);
    check(rc == RESULT_OK, "a specify with no appid has-bit succeeds");
    check(last_map_appid == 0, "a request with no appid has-bit reads as appid zero");
}

static void no_manager_cases(void) {
    // When np_compat_manager returns NULL the handlers must cope.
    reset();
    parse_into_ok = 0;
    tool_spec_t tools[] = {
        { "crossover", "CrossOver", COMPAT_PLATFORM_WINDOWS, 100, 0, 0 },
    };
    build_tools(tools, 1);
    stub_platforms_val = COMPAT_PLATFORM_WINDOWS;
    int rc = get_compat_tools(build_request(REQ_HAS_APPID, 7), (uintptr_t)response_buf);
    check(rc == RESULT_FAIL, "a rejected parse_into fails the whole reply");
    parse_into_ok = 1;
}

// hook_webpatch reads these to decide whether an absent service matters, so untried has to
// stay apart from absent: folding them puts an error on a launch where nothing is wrong.
static void routes_state_cases(void) {
    g_routes = NP_COMPATSVC_UNTRIED;
    stub_absent_type = NULL;
    check(np_compatsvc_routes() == NP_COMPATSVC_UNTRIED,
          "no route lookup yet reads as untried rather than absent");

    np_compatsvc_register(NULL, 0, 0, 0);
    check(np_compatsvc_routes() == NP_COMPATSVC_READY,
          "a client carrying every message type registers and reads as ready");

    // The stable client: the page specifies the tool directly and the build carries no
    // CompatManager types at all.
    g_routes = NP_COMPATSVC_UNTRIED;
    stub_absent_type = "CCompatManager_GetCompatTools";
    np_compatsvc_register(NULL, 0, 0, 0);
    check(np_compatsvc_routes() == NP_COMPATSVC_ABSENT,
          "a client with no GetCompatTools types reads as absent");

    // Half a CompatManager, which is the shape that stays an error.
    g_routes = NP_COMPATSVC_UNTRIED;
    stub_absent_type = "CCompatManager_SpecifyCompatTool";
    np_compatsvc_register(NULL, 0, 0, 0);
    check(np_compatsvc_routes() == NP_COMPATSVC_ABSENT,
          "a client that can list but not specify reads as absent");

    // Settled state is also the once-only guard, so a second lookup is not a second
    // registration that could overwrite what the first one found.
    stub_absent_type = NULL;
    np_compatsvc_register(NULL, 0, 0, 0);
    check(np_compatsvc_routes() == NP_COMPATSVC_ABSENT,
          "a later route lookup does not re-register over a settled answer");

    g_routes = NP_COMPATSVC_UNTRIED;
    stub_absent_type = NULL;
}

static char scratch[PATH_MAX];

static const char *answer(void) {
    static char json[256];
    json[0] = '\0';
    pb_copy_string(captured_pb, captured_pb_len, RESP_DEFAULT, json, sizeof json);
    return json;
}

static int exists(const char *name) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", scratch, name);
    return access(path, F_OK) == 0;
}

static void put(const char *name, const char *text) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", scratch, name);
    FILE *f = fopen(path, "w");
    fputs(text, f);
    fclose(f);
}

static void ready_to_rebuild(void) {
    reset();
    memset(&stub_state, 0, sizeof stub_state);
    stub_rebuilding = 0;
    spawned_count = 0;
    spawn_result = 0;
    stub_state.has_prefix = 1;
    stub_state.needs_rebuild = 1;
    snprintf(stub_state.compatdata, sizeof stub_state.compatdata, "%s", scratch);
    snprintf(stub_state.tool_build, sizeof stub_state.tool_build, "27.0.0.41073-fex");
    snprintf(stub_state.tool_flavor, sizeof stub_state.tool_flavor, "fex");
    snprintf(stub_state.app, sizeof stub_state.app, "/Applications/NotProton.app/Contents/MacOS/NotProtonApp");
    stub_tool_for_app_name = "notproton-fex-41073";
    char status[PATH_MAX];
    snprintf(status, sizeof status, "%s/notproton-rebuild", scratch);
    unlink(status);
}

// Any page can call these, and two of them start the app, so each refusal is checked.
static void rebuild_route_cases(void) {
    snprintf(scratch, sizeof scratch, "%s/compatsvc.XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    if (!mkdtemp(scratch)) { check(0, "a scratch compatdata exists"); return; }

    struct { const char *why; void (*set)(void); const char *want; } refusals[] = {
        { "a prefix that needs no rebuild is not rebuilt", NULL, "{\"error\":\"none\"}" },
        { "a rebuild already under way is not started twice", NULL, "{\"error\":\"busy\"}" },
        { "a running game is not rebuilt under it", NULL, "{\"error\":\"running\"}" },
        { "a missing app is reported, not started", NULL, "{\"error\":\"app\"}" },
    };
    for (int i = 0; i < 4; i++) {
        ready_to_rebuild();
        if (i == 0) stub_state.needs_rebuild = 0;
        if (i == 1) stub_rebuilding = 1;
        if (i == 2) stub_state.running = 1;
        if (i == 3) stub_state.app[0] = '\0';
        int rc = rebuild_prefix(build_request(REQ_HAS_APPID, 480), (uintptr_t)response_buf);
        check(rc == RESULT_OK && strcmp(answer(), refusals[i].want) == 0, refusals[i].why);
        check(spawned_count == 0, "a refused rebuild starts nothing");
        check(!exists("notproton-rebuild"), "a refused rebuild writes no progress");
    }

    ready_to_rebuild();
    int rc = backup_and_rebuild_prefix(build_request(REQ_HAS_APPID, 480), (uintptr_t)response_buf);
    check(rc == RESULT_OK && strcmp(answer(), "{\"started\":true}") == 0, "a rebuild starts");
    char log[PATH_MAX];
    snprintf(log, sizeof log, "%s/bridgeplay-run.log", scratch);
    const char *want[] = { "/bin/sh", "-c", REBUILD_SCRIPT, stub_state.app, log, scratch,
                           "notproton-fex-41073", "27.0.0.41073-fex", "fex", "keep-backup" };
    int same = spawned_count == 10;
    for (int i = 0; same && i < 10; i++) same = strcmp(spawned[i], want[i]) == 0;
    check(same, "the app gets the prefix, the tool Steam would run, and the backup choice");
    check(exists("notproton-rebuild"), "a started rebuild reads as under way before the app reports");

    ready_to_rebuild();
    char status_path[PATH_MAX], victim[PATH_MAX], lock_path[PATH_MAX];
    snprintf(status_path, sizeof status_path, "%s/notproton-rebuild", scratch);
    snprintf(victim, sizeof victim, "%s/keep", scratch);
    snprintf(lock_path, sizeof lock_path, "%s/.notproton-rebuild.lock", scratch);
    put("keep", "untouched");
    symlink(victim, status_path);
    rebuild_prefix(build_request(REQ_HAS_APPID, 480), (uintptr_t)response_buf);
    struct stat info;
    check(spawned_count == 0 && stat(victim, &info) == 0 && info.st_size == 9,
          "a symlinked status neither truncates its target nor starts a rebuild");
    ready_to_rebuild();
    int claim = open(lock_path, O_RDWR);
    if (claim < 0 || flock(claim, LOCK_EX | LOCK_NB) != 0) abort();
    put("notproton-rebuild", "copy\n4242\n");
    rebuild_prefix(build_request(REQ_HAS_APPID, 480), (uintptr_t)response_buf);
    check(spawned_count == 0 && strcmp(answer(), "{\"error\":\"busy\"}") == 0,
          "the actual rebuild lock refuses a launch even when the state snapshot is stale");
    close(claim);

    ready_to_rebuild();
    rebuild_prefix(build_request(REQ_HAS_APPID, 480), (uintptr_t)response_buf);
    check(spawned_count == 10 && strcmp(spawned[9], "keep-backup") == 0,
          "a plain rebuild from a page still keeps the original");

    ready_to_rebuild();
    spawn_result = 1;
    rebuild_prefix(build_request(REQ_HAS_APPID, 480), (uintptr_t)response_buf);
    check(strcmp(answer(), "{\"error\":\"spawn\"}") == 0, "a rebuild that cannot start says so");
    check(!exists("notproton-rebuild"), "a rebuild that cannot start leaves no progress behind");

    ready_to_rebuild();
    rc = rebuild_prefix(build_request(0, 0), (uintptr_t)response_buf);
    check(rc == RESULT_FAIL && spawned_count == 0, "a request with no appid starts nothing");

    ready_to_rebuild();
    open_prefix_log(build_request(REQ_HAS_APPID, 480), (uintptr_t)response_buf);
    check(strcmp(answer(), "{\"error\":\"log\"}") == 0 && spawned_count == 0,
          "a missing log is not opened");
    put("bridgeplay-run.log", "x\n");
    open_prefix_log(build_request(REQ_HAS_APPID, 480), (uintptr_t)response_buf);
    check(strcmp(answer(), "{\"opened\":true}") == 0 && spawned_count == 4
          && strcmp(spawned[0], "/bin/sh") == 0 && strcmp(spawned[3], log) == 0
          && strcmp(spawned[2], "/usr/bin/open -t \"$0\" &") == 0,
          "the log opens in the background, so Steam does not wait on LaunchServices");
    unlink(log);
    symlink(victim, log);
    spawned_count = 0;
    open_prefix_log(build_request(REQ_HAS_APPID, 480), (uintptr_t)response_buf);
    check(spawned_count == 0, "a symlinked log is not opened");

    ready_to_rebuild();
    put("notproton-rebuild", "done\n1\n");
    prefix_state(build_request(REQ_HAS_APPID, 480), (uintptr_t)response_buf);
    check(exists("notproton-rebuild"), "a finished rebuild remains available to other pages");
    put("notproton-rebuild", "copy\n1\n");
    stub_rebuilding = 1;
    prefix_state(build_request(REQ_HAS_APPID, 480), (uintptr_t)response_buf);
    check(exists("notproton-rebuild"), "a rebuild under way keeps its progress");

    char cmd[PATH_MAX + 16];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", scratch);
    if (system(cmd) != 0) fprintf(stderr, "could not remove %s\n", scratch);
}

static void string_field_cases(void) {
    // string_field reads an arena-tagged pointer. Low bit set = arena, cleared before
    // deref. A long string (byte[23] < 0) dereferences the first qword as a pointer to
    // the characters. A short string (byte[23] >= 0) reads the characters inline.
    static uint8_t short_str[24];
    memcpy(short_str, "hello world", 11);
    short_str[23] = 11;
    uintptr_t ptr = (uintptr_t)short_str;

    // Build a request whose tool name field points at this.
    memset(request_buf, 0, sizeof request_buf);
    *(uintptr_t *)(request_buf + SPECIFY_TOOL_NAME_OFF) = ptr;
    const char *result = string_field((uintptr_t)(request_buf + SPECIFY_TOOL_NAME_OFF));
    check(result != NULL, "a short string is read");
    check(result == (const char *)short_str, "a short string reads inline from the struct");

    // A long string: byte[23] negative, first qword is a pointer.
    static char long_chars[] = "this is a longer string value";
    static uint8_t long_str[24];
    *(const char **)long_str = long_chars;
    long_str[23] = (uint8_t)0xFF;
    ptr = (uintptr_t)long_str;
    *(uintptr_t *)(request_buf + SPECIFY_TOOL_NAME_OFF) = ptr;
    result = string_field((uintptr_t)(request_buf + SPECIFY_TOOL_NAME_OFF));
    check(result != NULL && strcmp(result, long_chars) == 0,
          "a long string dereferences the first qword as the character pointer");

    // Arena-tagged pointer (low bit set).
    *(uintptr_t *)(request_buf + SPECIFY_TOOL_NAME_OFF) = ptr | 1;
    result = string_field((uintptr_t)(request_buf + SPECIFY_TOOL_NAME_OFF));
    check(result != NULL && strcmp(result, long_chars) == 0,
          "the arena tag in the low bit is cleared before the deref");

    // NULL string returns empty.
    *(uintptr_t *)(request_buf + SPECIFY_TOOL_NAME_OFF) = 0;
    result = string_field((uintptr_t)(request_buf + SPECIFY_TOOL_NAME_OFF));
    check(result != NULL && result[0] == '\0', "a null string field returns empty");
}

int main(void) {
    offered_cases();
    hidden_cases();
    is_a_tool_cases();
    none_entry_cases();
    priority_cases();
    selected_cases();
    fallback_cases();
    active_flag_cases();
    specify_cases();
    no_manager_cases();
    routes_state_cases();
    string_field_cases();
    rebuild_route_cases();

    if (failures) {
        printf("==> compatsvc: %d check(s) failed\n", failures);
        return 1;
    }
    printf("==> compatsvc: the tool list, the none entry, the priorities, the specify "
           "handler, the route states and the rebuild routes all answer\n");
    return 0;
}
