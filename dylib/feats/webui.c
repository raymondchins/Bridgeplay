// WebUI route registration for routes the macOS client does not serve.
// Needed since the October 13th 2026 Steam client update (1791918634), which has a new UI.
#include "webui.h"
#include "../core/macho.h"
#include "../util/log.h"
#include "../util/ptr.h"

#include <stdlib.h>
#include <string.h>

static inline int32_t sign_extend(uint32_t val, int bits) {
    if (val & (1u << (bits - 1))) val -= (1u << bits);
    return (int32_t)val;
}

#define ACCESSOR_LOOKBACK 12

#define MIN_SITES 4

#define FN_SPAN_MAX 0x400

#define VT_SLOTS 24

#define VT_RUN_MIN 8

#define MAX_ROUTES 8

#define REGISTRY_MAP_OFF   96
#define MAP_ELEMENTS_OFF   48
#define MAP_BOUND_OFF      72
#define ROUTE_STRIDE       48

#define REGISTRY_BROADCASTER_OFF 24
#define BROADCAST_TASK_NAME "ThreadedBroadcastNotification"

#define MSG_NEW_OFF 24

#define ELEM_DESCRIPTOR_OFF 8
#define ELEM_FLAGS_OFF      16

#define DESC_NAME      0
#define DESC_CONSTANT  1
#define DESC_FACTORY   2
#define DESC_QWORDS    7

#define DESC_CONSTANT_VALUE 0xFFFFFFFD00000000ULL

#define RESULT_FAIL 2

typedef uintptr_t (*np_registry_accessor_fn)(void);
typedef uintptr_t (*np_msg_new_fn)(void);
typedef int (*np_notify_fn)(uintptr_t transport, const char *name, uintptr_t message);
typedef int (*np_parse_fn)(uintptr_t message, const void *bytes, uint32_t len);
typedef uintptr_t (*np_job_factory_fn)(uintptr_t dispatcher, uintptr_t arg);
typedef void      (*np_send_response_fn)(uintptr_t job, uintptr_t ctx);
typedef int       (*np_register_fn)(uintptr_t registry, void *record);

// Routes can share request types, so each gets its own job vtable and the job's
// vptr says which route it belongs to.
typedef struct {
    uintptr_t           descriptor[DESC_QWORDS];
    np_webui_handler_fn handler;
    uintptr_t           vtable[2 + VT_SLOTS];
} np_route_t;

static uintptr_t g_registry;
static uintptr_t g_register_fn;
static uintptr_t g_send_response;
static uintptr_t g_parse;
static uintptr_t g_text_base, g_text_end;
static uintptr_t g_const_base, g_const_end;
static uintptr_t g_text_seg_base;
static size_t    g_text_seg_size;

// A slot of 0 is a real slot
static int g_notify_slot = -1;

static np_route_t g_routes[MAX_ROUTES];
static int        g_route_count;

static uintptr_t g_stock_factory;
static uintptr_t g_clone[2 + VT_SLOTS];
static size_t    g_clone_words;
static uintptr_t g_route_flags;

static int bl_target(uint32_t insn, uintptr_t pc, uintptr_t *out) {
    if ((insn & 0xFC000000) != 0x94000000) return 0;
    int32_t imm = sign_extend(insn & 0x03FFFFFF, 26);
    *out = pc + 4 * (intptr_t)imm;
    return 1;
}

static int in_text(uintptr_t va) {
    return g_text_base && va >= g_text_base && va < g_text_end && (va & 3) == 0;
}

static uintptr_t adrp_add_target(uintptr_t pc, uint32_t first, uint32_t second) {
    if ((first & 0x9F000000) != 0x90000000) return 0;

    int reg = (int)(first & 0x1F);
    int32_t imm = sign_extend(((first >> 5) & 0x7FFFF) << 2 | ((first >> 29) & 3), 21);
    uintptr_t page = (pc & ~(uintptr_t)0xFFF) + ((intptr_t)imm << 12);

    if ((second & 0xFF800000) != 0x91000000) return 0;
    if ((int)(second & 0x1F) != reg || (int)((second >> 5) & 0x1F) != reg) return 0;

    return page + ((second >> 10) & 0xFFF);
}

static uintptr_t find_accessor(uintptr_t register_fn, uintptr_t text_base,
                               size_t text_size, int *out_sites) {
    uintptr_t end = text_base + text_size;
    uintptr_t winner = 0;
    int agree = 0, disagree = 0, silent = 0;

    for (uintptr_t pc = text_base; pc + 4 <= end; pc += 4) {
        uintptr_t called;
        if (!bl_target(*(const uint32_t *)pc, pc, &called) || called != register_fn)
            continue;

        uintptr_t accessor = 0;
        for (int back = 1; back <= ACCESSOR_LOOKBACK; back++) {
            uintptr_t at = pc - 4 * back;
            if (at < text_base) break;
            if (bl_target(*(const uint32_t *)at, at, &accessor)) break;
        }
        if (!accessor) { silent++; continue; }

        if (!winner)                 { winner = accessor; agree = 1; }
        else if (accessor == winner) { agree++; }
        else                         { disagree++; }
    }

    if (disagree) {
        NP_ERR("webui: %d registration sites reach the registry through 0x%lx but %d "
               "use something else, so none of them can be trusted",
               agree, (unsigned long)winner, disagree);
        return 0;
    }
    if (agree < MIN_SITES) {
        NP_WARN("webui: %d registration site(s) name an accessor, %d name none; "
                "need %d that agree", agree, silent, MIN_SITES);
        return 0;
    }
    if (winner < text_base || winner >= end) {
        NP_ERR("webui: accessor 0x%lx sits outside the code it was read from",
               (unsigned long)winner);
        return 0;
    }

    if (silent)
        NP_DBG("webui: %d registration site(s) set up the registry outside the "
               "instructions this reads", silent);
    if (out_sites) *out_sites = agree;
    return winner;
}

// request-body parse
static uintptr_t find_parse(uintptr_t dispatch_fn) {
    uintptr_t found = 0;
    int hits = 0;

    for (uintptr_t pc = dispatch_fn; pc + 8 <= dispatch_fn + FN_SPAN_MAX; pc += 4) {
        uintptr_t called = 0;
        if (!bl_target(*(const uint32_t *)pc, pc, &called)) continue;
        // TBZ W0, #0, <label>
        if ((*(const uint32_t *)(pc + 4) & 0xFFF8001F) != 0x36000000) continue;
        found = called;
        hits++;
    }

    if (hits != 1) {
        NP_ERR("webui: the dispatcher tests %d of its calls a bit at a time, so "
               "none of them is certainly the parse", hits);
        return 0;
    }
    return found;
}

int np_webui_init(const struct mach_header_64 *mh, intptr_t slide,
                  uintptr_t register_fn, uintptr_t dispatch_fn,
                  uintptr_t send_response) {
    if (!mh || !register_fn || !dispatch_fn || !send_response) return 0;

    size_t text_size = 0;
    if (np_get_section_containing(mh, slide, register_fn, &g_text_base, &text_size) != 0) {
        NP_ERR("webui: the register function at 0x%lx belongs to no section",
               (unsigned long)register_fn);
        return 0;
    }
    g_text_end = g_text_base + text_size;

    uintptr_t const_base = 0;
    size_t    const_size = 0;
    if (np_find_segment(mh, slide, "__DATA_CONST", &const_base, &const_size) != 0) {
        NP_ERR("webui: the image has no __DATA_CONST, so no vtable can be trusted");
        return 0;
    }
    g_const_base = const_base;
    g_const_end  = const_base + const_size;

    // String literals are in in __TEXT
    if (np_find_segment(mh, slide, "__TEXT", &g_text_seg_base, &g_text_seg_size) != 0)
        NP_WARN("webui: the image has no __TEXT, so nothing can be told when the "
                "answer to a route stops holding");

    int sites = 0;
    uintptr_t accessor = find_accessor(register_fn, g_text_base, text_size, &sites);
    if (!accessor) return 0;

    uintptr_t registry = ((np_registry_accessor_fn)accessor)();
    if (!np_plausible_ptr(registry)) {
        NP_ERR("webui: accessor 0x%lx returned 0x%lx, which is no registry",
               (unsigned long)accessor, (unsigned long)registry);
        return 0;
    }

    g_registry      = registry;
    g_register_fn   = register_fn;
    g_send_response = send_response;
    g_parse         = find_parse(dispatch_fn);
    NP_LOG("webui: registry 0x%lx via accessor 0x%lx, agreed by %d of the client's "
           "own route registrations", (unsigned long)registry,
           (unsigned long)accessor, sites);
    return 1;
}

uintptr_t np_webui_registry(void) {
    return g_registry;
}

int np_webui_parse_into(uintptr_t message, const void *bytes, uint32_t len) {
    if (!g_parse || !message || !bytes) return 0;
    return (((np_parse_fn)g_parse)(message, bytes, len) & 1) ? 1 : 0;
}

uintptr_t np_webui_lookup_site(uintptr_t register_fn, uintptr_t dispatch_fn) {
    if (!register_fn || !dispatch_fn) return 0;

    uintptr_t lookup = 0;
    for (uintptr_t pc = register_fn; pc < register_fn + FN_SPAN_MAX; pc += 4)
        if (bl_target(*(const uint32_t *)pc, pc, &lookup)) break;

    if (!lookup) {
        NP_ERR("webui: the register function at 0x%lx calls nothing, so the route "
               "lookup has no name", (unsigned long)register_fn);
        return 0;
    }

    uintptr_t site = 0;
    int hits = 0;
    for (uintptr_t pc = dispatch_fn; pc < dispatch_fn + FN_SPAN_MAX; pc += 4) {
        uintptr_t called;
        if (bl_target(*(const uint32_t *)pc, pc, &called) && called == lookup) {
            site = pc;
            hits++;
        }
    }

    if (hits != 1) {
        NP_ERR("webui: the dispatcher at 0x%lx reaches the route lookup 0x%lx %d "
               "times, where one call is the whole basis for trusting it",
               (unsigned long)dispatch_fn, (unsigned long)lookup, hits);
        return 0;
    }

    NP_DBG("webui: route lookup 0x%lx called from 0x%lx",
           (unsigned long)lookup, (unsigned long)site);
    return site;
}

static const char *route_at(uintptr_t elements, int index) {
    uintptr_t slot = elements + (uintptr_t)index * ROUTE_STRIDE;
    uint64_t  name = *(const uint64_t *)slot;
    if (name < 0x100000000ULL || name >= 0x800000000000ULL) return NULL;

    const char *s = (const char *)(uintptr_t)name;
    for (int i = 0; i < 128; i++) {
        if (s[i] == '\0') return i ? s : NULL;
        if (s[i] < 0x20 || s[i] > 0x7e) return NULL;
    }
    return NULL;
}

static int walk_routes(uintptr_t *elements_out, int *bound_out) {
    if (!g_registry) return 0;

    uintptr_t map      = g_registry + REGISTRY_MAP_OFF;
    uintptr_t elements = *(const uintptr_t *)(map + MAP_ELEMENTS_OFF);
    int       bound    = *(const int32_t *)(map + MAP_BOUND_OFF);
    if (!np_plausible_ptr(elements) || bound <= 0 || bound > 4096) {
        NP_WARN("webui: route table at 0x%lx bound %d is not walkable",
                (unsigned long)elements, bound);
        return 0;
    }
    *elements_out = elements;
    *bound_out    = bound;
    return 1;
}

void np_webui_dump_routes(void) {
    uintptr_t elements;
    int bound;
    if (!getenv("NOTPROTON_WEBUI_ROUTES") || !walk_routes(&elements, &bound)) return;

    int named = 0;
    for (int i = 0; i < bound; i++) {
        const char *name = route_at(elements, i);
        if (!name) continue;
        named++;
        NP_LOG("webui: route[%d] %s", i, name);
    }
    NP_LOG("webui: %d of %d route slots named", named, bound);
}

// The target of a branch, with `cond` set when the branch is conditional
static uintptr_t branch_target(uint32_t insn, uintptr_t pc, int *cond) {
    int32_t imm;
    *cond = 0;

    if ((insn & 0xFC000000) == 0x14000000) {              // B
        imm = sign_extend(insn & 0x03FFFFFF, 26);
    } else if ((insn & 0xFF000010) == 0x54000000 ||       // B.cond
               (insn & 0x7F000000) == 0x34000000) {       // CBZ, CBNZ
        *cond = 1;
        imm = sign_extend((insn >> 5) & 0x7FFFF, 19);
    } else if ((insn & 0x7F000000) == 0x36000000) {       // TBZ, TBNZ
        *cond = 1;
        imm = sign_extend((insn >> 5) & 0x3FFF, 14);
    } else {
        return 0;
    }

    return pc + 4 * (intptr_t)imm;
}

// This was painful, WIP, don't change unless you are me
static int fn_calls(uintptr_t fn, uintptr_t target) {
    uintptr_t furthest = fn;

    for (uintptr_t pc = fn; pc < fn + FN_SPAN_MAX; pc += 4) {
        uint32_t insn = *(const uint32_t *)pc;

        uintptr_t called;
        if (bl_target(insn, pc, &called) && called == target) return 1;

        int cond = 0;
        uintptr_t branch = branch_target(insn, pc, &cond);
        if (branch) {
            if (!cond && pc >= furthest) break;
            if (branch > furthest) furthest = branch;
            continue;
        }

        int returns = insn == 0xD65F03C0 ||                   // RET
                      (insn & 0xFFFFFC1F) == 0xD61F0000;      // BR
        if (returns && pc >= furthest) break;
    }
    return 0;
}

static int vtable_run(uintptr_t vptr) {
    int n = 0;
    while (n < VT_SLOTS && in_text(*(const uintptr_t *)(vptr + 8 * (uintptr_t)n)))
        n++;
    return n;
}

// The handler slot of a job vtable
static int handler_slot(uintptr_t vptr, int run) {
    int found = -1;
    for (int i = 0; i < run; i++) {
        uintptr_t fn = *(const uintptr_t *)(vptr + 8 * (uintptr_t)i);
        if (!fn_calls(fn, g_send_response)) continue;
        if (found >= 0) {
            NP_DBG("webui: job vtable 0x%lx sends a response from both slot %d and "
                   "slot %d, so neither can be claimed",
                   (unsigned long)vptr, found, i);
            return -1;
        }
        found = i;
    }
    return found;
}

// The job vtable a factory installs
static uintptr_t vtable_from_factory(uintptr_t factory, int *slot_out, int *run_out) {
    uintptr_t ctor = 0;
    for (uintptr_t pc = factory; pc < factory + FN_SPAN_MAX; pc += 4)
        if (bl_target(*(const uint32_t *)pc, pc, &ctor)) break;

    if (!in_text(ctor)) {
        NP_DBG("webui: job factory 0x%lx calls nothing that could build the job",
               (unsigned long)factory);
        return 0;
    }

    for (uintptr_t pc = ctor; pc + 8 <= ctor + FN_SPAN_MAX; pc += 4) {
        uintptr_t cand = adrp_add_target(pc, *(const uint32_t *)pc,
                                         *(const uint32_t *)(pc + 4));
        if (!cand || cand < g_const_base + 16) continue;
        if (cand + 8 * VT_SLOTS >= g_const_end) continue;

        int run = vtable_run(cand);
        if (run < VT_RUN_MIN) continue;

        int slot = handler_slot(cand, run);
        if (slot < 0) continue;

        *slot_out = slot;
        *run_out  = run;
        return cand;
    }

    NP_DBG("webui: nothing in the job builder at 0x%lx reads as a job class built on "
           "a single base", (unsigned long)ctor);
    return 0;
}

static int (*g_on_job)(void);

void np_webui_on_job(int (*fn)(void)) {
    g_on_job = fn;
}

// Every route shares one job class, so one handler serves them all
static int64_t job_handler(uintptr_t job, uintptr_t ctx) {
    if (g_on_job) g_on_job();

    uintptr_t request  = *(const uintptr_t *)(ctx + 8);
    uintptr_t response = *(const uintptr_t *)(ctx + 16);
    uintptr_t job_vptr = *(const uintptr_t *)job;

    int result = RESULT_FAIL;
    for (int i = 0; i < g_route_count; i++) {
        if ((uintptr_t)&g_routes[i].vtable[2] != job_vptr) continue;
        result = g_routes[i].handler(request, response);
        break;
    }

    *(uint32_t *)ctx = (uint32_t)result;
    ((np_send_response_fn)g_send_response)(job, ctx);
    return 1;
}

// A route the client already serves, borrowed for its job factory and its flags.
static int borrow_from_served_route(void) {
    uintptr_t elements;
    int bound;
    if (!walk_routes(&elements, &bound)) return 0;

    for (int i = 0; i < bound; i++) {
        if (!route_at(elements, i)) continue;

        uintptr_t elem = elements + (uintptr_t)i * ROUTE_STRIDE;
        uintptr_t desc = *(const uintptr_t *)(elem + ELEM_DESCRIPTOR_OFF);
        if (!np_plausible_ptr(desc)) continue;

        uintptr_t factory = *(const uintptr_t *)(desc + 8 * DESC_FACTORY);
        if (!in_text(factory)) continue;

        int slot = -1, run = 0;
        uintptr_t vptr = vtable_from_factory(factory, &slot, &run);
        if (!vptr) continue;

        // Two entries sit ahead of slot 0, the offset to top and the type
        // information, and code that asks a job what it is reads them.
        memcpy(g_clone, (const void *)(vptr - 16), 16 + 8 * (size_t)run);
        g_clone[2 + slot] = (uintptr_t)job_handler;
        g_clone_words   = 2 + (size_t)run;
        g_stock_factory = factory;
        g_route_flags   = *(const uintptr_t *)(elem + ELEM_FLAGS_OFF);

        NP_LOG("webui: job built like the client's own %s, vtable 0x%lx cloned over "
               "%d virtuals with the handler in slot %d", route_at(elements, i),
               (unsigned long)vptr, run, slot);
        return 1;
    }

    NP_ERR("webui: none of the %d routes the client serves gives up a job factory",
           bound);
    return 0;
}

static uintptr_t build_job(int route, uintptr_t dispatcher, uintptr_t arg) {
    uintptr_t job = ((np_job_factory_fn)g_stock_factory)(dispatcher, arg);
    if (job)
        *(uintptr_t *)job = (uintptr_t)&g_routes[route].vtable[2];
    return job;
}

// The dispatcher calls a factory with no route, so each route needs a factory of its own.
#define JOB_FACTORY(i) \
    static uintptr_t job_factory_##i(uintptr_t d, uintptr_t a) { return build_job(i, d, a); }
JOB_FACTORY(0) JOB_FACTORY(1) JOB_FACTORY(2) JOB_FACTORY(3)
JOB_FACTORY(4) JOB_FACTORY(5) JOB_FACTORY(6) JOB_FACTORY(7)
static const np_job_factory_fn g_job_factories[MAX_ROUTES] = {
    job_factory_0, job_factory_1, job_factory_2, job_factory_3,
    job_factory_4, job_factory_5, job_factory_6, job_factory_7,
};

int np_webui_register_route(const char *name, uintptr_t request_vptr,
                           uintptr_t response_vptr, np_webui_handler_fn handler) {
    if (!g_registry || !g_register_fn || !name || !handler) return 0;
    if (!np_plausible_ptr(request_vptr) || !np_plausible_ptr(response_vptr)) {
        NP_ERR("webui: %s has no message types, so it cannot be served", name);
        return 0;
    }
    if (g_route_count >= MAX_ROUTES) {
        NP_ERR("webui: no room left to serve %s", name);
        return 0;
    }

    if (!g_clone_words && !borrow_from_served_route())
        return 0;

    uintptr_t request_new  = *(const uintptr_t *)(request_vptr + MSG_NEW_OFF);
    uintptr_t response_new = *(const uintptr_t *)(response_vptr + MSG_NEW_OFF);
    if (!in_text(request_new) || !in_text(response_new)) {
        NP_ERR("webui: the message types for %s do not build their own messages", name);
        return 0;
    }

    np_route_t *route = &g_routes[g_route_count];
    route->descriptor[DESC_NAME]     = (uintptr_t)name;
    route->descriptor[DESC_CONSTANT] = DESC_CONSTANT_VALUE;
    route->descriptor[DESC_FACTORY]  = (uintptr_t)g_job_factories[g_route_count];
    route->handler                   = handler;
    memcpy(route->vtable, g_clone, sizeof(uintptr_t) * g_clone_words);

    uintptr_t record[4] = {
        (uintptr_t)route->descriptor,
        g_route_flags,
        request_new,
        response_new,
    };

    int rc = ((np_register_fn)g_register_fn)(g_registry, record);
    if (rc != 1) {
        NP_ERR("webui: the client refused to serve %s (rc=%d)", name, rc);
        return 0;
    }

    g_route_count++;
    NP_LOG("webui: serving %s", name);
    return 1;
}

static uintptr_t find_literal(const char *s) {
    if (!g_text_seg_base) return 0;
    return (uintptr_t)memmem((const void *)g_text_seg_base, g_text_seg_size,
                             s, strlen(s) + 1);
}

static int notify_slot(uintptr_t vtable, uintptr_t task_name) {
    for (int slot = 0; slot < VT_SLOTS; slot++) {
        uintptr_t fn = *(const uintptr_t *)(vtable + 8 * (uintptr_t)slot);
        if (!in_text(fn)) continue;

        for (uintptr_t pc = fn; pc + 8 <= fn + FN_SPAN_MAX; pc += 4) {
            uint32_t insn = *(const uint32_t *)pc;
            if (insn == 0xD65F03C0) break;                    // RET
            if (adrp_add_target(pc, insn, *(const uint32_t *)(pc + 4)) == task_name)
                return slot;
        }
    }
    return -1;
}

uintptr_t np_webui_new_message(uintptr_t vptr) {
    if (!np_plausible_ptr(vptr)) return 0;

    uintptr_t new_fn = *(const uintptr_t *)(vptr + MSG_NEW_OFF);
    if (!in_text(new_fn)) {
        NP_ERR("webui: the message type at 0x%lx does not build its own messages",
               (unsigned long)vptr);
        return 0;
    }
    return ((np_msg_new_fn)new_fn)();
}

int np_webui_notify(const char *name, uintptr_t message) {
    static int worked_out;

    if (!g_registry || !name || !np_plausible_ptr(message)) return 0;

    uintptr_t transport = *(const uintptr_t *)(g_registry + REGISTRY_BROADCASTER_OFF);
    uintptr_t vtable    = np_plausible_ptr(transport) ? *(const uintptr_t *)transport : 0;
    if (!np_plausible_ptr(vtable)) {
        NP_DBG("webui: no transport is up, so %s reaches nobody", name);
        return 0;
    }

    if (g_notify_slot < 0) {
        if (worked_out) return 0;
        worked_out = 1;

        uintptr_t task = find_literal(BROADCAST_TASK_NAME);
        g_notify_slot  = task ? notify_slot(vtable, task) : -1;
        if (g_notify_slot < 0) {
            NP_ERR("webui: the transport at 0x%lx sends nothing through a task, so "
                   "the page will not hear %s", (unsigned long)transport, name);
            return 0;
        }
        NP_LOG("webui: notifications go out through slot %d of the transport at 0x%lx",
               g_notify_slot, (unsigned long)transport);
    }

    uintptr_t send = *(const uintptr_t *)(vtable + 8 * (uintptr_t)g_notify_slot);
    if (!in_text(send)) return 0;

    return ((np_notify_fn)send)(transport, name, message) == 1;
}
