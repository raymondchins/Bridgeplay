// The layout probes read instruction words straight out of the client, and everything else
// reaches it through a function pointer an installer sets. Including the unit rather than
// linking points the probes at synthesised instructions and the pointers at stubs. No Steam.
#include <dlfcn.h>
#include <stdlib.h>

static void *checked_calloc(size_t count, size_t size);
static void checked_free(void *ptr);
static void *checked_dlsym(void *handle, const char *name);

#define calloc checked_calloc
#define free checked_free
#define dlsym checked_dlsym
#include "../feats/compat.c"
#undef calloc
#undef free
#undef dlsym
#include "../feats/usershortcuts.c"

#include <stdio.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/wait.h>

static atomic_int home_calls;
static atomic_int home_ready;

// Silent, because half of these checks drive paths whose whole job is to refuse and log.
int   np_log_level = -1;
FILE *np_log_file  = NULL;

int np_log_first_hit(const void *anchor, unsigned long tag) {
    (void)anchor; (void)tag;
    return 1;
}

const char *np_home_dir(void) {
    if (atomic_fetch_add(&home_calls, 1) == 0) {
        usleep(50000);
        atomic_store(&home_ready, 1);
    }
    return "/nonexistent";
}

void np_support_path(char *buf, size_t bufsz, const char *home, const char *rel) {
    snprintf(buf, bufsz, "%s/Library/Application Support/bridgeplay/%s", home, rel ? rel : "");
}

int np_get_section_containing(const struct mach_header_64 *mh, intptr_t slide,
                              uintptr_t addr, uintptr_t *out_base, size_t *out_size) {
    (void)mh; (void)slide; (void)addr; (void)out_base; (void)out_size;
    return -1;
}

uintptr_t np_rtti_vptr(const struct mach_header_64 *mh, intptr_t slide,
                       uintptr_t text_base, size_t text_size, const char *type_name) {
    (void)mh; (void)slide; (void)text_base; (void)text_size; (void)type_name;
    return 0;
}

static int failures;

static void check(int ok, const char *what) {
    if (!ok) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

static int track_registration, fail_calloc, missing_allocator;
static int buffer_allocations, buffer_successes, buffer_frees, registration_calls, path_frees;
static void *registration_buffer;
static void *path_allocations[16];
static int path_count;

static void *checked_calloc(size_t count, size_t size) {
    if (!track_registration) return calloc(count, size);
    buffer_allocations++;
    if (fail_calloc) return NULL;
    registration_buffer = calloc(count, size);
    buffer_successes += registration_buffer != NULL;
    return registration_buffer;
}

static void checked_free(void *ptr) {
    if (track_registration && ptr && ptr == registration_buffer) {
        buffer_frees++;
        registration_buffer = NULL;
    }
    for (int i = 0; i < path_count; i++)
        check(!ptr || ptr != path_allocations[i], "Steam strings never reach libc free");
    free(ptr);
}

static void stub_plat_free(void *ptr) {
    for (int i = 0; i < path_count; i++) {
        if (ptr && path_allocations[i] == ptr) {
            path_allocations[i] = NULL;
            path_frees++;
            free(ptr);
            return;
        }
    }
    check(0, "Plat_Free receives only an owned path string, once");
}

static void *checked_dlsym(void *handle, const char *name) {
    check(handle == RTLD_DEFAULT && !strcmp(name, "Plat_Free"),
          "registration resolves Steam's exported deallocator");
    return missing_allocator ? NULL : (void *)stub_plat_free;
}

static void *first_fallback(void *arg) {
    int *ok = arg;
    const char *name = np_compat_fallback_tool_name();
    *ok = atomic_load(&home_ready) && strcmp(name, "bridgeplay-proton") == 0;
    return NULL;
}

static void concurrent_fallback_cases(void) {
    pthread_t threads[16];
    int results[16] = {0};
    size_t started = 0;
    for (; started < 16; started++) {
        if (pthread_create(&threads[started], NULL, first_fallback, &results[started]) != 0) {
            check(0, "the fallback reader thread starts");
            break;
        }
    }
    for (size_t i = 0; i < started; i++) {
        pthread_join(threads[i], NULL);
        check(results[i], "every first fallback read waits for initialization");
    }
    check(atomic_load(&home_calls) == 2, "the tool list is initialized once");
}

// A64 encodings the probes look for.
#define NOP 0xD503201Fu
static uint32_t ldr32_x0(uint32_t off, uint32_t rt) { return 0xB9400000u | ((off / 4u) << 10) | rt; }
static uint32_t ldr64(uint32_t base, uint32_t off, uint32_t rt) {
    return 0xF9400000u | ((off / 8u) << 10) | (base << 5) | rt;
}
static uint32_t ldrb(uint32_t base, uint32_t off, uint32_t rt) {
    return 0x39400000u | (off << 10) | (base << 5) | rt;
}
static uint32_t mov_x0(uint32_t rd) { return 0xAA0003E0u | rd; }
static uint32_t cbz(int32_t words, uint32_t rt) {
    return 0x34000000u | (((uint32_t)words & 0x7FFFFu) << 5) | rt;
}

// The gate the probe is handed: the appid load, a branch past it, and the install load
// the branch lands near. Laid out in a fresh buffer so one case cannot feed the next.
#define CODE_WORDS 160
#define GATE_IDX   32
static uint32_t code[CODE_WORDS];

static uintptr_t build_gate(uint32_t appid_off, uint32_t install_off) {
    for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
    code[GATE_IDX]     = ldr32_x0(appid_off, 3);
    code[GATE_IDX + 1] = cbz(4, 3);                       // lands on GATE_IDX + 5
    code[GATE_IDX + 5] = ldr64(0, install_off, 4);
    return (uintptr_t)&code[GATE_IDX];
}

// The far-end corroboration: two loads through x21 inside the window the probe scans.
static uint32_t oslist_code[CODE_WORDS];

static uintptr_t build_oslist(uint32_t from_off, uint32_t to_off) {
    for (int i = 0; i < CODE_WORDS; i++) oslist_code[i] = NOP;
    oslist_code[GATE_IDX]     = ldr64(21, from_off, 1);
    oslist_code[GATE_IDX + 1] = ldr64(21, to_off, 2);
    return (uintptr_t)&oslist_code[GATE_IDX];
}

static void probe_cases(void) {
    g_tool_shift = 0;
    check(np_compat_probe_tool_layout(build_gate(0x60, 0x58), 0) == 1,
          "the reference layout probes clean");
    check(g_tool_shift == 0, "the reference layout reports no shift");
    check(np_compat_tool_stride() == COMPAT_TOOL_STRIDE, "an unshifted entry keeps its stride");

    g_tool_shift = 0;
    check(np_compat_probe_tool_layout(build_gate(0x68, 0x60), 0) == 1,
          "a client that grew the entry by 8 probes clean");
    check(np_compat_tool_off(COMPAT_TOOL_APPID_OFF) == 0x68, "appid follows the shift");
    check(np_compat_tool_off(COMPAT_TOOL_INSTALL_OFF) == 0x60, "install follows the shift");
    check(np_compat_tool_off(COMPAT_TOOL_GATE_FLAGS_OFF) == COMPAT_TOOL_GATE_FLAGS_OFF,
          "a field ahead of the insertion point does not follow the shift");
    check(np_compat_tool_stride() == COMPAT_TOOL_STRIDE + 8, "the entry widens by what it moved");

    // A shift already established has to survive a probe that cannot agree with itself,
    // because a half-written layout is worse than the one being replaced.
    g_tool_shift = 8;
    check(np_compat_probe_tool_layout(build_gate(0x68, 0x58), 0) == 0,
          "appid and install disagreeing about the shift is refused");
    check(g_tool_shift == 8, "a refused probe leaves the shift alone");

    g_tool_shift = 0;
    check(np_compat_probe_tool_layout(0, 0) == 0, "no gate is refused");

    for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
    check(np_compat_probe_tool_layout((uintptr_t)&code[GATE_IDX], 0) == 0,
          "a gate that is not the appid load is refused");

    uintptr_t gate = build_gate(0x60, 0x58);
    code[GATE_IDX + 1] = NOP;
    check(np_compat_probe_tool_layout(gate, 0) == 0, "an appid load with no branch after it is refused");

    gate = build_gate(0x60, 0x58);
    code[GATE_IDX + 5] = NOP;
    check(np_compat_probe_tool_layout(gate, 0) == 0, "a branch landing on no install load is refused");
}

// The layout both probes agree on, for cases that set the shifts by hand.
static void confirm_layout(void) {
    g_head_probed = g_tail_probed = 1;
    g_head_appid_off = (uint32_t)((int32_t)COMPAT_TOOL_APPID_OFF + g_tool_shift);
}

// YldRegisterTool's prologue as the clients build it: the tool pointer parked in a callee-saved
// register, x1 reused for a log call's argument, then the name read through a second copy.
static uint32_t movz_w(uint32_t rd, uint32_t imm) { return 0x52800000u | (imm << 5) | rd; }
#define CMP_X8_0 (0xF100001Fu | (8u << 5))
#define CSEL_X8  (0x9A800000u | (8u << 16) | (26u << 5) | 8u)
static uint32_t ldr32(uint32_t base, uint32_t off, uint32_t rt) {
    return 0xB9400000u | ((off / 4) << 10) | (base << 5) | rt;
}
static uint32_t enc_mov(uint32_t rd, uint32_t rm) { return 0xAA0003E0u | (rm << 16) | rd; }
static uint32_t enc_ldr64_pre(uint32_t base, uint32_t off, uint32_t rt) {
    return 0xF8400C00u | ((off & 0x1FFu) << 12) | (base << 5) | rt;
}

static uintptr_t build_yld(uint32_t name_off, int via_x1_after_reuse) {
    for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
    code[0] = 0xA9BF7BFDu;                 // stp x29, x30, [sp, #-0x10]!
    code[1] = enc_mov(20, 1);              // mov x20, x1
    code[2] = enc_mov(19, 0);              // mov x19, x0
    code[3] = movz_w(1, 4);                // mov w1, #4: x1 no longer holds the tool
    code[4] = via_x1_after_reuse ? ldr64(1, 0x40, 8) : NOP;
    code[5] = enc_mov(21, 20);             // mov x21, x20
    code[6] = enc_ldr64_pre(21, name_off, 8);  // ldr x8, [x21, #name]!
    code[7] = 0xF90017E0u;                 // str x0, [sp, #0x28]
    code[8] = CMP_X8_0;                    // cmp x8, #0
    code[9] = CSEL_X8;                     // csel x8, x26, x8, eq: the default name
    code[10] = ldr32(21, 0x28, 9);         // ldr w9, [x21, #0x28]: the appid, name + 0x28
    code[11] = 0xD65F03C0u;                // ret
    return (uintptr_t)code;
}

static int probe_tool_head(uintptr_t start) {
    return np_compat_probe_tool_head(start, (uintptr_t)(code + CODE_WORDS));
}

static void head_cases(void) {
    g_head_shift = 0;
    check(probe_tool_head(build_yld(0x40, 0)) == 1, "the stable prologue probes clean");
    check(g_head_shift == 0 && g_head_appid_off == 0x68, "a name at the reference offset reports no head shift");

    check(probe_tool_head(build_yld(0x48, 0)) == 1, "the beta prologue probes clean");
    check(g_head_shift == 8, "a name 8 further in reports the head shift");

    check(probe_tool_head(build_yld(0x48, 1)) == 1,
          "a load through x1 after x1 was reused is not the tool");
    check(g_head_shift == 8, "the name is still read through the parked copy");

    // A BL whose displacement ends in x20's number writes no register, while the call
    // does clobber x1, so a load through x1 after it is not the tool.
    build_yld(0x48, 0);
    code[3] = 0x94000000u | 20u;           // bl, low bits 10100
    code[4] = ldr64(1, 0x40, 8);           // ldr x8, [x1, #0x40]
    check(probe_tool_head((uintptr_t)code) == 1 && g_head_shift == 8,
          "a call keeps the parked copy and drops x1");
    build_yld(0x48, 0);
    code[3] = 0xD63F0100u;                 // blr x8
    code[4] = ldr64(1, 0x40, 8);
    check(probe_tool_head((uintptr_t)code) == 1 && g_head_shift == 8,
          "an indirect call drops x1 too");

    // Writes the old scan missed: both registers of a pair load, and a written-back base.
    build_yld(0x48, 0);
    code[3] = 0xA9400000u | (2u << 15) | (20u << 10) | (31u << 5) | 8u;   // ldp x8, x20, [sp, #0x10]
    check(probe_tool_head((uintptr_t)code) == 0, "a pair load into the parked copy drops it");
    build_yld(0x48, 0);
    code[3] = 0xA9800000u | (0x7Eu << 15) | (30u << 10) | (20u << 5) | 29u; // stp x29, x30, [x20, #-0x10]!
    check(probe_tool_head((uintptr_t)code) == 0, "a pair store writing back the copy drops it");
    build_yld(0x48, 0);
    code[3] = 0xF8400400u | (8u << 12) | (20u << 5) | 9u;                   // ldr x9, [x20], #8
    check(probe_tool_head((uintptr_t)code) == 0, "a post-indexed load through the copy drops it");

    // Control flow: a forward branch is taken, so a load it jumps over is never read,
    // and a return or a backward or far branch ends the walk with no answer.
    build_yld(0x48, 0);
    code[3] = 0x14000002u;                 // b over the next word
    code[4] = ldr64(20, 0x30, 8);          // unreachable; refused if it were read
    check(probe_tool_head((uintptr_t)code) == 1 && g_head_shift == 8,
          "a load a branch jumps over is not read");
    build_yld(0x48, 0);
    code[3] = 0xD65F03C0u;                 // ret
    check(probe_tool_head((uintptr_t)code) == 0, "a return before the name load is refused");
    build_yld(0x48, 0);
    code[3] = 0x17FFFFFFu;                 // b back one word
    check(probe_tool_head((uintptr_t)code) == 0, "a backward branch is refused");
    build_yld(0x48, 0);
    code[3] = 0x14000000u | (0x200u / 4);  // b past the window
    check(probe_tool_head((uintptr_t)code) == 0, "a branch out of the window is refused");

    // Anything the walk does not model is refused rather than guessed past.
    static const uint32_t unmodelled[] = {
        0x58000041u,                       // ldr x1, literal
        0x0CDF7000u | (20u << 5),          // ld1 {v0.8b}, [x20], #8
        0xC87F0000u | (20u << 10) | 8u,    // ldxp x8, x20, [x0]
        0xC8E0FC00u | (2u << 16) | 20u,    // casal x2, x20, [x0]
        0xF8228000u | 20u,                 // swp x2, x20, [x0]
        0x91000000u | (0x48u << 10) | (20u << 5) | 9u,  // add x9, x20, #0x48
    };
    for (size_t i = 0; i < sizeof unmodelled / sizeof *unmodelled; i++) {
        build_yld(0x48, 0);
        code[3] = unmodelled[i];
        check(probe_tool_head((uintptr_t)code) == 0, "an unmodelled instruction is refused");
    }

    // Both sides of a conditional branch are read and must agree.
    for (int agree = 0; agree < 2; agree++) {
        for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
        code[0] = enc_mov(20, 1);
        code[1] = 0x34000000u | (6u << 5) | 2u;    // cbz w2, +6 words
        code[2] = ldr64(20, agree ? 0x48 : 0x40, 8);
        code[3] = CMP_X8_0;
        code[4] = CSEL_X8;
        code[5] = ldr32(20, agree ? 0x70 : 0x68, 9);
        code[6] = 0xD65F03C0u;
        code[7] = ldr64(20, 0x48, 8);
        code[8] = CMP_X8_0;
        code[9] = CSEL_X8;
        code[10] = ldr32(20, 0x70, 9);
        code[11] = 0xD65F03C0u;
        check(probe_tool_head((uintptr_t)code) == agree,
              agree ? "paths that agree probe clean" : "paths that disagree are refused");
    }
    check(g_head_shift == 8 && g_head_appid_off == 0x70, "an unscaled name load keeps its own appid");

    // A call writes the link register too, so a copy parked there is gone after it.
    for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
    code[0] = enc_mov(30, 1);
    code[1] = movz_w(1, 4);
    code[3] = ldr64(30, 0x40, 8);
    code[4] = CMP_X8_0;
    code[5] = CSEL_X8;
    code[6] = ldr32(30, 0x68, 9);
    code[7] = 0xD65F03C0u;
    check(probe_tool_head((uintptr_t)code) == 1, "a copy in the link register is accepted before a call");
    code[2] = 0x94000040u;                 // bl
    check(probe_tool_head((uintptr_t)code) == 0, "a copy in the link register is lost to a call");

    // The appid read after the name ties the head to the tail probe.
    build_yld(0x48, 0);
    code[10] = 0xD65F03C0u;
    check(probe_tool_head((uintptr_t)code) == 0, "a name with no appid after it is refused");
    build_yld(0x48, 0);
    code[10] = ldr32(21, 0x20, 9);         // appid at 0x68, which the beta tail does not have
    check(probe_tool_head((uintptr_t)code) == 1, "the head probe itself reads a mismatched appid");
    g_tool_shift = 16;
    g_tail_probed = 1;
    check(!np_compat_layout_known(), "an appid the tail probe disagrees with leaves the layout unconfirmed");
    check(probe_tool_head(build_yld(0x48, 0)) == 1 && g_head_appid_off == 0x70 &&
          np_compat_layout_known(), "the beta prologue agrees with the beta tail");
    // A field that is not null-checked into a default string is not the name, even
    // when the real appid follows it.
    for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
    code[0] = ldr64(1, 0x40, 8);           // beta priority slot
    code[1] = ldr32(1, 0x70, 9);           // the genuine beta appid
    code[2] = ldr64(1, 0x48, 10);
    code[3] = 0xD65F03C0u;
    check(probe_tool_head((uintptr_t)code) == 0, "a load with no name check is not the name");
    build_yld(0x48, 0);
    code[8] = NOP;
    check(probe_tool_head((uintptr_t)code) == 0, "a name check without the compare is refused");
    build_yld(0x48, 0);
    code[9] = 0x9A800000u | (27u << 16) | (26u << 5) | 8u;  // csel x8, x26, x27, eq
    check(probe_tool_head((uintptr_t)code) == 0, "a select that ignores the load is refused");

    build_yld(0x48, 0);
    code[9] = 0x9A8803E8u;                 // csel x8, xzr, x8, eq
    check(!probe_tool_head((uintptr_t)code), "an equal select with no default string is refused");
    code[9] = 0x9A9F1108u;                 // csel x8, x8, xzr, ne
    check(!probe_tool_head((uintptr_t)code), "a not-equal select with no default string is refused");

    build_yld(0x48, 0);
    code[9] = CSEL_X8 | (2u << 12);         // csel x8, x26, x8, hs
    check(!probe_tool_head((uintptr_t)code), "an unrelated select condition is refused");
    build_yld(0x48, 0);
    code[9] = 0xF100001Fu;                 // cmp x0, #0 clobbers the name comparison
    code[10] = CSEL_X8;
    code[11] = ldr32(21, 0x28, 9);
    check(!probe_tool_head((uintptr_t)code), "a select on overwritten flags is refused");
    build_yld(0x48, 0);
    code[9] = movz_w(8, 1);
    code[10] = CSEL_X8;
    code[11] = ldr32(21, 0x28, 9);
    check(!probe_tool_head((uintptr_t)code), "an overwritten name is refused");
    build_yld(0x48, 0);
    code[5] = 0x14000002u;                 // b beyond the function
    code[6] = 0xD65F03C0u;
    code[7] = enc_ldr64_pre(20, 0x48, 8);
    code[10] = ldr32(20, 0x28, 9);
    check(!np_compat_probe_tool_head((uintptr_t)code, (uintptr_t)(code + 7)),
          "a branch into the next function is refused");

    // Decoder cases: a load replacing its own base, register arithmetic that only
    // resembles a pair, and a hint that writes x17.
    for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
    code[0] = enc_mov(20, 1);
    code[1] = ldr64(20, 0x48, 20);         // ldr x20, [x20, #0x48]
    code[2] = 0xF100001Fu | (20u << 5);
    code[3] = 0x9A800000u | (20u << 16) | (26u << 5) | 8u;
    code[4] = ldr32(20, 0x70, 9);
    code[5] = 0xD65F03C0u;
    check(probe_tool_head((uintptr_t)code) == 0, "a load that replaces its base is refused");
    build_yld(0x48, 0);
    code[3] = 0xAB020014u;                 // adds x20, x0, x2
    check(probe_tool_head((uintptr_t)code) == 0, "register arithmetic is not a pair store");
    build_yld(0x48, 0);
    code[1] = enc_mov(17, 1);
    code[3] = 0xD503211Fu;                 // pacia1716
    code[5] = enc_mov(21, 17);
    check(probe_tool_head((uintptr_t)code) == 0, "a hint that writes x17 is refused");
    build_yld(0x48, 0);
    code[3] = 0xD503237Fu;                 // pacibsp
    code[4] = 0xD503245Fu;                 // bti c
    check(probe_tool_head((uintptr_t)code) == 1 && g_head_shift == 8, "PAC and BTI hints are allowed");

    // The real prologue, with its logging branch: a call on one side, a move on the other.
    for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
    static const uint32_t real[] = {        // Steam beta 1795048523, YldRegisterTool
        0xD10243FFu, 0xA9036FFCu, 0xA90467FAu, 0xA9055FF8u, 0xA90657F6u, 0xA9074FF4u,
        0xA9087BFDu, 0x910203FDu, 0xAA0103F4u, 0xAA0003F3u, 0xB0008208u, 0xF9429D08u,
        0xB9400108u, 0x340000E8u, 0xD00079A0u, 0x913B3400u, 0x9100A3E2u, 0x52800081u,
        0x9431A16Bu, 0x14000002u, 0xD2800000u, 0xAA1403F5u, 0xF8448EA8u, 0xF90017E0u,
        0x9000779Au, 0x913A575Au, 0xF100011Fu, 0x9A880348u, 0xB9402AA9u, 0xA90027E8u,
    };
    memcpy(code, real, sizeof real);
    check(probe_tool_head((uintptr_t)code) == 1 && g_head_shift == 8 && g_head_appid_off == 0x70,
          "the beta prologue as Steam builds it probes clean");

    g_tool_shift = 0;
    g_tail_probed = 0;

    check(probe_tool_head(build_yld(0x30, 0)) == 0, "a name below the reference is refused");
    check(probe_tool_head(0) == 0, "no function is refused");
    for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
    check(probe_tool_head((uintptr_t)code) == 0, "a body with no tool load is refused");

    // Beta 1795048523: 8 bytes ahead of "unlisted", 16 in all by the install dir.
    g_head_shift = 8;
    g_tool_shift = 16;
    confirm_layout();
    check(np_compat_tool_off(0x20) == 0x20, "a field below the head insertion stays put");
    check(np_compat_tool_off(COMPAT_TOOL_GATE_FLAGS_OFF) == 0x2c, "unlisted follows the head shift");
    check(np_compat_tool_off(COMPAT_TOOL_PRIORITY_OFF) == 0x40, "priority follows the head shift");
    check(np_compat_tool_off(COMPAT_TOOL_NAME_OFF) == 0x48, "the name follows the head shift");
    check(np_compat_tool_off(COMPAT_TOOL_DISPLAY_OFF) == 0x58, "the display name follows the head shift");
    check(np_compat_tool_off(COMPAT_TOOL_INSTALL_OFF) == 0x68, "install takes both shifts");
    check(np_compat_tool_off(COMPAT_TOOL_APPID_OFF) == 0x70, "appid takes both shifts");
    check(np_compat_tool_stride() == 0x140, "the entry widens by both shifts");
    check(np_compat_layout_known(), "agreeing probes confirm the layout");
    {
        static uint8_t entry[0x200];
        static const char tool[] = "bridgeplay-proton-winecx-11.17";
        *(const char **)(entry + 0x48) = tool;
        check(np_compat_tool_name(entry) == tool, "the name is read at the probed offset");
        g_head_probed = 0;
        check(np_compat_tool_name(entry) == NULL, "an unconfirmed layout reads no name");
        g_head_probed = 1;
    }
    g_head_shift = 24;
    check(!np_compat_layout_known(), "a head shift past the install shift is not a layout");
    g_tool_shift = 64;
    confirm_layout();
    check(np_compat_layout_known(), "the largest entry that fits the registration buffer is accepted");
    g_tool_shift = 72;
    confirm_layout();
    check(!np_compat_layout_known(), "the first aligned entry larger than the registration buffer is refused");
    g_head_probed = 0;
    g_head_shift = 0;
    check(!np_compat_layout_known(), "an unprobed head leaves the layout unconfirmed");
    g_tool_shift = 0;
    g_tail_probed = 0;
}

static void oslist_cases(void) {
    g_tool_shift = 0;
    check(np_compat_probe_tool_layout(build_gate(0x68, 0x60), build_oslist(0x78, 0x80)) == 1,
          "the far end agreeing on the shift probes clean");
    check(g_tool_shift == 8, "agreement at both ends keeps the shift");

    g_tool_shift = 0;
    check(np_compat_probe_tool_layout(build_gate(0x68, 0x60), build_oslist(0x70, 0x78)) == 0,
          "the near fields moving and the oslist not is refused");
    check(g_tool_shift == 0, "a far-end disagreement writes no shift");

    // Whichever order the comparison loads them in, the higher offset is to_oslist.
    g_tool_shift = 0;
    check(np_compat_probe_tool_layout(build_gate(0x68, 0x60), build_oslist(0x80, 0x78)) == 1,
          "the oslist pair is read by offset rather than by load order");
}

static void enabled_cases(void) {
    g_enabled_off = COMPAT_MANAGER_ENABLED_OFF;

    for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
    code[0] = mov_x0(21);
    code[1] = ldrb(21, 0x7C0, 8);
    check(np_compat_probe_enabled_off((uintptr_t)code) == 1, "the enabled flag probes clean");
    check(np_compat_enabled_off() == 0x7C0, "the probed flag offset is what gets reported");

    g_enabled_off = COMPAT_MANAGER_ENABLED_OFF;
    for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
    code[0] = mov_x0(21);
    code[1] = ldrb(21, 0x20, 8);
    check(np_compat_probe_enabled_off((uintptr_t)code) == 0,
          "a byte read too early in the object is not taken for the flag");
    check(np_compat_enabled_off() == COMPAT_MANAGER_ENABLED_OFF,
          "a refused flag probe leaves the baseline in place");

    for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
    code[0] = ldrb(21, 0x7C0, 8);
    check(np_compat_probe_enabled_off((uintptr_t)code) == 0,
          "a body that never parks this in a register is refused");

    check(np_compat_probe_enabled_off(0) == 0, "no function is refused");
}

// A manager holding `count` entries, the one at `named_slot` carrying the tool name.
static uint8_t manager[0x400];
static uint8_t entries[(COMPAT_MANAGER_TOOLS_HEADROOM + 64) * (COMPAT_TOOL_STRIDE + 64)];

static void *build_manager(uint32_t count, int named_slot) {
    memset(manager, 0, sizeof manager);
    memset(entries, 0, sizeof entries);
    *(uint8_t **)(manager + COMPAT_MANAGER_TOOL_ARRAY_OFF) = entries;
    *(uint32_t *)(manager + COMPAT_MANAGER_TOOL_COUNT_OFF) = count;
    if (named_slot >= 0) {
        uint8_t *entry = entries + (size_t)named_slot * np_compat_tool_stride();
        *(const char **)(entry + COMPAT_TOOL_NAME_OFF) = TOOL_DIR_NAME;
    }
    return manager;
}

static void manager_cases(void) {
    g_tool_shift = 0;
    g_head_shift = 0;
    confirm_layout();

    void *mgr = build_manager(3, 1);
    void *want = entries + np_compat_tool_stride();
    check(np_compat_registered_tool(mgr) == want, "the entry registered under the tool name is found");

    check(np_compat_registered_tool(build_manager(3, -1)) == NULL,
          "a manager holding no entry of ours reports none");
    check(np_compat_registered_tool(NULL) == NULL, "no manager reports no entry");

    // A count this large means the offset it was read from moved, so the array it
    // describes is not one to walk.
    uint32_t cap = np_compat_manager_tools_max();
    check(cap <= COMPAT_MANAGER_TOOLS_HEADROOM + 64, "the manager fixture holds the cap");
    check(np_compat_registered_tool(build_manager(cap + 1, 1)) == NULL,
          "a count past the cap is refused rather than walked");
    check(np_compat_registered_tool(build_manager(cap, -1)) == NULL,
          "a count at the cap is still walked");

    mgr = build_manager(3, 1);
    *(uint8_t **)((uint8_t *)mgr + COMPAT_MANAGER_TOOL_ARRAY_OFF) = NULL;
    check(np_compat_registered_tool(mgr) == NULL, "a manager with no array is refused");

    // The walk steps by the live stride, so an entry that grew is still found.
    g_tool_shift = 8;
    confirm_layout();
    mgr = build_manager(3, 2);
    check(np_compat_registered_tool(mgr) == entries + 2 * np_compat_tool_stride(),
          "the walk steps by the live stride rather than the baseline");
    g_tool_shift = 0;
}

#define REGISTRATION_CLIENT_SHIFT 8
static const uint32_t registration_paths[] = {160, 168, 176, 216, 224, 232, 240, 288};
static const uint32_t registration_strings[] = {
    64, 80, 96, 120, 128, 160, 168, 176, 216, 224, 232, 240, 288
};
static int partial_paths;
static int registration_head_shift;

static uint32_t registration_string_off(uint32_t field) {
    if (field < 96) return field + registration_head_shift;
    return field + g_tool_shift - REGISTRATION_CLIENT_SHIFT;
}

static void stub_register_tool(void *mgr, void *source) {
    uint8_t *tool = source;
    uint32_t *count = (uint32_t *)((uint8_t *)mgr + COMPAT_MANAGER_TOOL_COUNT_OFF);
    uint8_t *copy = entries + (*count)++ * np_compat_tool_stride();
    registration_calls++;
    for (size_t i = 0; i < sizeof(registration_paths) / sizeof(*registration_paths); i++) {
        if (partial_paths && i % 2) continue;
        char *path = strdup("/pfx/drive_c/users/steamuser");
        path_allocations[path_count++] = path;
        *(char **)(tool + registration_paths[i] + g_tool_shift - REGISTRATION_CLIENT_SHIFT) = path;
    }
    memcpy(copy, tool, np_compat_tool_stride());
    for (size_t i = 0; i < sizeof(registration_strings) / sizeof(*registration_strings); i++) {
        uint32_t field = registration_strings[i];
        uint32_t off = registration_string_off(field);
        const char *str = *(const char **)(tool + off);
        *(char **)(copy + off) = str ? strdup(str) : NULL;
    }
}

static void registration_case(int head_shift, int shift, int mode) {
    tool_entry_t tools[2] = {0};
    g_tool_shift = shift;
    registration_head_shift = g_head_shift = head_shift;
    confirm_layout();
    if (mode == 7) g_head_probed = 0;   // a client whose layout was not confirmed
    g_tools = tools;
    g_tool_count = mode == 4 ? 0 : 2;
    int existing = mode == 1 ? 2 : mode == 2 ? 1 : 0;
    fail_calloc = mode == 3;
    missing_allocator = mode == 5;
    partial_paths = mode == 6;
    build_manager(existing, -1);
    for (int i = 0; i < g_tool_count; i++) {
        snprintf(tools[i].name, sizeof(tools[i].name), "bridgeplay-proton-%d", i);
        snprintf(tools[i].display, sizeof(tools[i].display), "Tool %d", i);
        snprintf(tools[i].dir, sizeof(tools[i].dir), "/tools/tool%d", i);
        if (i < existing)
            *(const char **)(entries + i * np_compat_tool_stride() + 0x40 + head_shift) = tools[i].name;
    }
    track_registration = 1;
    np_compat_register_crossover(NULL);
    np_compat_register_crossover(manager);
    check(buffer_allocations == 0, "registration waits for a manager and function");
    np_compat_set_register_fn((uintptr_t)stub_register_tool);
    np_compat_register_crossover(manager);
    int expected = fail_calloc || mode == 7 ? 0 : g_tool_count - existing;
    check(registration_calls == expected, "only missing tools are registered");
    check(registration_buffer == NULL, "the temporary entry buffer is freed");
    check(buffer_frees == buffer_successes, "each successful allocation is freed once");
    check(path_frees == (missing_allocator ? 0 : path_count), "every owned path uses Plat_Free");
    for (int i = existing; i < existing + expected; i++) {
        uint8_t *copy = entries + i * np_compat_tool_stride();
        const char *name = *(const char **)(copy + 0x40 + head_shift);
        const char *display = *(const char **)(copy + 0x50 + head_shift);
        check(name && !strcmp(name, tools[i].name), "the manager owns the tool name");
        check(display && !strcmp(display, tools[i].display), "the manager owns the display name");
        check(*(uint32_t *)(copy + 0x28 + head_shift) == COMPAT_TOOL_FLAG_NO_APP,
              "the manager has the no-app flag at the client offset");
        for (size_t j = 0; j < sizeof(registration_strings) / sizeof(*registration_strings); j++) {
            uint32_t field = registration_strings[j];
            uint32_t off = registration_string_off(field);
            char *str = *(char **)(copy + off);
            if (field >= 160 && str)
                check(!strcmp(str, "/pfx/drive_c/users/steamuser"), "the manager owns its path copy");
            free(str);
        }
    }
    int attempts = buffer_allocations;
    np_compat_register_crossover(manager);
    check(buffer_allocations == attempts && registration_calls == expected,
          "repeated queries neither allocate nor register again");
    for (int i = 0; i < path_count; i++) free(path_allocations[i]);
    free(registration_buffer);
}

static void registration_cases(void) {
    const int shifts[] = {0, 8, 16, 64};
    for (size_t i = 0; i < sizeof(shifts) / sizeof(*shifts); i++) {
        for (int mode = 0; mode < 8; mode++) {
            fflush(NULL);
            pid_t child = fork();
            if (child == 0) {
                failures = 0;
                registration_case(shifts[i] == 16 ? 8 : 0, shifts[i], mode);
                fflush(NULL);
                _exit(failures ? 1 : 0);
            }
            int status = 0;
            check(child > 0 && waitpid(child, &status, 0) == child &&
                  WIFEXITED(status) && WEXITSTATUS(status) == 0,
                  "registration ownership case passes");
        }
    }
}

static void tool_list_cases(void) {
    confirm_layout();
    static const char path[] = "out/compatcheck-tools";
    FILE *f = fopen(path, "w");
    if (!f) {
        check(0, "the tool list fixture can be written");
        return;
    }
    fputs("bridgeplay-proton\t27.0.0.40921-fex\tfex\tCrossOver Preview (FEX)\n"
          "bridgeplay-proton-fex-41069\t27.0.0.41069-fex\tfex\tCrossOver Preview 41069 (FEX)\n"
          "bridgeplay-proton-fex-rosetta\t27.0.0.40921-fex\trosetta\tCrossOver Preview (Rosetta)\n"
          "notproton-26.3\t26.3.0.39832\trosetta\tCrossOver 26.3\n"
          "bridgeplay-proton\t26.3.0.39832\trosetta\tDuplicate\n"
          "proton-other\t1\trosetta\tForeign\n"
          "bridgeplay-other\t1\trosetta\tNo proton in the name\n"
          "bridgeplay-proton-x\t1\tarm\tBad flavor\n"
          "bridgeplay-proton-q\t1\trosetta\tQuote\"d\n"
          "bridgeplay-proton-short\t1\trosetta\n"
          "\n", f);
    fclose(f);

    int kept = np_compat_load_tool_list(path, "/tools");
    unlink(path);

    check(kept == 4, "only well-formed, unique lines named bridgeplay-proton or notproton are kept");
    check(strcmp(g_tools[0].name, "bridgeplay-proton") == 0
          && strcmp(g_tools[0].flavor, "fex") == 0, "the first line stays first");
    check(strcmp(g_tools[3].build, "26.3.0.39832") == 0
          && strcmp(g_tools[3].dir, "/tools/notproton-26.3") == 0,
          "each tool carries its build and directory");

    uint8_t *mgr = build_manager(3, -1);
    *(const char **)(entries + np_compat_tool_stride() + COMPAT_TOOL_NAME_OFF) = "notproton-26.3";
    check(np_compat_registered_tool(mgr) == entries + np_compat_tool_stride(),
          "the most preferred tool the manager holds is the default");
    *(const char **)(entries + COMPAT_TOOL_NAME_OFF) = "bridgeplay-proton";
    check(np_compat_registered_tool(mgr) == entries,
          "the first listed tool wins when the manager holds it");

    const char *fex[3] = { NULL, NULL, NULL };
    check(np_compat_fex_tools(fex, 3) == 2 && strcmp(fex[0], "bridgeplay-proton") == 0
          && strcmp(fex[1], "bridgeplay-proton-fex-41069") == 0 && !fex[2],
          "only the fex flavor counts as FEX, not a FEX build's Rosetta tool");
    fex[0] = fex[1] = NULL;
    check(np_compat_fex_tools(fex, 1) == 1 && strcmp(fex[0], "bridgeplay-proton") == 0 && !fex[1],
          "the FEX list stops at its limit, keeping the first listed");

    f = fopen(path, "w");
    if (!f) {
        check(0, "the long tool list fixture can be written");
        return;
    }
    for (int i = 0; i < 40; i++)
        fprintf(f, "bridgeplay-proton-%d\t1\trosetta\tTool %d\n", i, i);
    fclose(f);
    kept = np_compat_load_tool_list(path, "/tools");
    unlink(path);
    check(kept == 40 && strcmp(g_tools[39].name, "bridgeplay-proton-39") == 0
          && strcmp(g_tools[0].dir, "/tools/bridgeplay-proton-0") == 0, "a long list keeps every tool");
    check(strcmp(np_compat_fallback_tool_name(), "bridgeplay-proton-0") == 0,
          "the fallback is the first configured tool");
    check(np_compat_fex_tools(fex, 3) == 0, "a list with no FEX tool has no FEX names");

    check(np_compat_load_tool_list("out/compatcheck-missing", "/tools") == 0
          && !g_tool_list_present, "a missing list keeps no tools and says so");
}

static void tool_launch_cases(void) {
    static const char *tool[] = {
        "'/tools/compatibilitytools.d/bridgeplay-proton/.'/run waitforexitandrun  '/g/game.exe'",
        "A=1 '/tools/compatibilitytools.d/bridgeplay-proton-26.3/.'/run waitforexitandrun  '/g/game.exe' -x",
        "'/tools/compatibilitytools.d/bridgeplay-proton-fex-rosetta/.'/run run ",
        "'/tools/compatibilitytools.d/bridgeplay-proton'/run waitforexitandrun  '/g/game.exe'",
        "'/Volumes/Ext/Steam/compatibilitytools.d/bridgeplay-proton/.'/run waitforexitandrun '/g/game.exe'",
        "'/tools/compatibilitytools.d/notproton/.'/run waitforexitandrun  '/g/game.exe'",
        "A=1 '/tools/compatibilitytools.d/notproton-26.3/.'/run waitforexitandrun  '/g/game.exe' -x",
        "'/tools/compatibilitytools.d/proton-other/.'/run x '/tools/compatibilitytools.d/notproton/.'/run run ",
    };
    static const char *native[] = {
        "'/g/Game.app' -windowed",
        "'/g/Game.app/Contents/MacOS/Game'",
        "'/tools/compatibilitytools.d/proton-other/.'/run waitforexitandrun '/g/game.exe'",
        "'/tools/compatibilitytools.d/bridgeplay/.'/run waitforexitandrun '/g/game.exe'",
        "'/tools/compatibilitytools.d/bridgeplay-proton/Game' -x",
        "'/tools/compatibilitytools.d/bridgeplay-proton/sub/.'/run waitforexitandrun '/g/game.exe'",
        "'/tools/compatibilitytools.d/bridgeplay-proton'/other '/g/game.exe'",
        "'/tools/compatibilitytools.d/notproton/Game' -x",
        "",
    };
    for (size_t i = 0; i < sizeof(tool) / sizeof(tool[0]); i++)
        check(np_compat_runs_tool(tool[i]), tool[i]);
    for (size_t i = 0; i < sizeof(native) / sizeof(native[0]); i++)
        check(!np_compat_runs_tool(native[i]), native[i]);
    check(!np_compat_runs_tool(NULL), "no command line is no tool launch");
}

static int put(const char *dir, const char *name, const char *text) {
    char path[768];
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    FILE *f = fopen(path, "w");
    if (!f) return -1;
    fputs(text, f);
    return fclose(f);
}

static int exists(const char *path) {
    return access(path, F_OK) == 0;
}

static void stale_tool_cases(void) {
    char root[] = "out/compatcheck-toolsd.XXXXXX";
    if (!mkdtemp(root)) {
        check(0, "the tools directory fixture can be made");
        return;
    }
    char current[700], renamed[700], legacy[700], user[700], lookalike[700];
    snprintf(current, sizeof(current), "%s/bridgeplay-proton-26.3", root);
    snprintf(renamed, sizeof(renamed), "%s/notproton-winehq", root);
    snprintf(legacy, sizeof(legacy), "%s/notproton", root);
    snprintf(user, sizeof(user), "%s/notproton-mine", root);
    snprintf(lookalike, sizeof(lookalike), "%s/bridgeplay-proton-copy", root);
    const char *dirs[] = { current, renamed, legacy, user, lookalike };
    for (size_t i = 0; i < 5; i++) mkdir(dirs[i], 0755);

    put(current, "flavor", "rosetta\n");
    put(current, "run", "#!/bin/sh\n# bridgeplay CrossOver compatibility tool shim\n");
    put(renamed, "flavor", "rosetta\n");
    put(renamed, "run", "#!/bin/sh\n# notproton CrossOver compatibility tool shim\n");
    put(legacy, "run", "#!/bin/sh\n# notproton CrossOver compatibility tool shim\nset -e\n");
    put(legacy, "toolmanifest.vdf", "\"manifest\" {}\n");
    put(legacy, "compatibilitytool.vdf", "\"compatibilitytools\" {}\n");
    put(user, "run", "#!/bin/sh\nexec my-wine \"$@\"\n");
    put(lookalike, "run", "#!/bin/sh\n# bridgeplay CrossOver compatibility tool shim\n");
    put(lookalike, "notes.txt", "mine\n");

    g_tool_count = 0;
    remove_unlisted_tools(root);

    check(!exists(current), "an unlisted tool with a flavor file is removed");
    check(!exists(renamed), "an unlisted tool under the pre-3.0 name is removed");
    check(!exists(legacy), "the single-tool dylib's directory is removed");
    check(exists(user), "a notproton directory the user wrote stays");
    char notes[768];
    snprintf(notes, sizeof(notes), "%s/notes.txt", lookalike);
    check(exists(notes), "files this project did not write stay with their directory");

    remove(notes);
    char path[768];
    snprintf(path, sizeof(path), "%s/run", user);
    remove(path);
    rmdir(user);
    rmdir(lookalike);
    rmdir(root);
}

static uint32_t stub_platforms_value;
static uint32_t stub_platforms(void *mgr, uint32_t appid) {
    (void)mgr; (void)appid;
    return stub_platforms_value;
}

static const char *stub_mapping_entry[3];
static void *stub_find_mapping(void *mgr, uint32_t appid) {
    (void)mgr; (void)appid;
    return stub_mapping_entry;
}

static uint32_t last_priority;
static uint32_t last_appid;
static void stub_set_mapping(void *mgr, uint32_t appid, const char *tool_name,
                             const char *config, uint32_t priority) {
    (void)mgr; (void)tool_name; (void)config;
    last_appid = appid;
    last_priority = priority;
}

static void installed_fn_cases(void) {
    // Nothing installed is the state before the client has given the function up, and
    // every one of these reads as "cannot say" rather than as an answer.
    g_get_valid_platforms = NULL;
    g_find_mapping = NULL;
    check(np_compat_valid_platforms(manager, 7) == 0, "no platforms function reports no platform");
    check(np_compat_would_force(manager, 7) == false, "no platforms function forces nothing");
    check(np_compat_app_mapping(manager, 7) == NULL, "no mapping function reports no mapping");

    np_compat_set_valid_platforms_fn((uintptr_t)stub_platforms);
    stub_platforms_value = COMPAT_PLATFORM_WINDOWS;
    check(np_compat_would_force(manager, 7), "a windows-only app takes the default");

    stub_platforms_value = COMPAT_PLATFORM_WINDOWS | COMPAT_PLATFORM_MACOS;
    check(!np_compat_would_force(manager, 7), "an app with a macOS build is left alone");

    stub_platforms_value = COMPAT_PLATFORM_MACOS;
    check(!np_compat_would_force(manager, 7), "a macOS-only app is left alone");

    stub_platforms_value = COMPAT_PLATFORM_WINDOWS;
    check(!np_compat_would_force(manager, 0), "appid zero is not an app to force");
    check(np_compat_valid_platforms(NULL, 7) == 0, "no manager reports no platform");

    np_compat_set_app_mapping_fn((uintptr_t)stub_find_mapping);
    stub_mapping_entry[0] = "notproton";
    check(np_compat_app_mapping(manager, 7) != NULL, "a mapped app reports its entry");
    check(strcmp(np_compat_app_mapping(manager, 7), "notproton") == 0,
          "the name in the entry is what comes back");
    check(np_compat_app_mapping(manager, 0) == NULL,
          "appid zero is refused rather than reaching the global entry");

    // An entry naming nothing is how the client holds an app that was taken off tools.
    stub_mapping_entry[0] = "";
    check(np_compat_app_mapping(manager, 7) == NULL, "an empty name reports no mapping");
    stub_mapping_entry[0] = NULL;
    check(np_compat_app_mapping(manager, 7) == NULL, "an entry naming nothing reports no mapping");

    np_compat_set_mapping_fn((uintptr_t)stub_set_mapping);
    last_priority = 0;
    np_compat_map_tool(manager, 7, "notproton");
    check(last_appid == 7 && last_priority == COMPAT_MAPPING_PRIORITY_APP,
          "an app mapping outranks the global one");

    last_priority = 0;
    np_compat_map_tool(manager, 0, "notproton");
    check(last_appid == 0 && last_priority == COMPAT_MAPPING_PRIORITY_GLOBAL,
          "the global mapping stays under the threshold that skips the platform check");

    last_priority = 0;
    np_compat_map_tool(manager, 7, NULL);
    check(last_priority == 0, "mapping an app to no tool at all reaches the client as nothing");
}

static const uint32_t SET_SHORTCUT_EXE[] = {
    0xD10103FF, 0xA90157F6, 0xA9024FF4, 0xA9037BFD, 0x9100C3FD, 0xAA0303F3, 0xB940380A,
    0x3100055F, 0x54000200, 0xAA0003F4, 0xF9402808, 0x91001109, 0x93407D4A, 0x8B0A150B,
    0xB940116D, 0xAA0803EC, 0x6B0101BF, 0x54000068, 0xAA0903EC, 0x54000222, 0xD37BE94A,
    0xB86A698A, 0x3100055F, 0x54FFFEA1, 0xB40000D3, 0xF90003E1, 0x900056E1, 0x912B9021,
    0xAA1303E0, 0x94167236, 0x52800000, 0xA9437BFD, 0xA9424FF4, 0xA94157F6, 0x910103FF,
    0xD65F03C0, 0xF9400D75, 0x910042A0, 0xAA0203E1, 0x9416718C, 0xAA1503E0, 0xAA1303E1,
    0x9400000B, 0xB40000B3, 0xF9400268, 0xB4000068, 0x39400108, 0x35FFFDE8, 0xAA1403E0,
    0xAA1503E1, 0x97FFFDB6, 0x52800020, 0x17FFFFEB,
};
#define SET_EXE_NOTIFY_BL 50

static const uint32_t SHORTCUT_NOTIFY[] = {
    0xD100C3FF, 0xA9014FF4, 0xA9027BFD, 0x910083FD, 0xAA0003F3, 0xB9400028, 0xB9000BE8,
    0xF9403428, 0xF100011F, 0x1A9F07E8, 0x390033E8, 0xF9400414,
};

static const uint32_t GET_WILDCARD_MAPPING[0x100 / sizeof(uint32_t)] = {
    0xD10143FF, 0xA90257F6, 0xA9034FF4, 0xA9047BFD, 0x910103FD, 0x34000541, 0xAA0103F4,
    0xAA0003F5, 0xB90017FF, 0x910FE000, 0x910053E1, 0x97FFFF0B, 0xAA0003F3, 0xB4000180,
    0xF9400268, 0xB9401108, 0x7103E91F, 0x5400010B, 0xF90003F4, 0xF0008E20, 0x912A6000,
    0x900077E1, 0x91024C21, 0x97E8D865, 0x14000023, 0xB9001FF4, 0x39006FFF, 0x911A62A0,
    0x910073E1, 0x91006FE2, 0x97FF0A8C, 0x340003C0,
};
#define WILDCARD_LOOKUP_BL 30

#define NOTIFY_AT 64

static uintptr_t bl_dest(const uint32_t *at) {
    uintptr_t target = 0;
    a64_bl((uintptr_t)at, *at, &target);
    return target;
}

static void shortcut_probe_cases(void) {
    static uint32_t code[NOTIFY_AT + 16];
    memcpy(code, SET_SHORTCUT_EXE, sizeof(SET_SHORTCUT_EXE));
    memcpy(code + NOTIFY_AT, SHORTCUT_NOTIFY, sizeof(SHORTCUT_NOTIFY));
    code[SET_EXE_NOTIFY_BL] = 0x94000000u | (uint32_t)(NOTIFY_AT - SET_EXE_NOTIFY_BL);

    check(probe_layout((uintptr_t)code, (uintptr_t)code, sizeof(code)) == 1,
          "SetShortcutExe gives up the table layout");
    check(g_layout.root == 0x38 && g_layout.nodes == 0x50 && g_layout.stride == 32,
          "the tree root, node array and stride come from the walk");
    check(g_layout.key == 0x10 && g_layout.value == 0x18,
          "a node keys on the appid and points at the shortcut");
    check(g_layout.exe == 0x10 && g_layout.remote == 0x68,
          "the exe string and the remote id come from the setter and its notify");

    layout_t kept = g_layout;
    code[SET_EXE_NOTIFY_BL] = 0xD503201Fu;
    check(probe_layout((uintptr_t)code, (uintptr_t)code, sizeof(code)) == 0,
          "a setter that never notifies is refused");
    check(memcmp(&g_layout, &kept, sizeof(kept)) == 0, "a refused walk keeps the last layout");
    check(probe_layout(0, 0, 0) == 0, "an unresolved setter is refused");
    code[SET_EXE_NOTIFY_BL] = 0x94000000u | (uint32_t)(NOTIFY_AT - SET_EXE_NOTIFY_BL);
    check(probe_layout((uintptr_t)code, (uintptr_t)code, NOTIFY_AT * 4) == 0,
          "a notify outside the text section is refused");

    const uint32_t *call = &GET_WILDCARD_MAPPING[WILDCARD_LOOKUP_BL];
    check(np_compat_probe_windows_only_off((uintptr_t)GET_WILDCARD_MAPPING,
                                           bl_dest(call)) == 1,
          "the lookup call in GetWildcardMapping gives up its table");
    check(g_windows_only_off == 0x698, "the table is the call's first argument");

    g_windows_only_off = 0;
    check(np_compat_probe_windows_only_off((uintptr_t)GET_WILDCARD_MAPPING,
                                           bl_dest(call) + 4) == 0,
          "a lookup GetWildcardMapping never calls is refused");
    check(g_windows_only_off == 0, "a refused probe leaves no table");
}

#define TEST_USER_SIZE       0x10000
#define TEST_SHORTCUTS_OFF   0x5CC8
#define TEST_GATE_OFF        0x698
#define TEST_MANAGER_SIZE    0x800

typedef struct {
    uint8_t *mgr;
    uint8_t *user;
    uint8_t  nodes[3][32];
    uint8_t *shortcut[3];
} shortcut_world_t;

static const uint32_t world_appid[3] = { 0x80000002u, 0x80000001u, 0x80000003u };

static void put_node(shortcut_world_t *w, int i, int32_t left, int32_t right) {
    memcpy(w->nodes[i] + NODE_LEFT_OFF, &left, sizeof(left));
    memcpy(w->nodes[i] + NODE_RIGHT_OFF, &right, sizeof(right));
    memcpy(w->nodes[i] + 0x10, &world_appid[i], sizeof(uint32_t));
    memcpy(w->nodes[i] + 0x18, &w->shortcut[i], sizeof(uint8_t *));
}

static void set_exe(shortcut_world_t *w, int i, const char *exe) {
    memcpy(w->shortcut[i] + 0x10, &exe, sizeof(exe));
}

static void build_world(shortcut_world_t *w) {
    w->mgr  = calloc(1, TEST_MANAGER_SIZE);
    w->user = calloc(1, TEST_USER_SIZE);
    memcpy(w->mgr + COMPAT_MANAGER_USER_OFF, &w->user, sizeof(w->user));

    uint8_t *shortcuts = w->user + TEST_SHORTCUTS_OFF;
    memcpy(shortcuts, &g_vptr, sizeof(g_vptr));
    int32_t root = 0;
    memcpy(shortcuts + 0x38, &root, sizeof(root));
    uint8_t *nodes = &w->nodes[0][0];
    memcpy(shortcuts + 0x50, &nodes, sizeof(nodes));

    for (int i = 0; i < 3; i++) w->shortcut[i] = calloc(1, 0x80);
    put_node(w, 0, 1, 2);
    put_node(w, 1, NODE_NONE, NODE_NONE);
    put_node(w, 2, NODE_NONE, NODE_NONE);
}

static void free_world(shortcut_world_t *w) {
    for (int i = 0; i < 3; i++) free(w->shortcut[i]);
    free(w->user);
    free(w->mgr);
}

static void shortcut_exe_cases(void) {
    static const char vptr_target = 0;
    g_vptr = (uintptr_t)&vptr_target;
    atomic_store(&g_shortcuts_off, 0);
    atomic_store(&g_scan_missed, 0);

    shortcut_world_t w = {0};
    build_world(&w);

    set_exe(&w, 0, "\"C:\\Games\\Game.EXE\"");
    set_exe(&w, 1, "/Applications/Game/run.exe");
    set_exe(&w, 2, "\"/Applications/Game.app\"");

    check(np_usershortcuts_runs_exe(w.user, world_appid[0]), "a quoted browsed exe takes the default");
    check(atomic_load(&g_shortcuts_off) == TEST_SHORTCUTS_OFF,
          "the table is found inside CUser by its vptr");
    check(np_usershortcuts_runs_exe(w.user, world_appid[1]), "a typed unquoted exe takes the default");
    check(!np_usershortcuts_runs_exe(w.user, world_appid[2]), "a Mac app is left alone");
    check(!np_usershortcuts_runs_exe(w.user, 0x80000004u), "an appid with no shortcut is left alone");
    check(!np_usershortcuts_runs_exe(w.user, 0x00000002u), "a Steam appid is never a shortcut");
    check(!np_usershortcuts_runs_exe(NULL, world_appid[0]), "no user answers no");

    set_exe(&w, 2, "C:\\Games\\setup.Exe");
    check(np_usershortcuts_runs_exe(w.user, world_appid[2]), "the extension matches in any case");
    set_exe(&w, 2, "C:\\Games\\launch.exe.bat");
    check(!np_usershortcuts_runs_exe(w.user, world_appid[2]), "only the last extension counts");
    set_exe(&w, 2, "C:\\Games.exe\\launcher");
    check(!np_usershortcuts_runs_exe(w.user, world_appid[2]), "a dot in a folder name is no extension");
    set_exe(&w, 2, "");
    check(!np_usershortcuts_runs_exe(w.user, world_appid[2]), "an empty exe is left alone");
    set_exe(&w, 2, NULL);
    check(!np_usershortcuts_runs_exe(w.user, world_appid[2]), "a shortcut with no exe is left alone");
    set_exe(&w, 2, (const char *)(uintptr_t)0x10);
    check(!np_usershortcuts_runs_exe(w.user, world_appid[2]), "an exe pointer below 4 GB is not read");
    set_exe(&w, 2, &"C:\\Games\\setup.exe"[1]);
    check(np_usershortcuts_runs_exe(w.user, world_appid[2]), "an unaligned exe string is still read");

    put_node(&w, 2, NODE_NONE, 0);
    check(!np_usershortcuts_runs_exe(w.user, 0x80000004u), "a looping tree stops at the depth cap");
    put_node(&w, 2, NODE_NONE, -2);
    check(!np_usershortcuts_runs_exe(w.user, 0x80000004u), "a corrupt node index stops the walk");
    put_node(&w, 2, NODE_NONE, NODE_NONE);

    uint64_t remote = 0x1234;
    memcpy(w.shortcut[1] + 0x68, &remote, sizeof(remote));
    check(!np_usershortcuts_runs_exe(w.user, world_appid[1]), "a remote client's shortcut is left alone");
    remote = 0;
    memcpy(w.shortcut[1] + 0x68, &remote, sizeof(remote));

    check(np_compat_user(w.mgr) == w.user, "the manager hands over its CUser");
    g_windows_only_off = TEST_GATE_OFF;
    check(np_compat_is_windows_only_table(w.mgr, w.mgr + TEST_GATE_OFF),
          "the probed table is the windows-only one");
    check(!np_compat_is_windows_only_table(w.mgr, w.mgr + TEST_GATE_OFF - 0x60),
          "any other table is not");
    check(!np_compat_is_windows_only_table(NULL, w.mgr + TEST_GATE_OFF),
          "no manager has no table");
    g_windows_only_off = 0;
    check(!np_compat_is_windows_only_table(w.mgr, w.mgr),
          "without a probed table nothing matches");

    memset(w.user + TEST_SHORTCUTS_OFF, 0, sizeof(uintptr_t));
    atomic_store(&g_shortcuts_off, 0);
    check(!np_usershortcuts_runs_exe(w.user, world_appid[0]), "a CUser with no table answers no");
    check(atomic_load(&g_scan_missed) == (uintptr_t)w.user, "the failed search is remembered");

    uint8_t *other = calloc(1, TEST_USER_SIZE);
    memcpy(other + TEST_SHORTCUTS_OFF, w.user + TEST_SHORTCUTS_OFF, 0x60);
    memcpy(other + TEST_SHORTCUTS_OFF, &g_vptr, sizeof(g_vptr));
    check(np_usershortcuts_runs_exe(other, world_appid[0]), "a new CUser is searched again");

    int32_t empty = NODE_NONE;
    memcpy(other + TEST_SHORTCUTS_OFF + 0x38, &empty, sizeof(empty));
    check(!np_usershortcuts_runs_exe(other, world_appid[0]), "an empty tree has no shortcuts");
    free(other);

    free_world(&w);
}

// A manager big enough for the enabled flag and the logon flag right after it.
static uint8_t platform_mgr[0x1000];
static int checks_run, overrides_dropped, logon_launches, check_after_drop;
static uint32_t last_checked;

static uint32_t stub_app_platforms(void *mgr, uint32_t appid) {
    (void)mgr;
    if (appid >= 1000) return 0;
    return appid >= 500 ? COMPAT_PLATFORM_WINDOWS | COMPAT_PLATFORM_MACOS : COMPAT_PLATFORM_WINDOWS;
}

static void stub_set_override(void *mgr, uint32_t appid, const char *from, const char *to) {
    (void)mgr;
    if (!from[0] && !to[0]) { overrides_dropped++; last_checked = appid; }
}

static void stub_check(void *mgr, uint32_t appid) {
    if (last_checked == appid) check_after_drop++;
    checks_run++;
    // The real check asks BIsCompatibilityToolEnabled about the app, through the hook.
    np_compat_note_app(mgr, appid);
}

static void stub_launch_logon(void *mgr) {
    logon_launches++;
    ((uint8_t *)mgr)[0x811] = 1;
}

static void reset_platform_state(void) {
    memset(g_platform_seen, 0, sizeof g_platform_seen);
    g_platform_seen_count = g_platform_queued = 0;
    atomic_store(&g_platform_mgr, NULL);
    atomic_store(&g_platform_mode, PLATFORM_UNDECIDED);
    memset(platform_mgr, 0, sizeof platform_mgr);
    checks_run = overrides_dropped = logon_launches = check_after_drop = 0;
    last_checked = 0;
}

static void platform_cases(void) {
    g_enabled_off = 0x810;
    np_compat_set_valid_platforms_fn((uintptr_t)stub_app_platforms);

    for (int i = 0; i < CODE_WORDS; i++) code[i] = NOP;
    code[0] = 0xA9BE4FF4u;                          // stp x20, x19, [sp, #-0x20]!
    code[1] = 0x52800028u;                          // mov w8, #1
    code[2] = 0x39000000u | (0x20u << 10) | 8;      // strb w8, [x0, #0x20]
    np_compat_set_platform_fns((uintptr_t)stub_check, (uintptr_t)stub_set_override,
                               (uintptr_t)code);
    reset_platform_state();
    np_compat_note_app(platform_mgr, 1);
    check(g_platform_queued == 0, "a logon flag store too early in the object turns the catch-up off");

    code[2] = 0x39000000u | (0x811u << 10) | 31;    // strb wzr, [x0, #0x811]
    check(probe_logon_flag((uintptr_t)code) == 0, "a store of zero is not the logon flag");
    code[2] = 0x39000000u | (0x811u << 10) | (1u << 5) | 8;  // strb w8, [x1, #0x811]
    check(probe_logon_flag((uintptr_t)code) == 0, "a store through another register is not it");

    code[2] = 0x39000000u | (0x811u << 10) | 8;     // strb w8, [x0, #0x811]
    np_compat_set_platform_fns((uintptr_t)stub_check, (uintptr_t)stub_set_override,
                               (uintptr_t)code);
    check(g_logon_flag_off == 0x811, "the logon flag is read from the job's first store");
    np_compat_set_platform_fns((uintptr_t)stub_check, (uintptr_t)stub_set_override,
                               (uintptr_t)stub_launch_logon);
    g_logon_flag_off = 0x811;

    // A client whose logon job ran is left alone.
    reset_platform_state();
    platform_mgr[0x810] = 1;
    platform_mgr[0x811] = 1;
    np_compat_note_app(platform_mgr, 1);
    check(np_compat_platform_catch_up() == 0 && logon_launches == 0,
          "a client that ran its logon compat job gets no catch-up");
    check(np_compat_check_noted_apps() == 0 && checks_run == 0,
          "a client that ran its logon compat job has nothing checked");
    np_compat_note_app(platform_mgr, 2);
    check(g_platform_queued == 1, "nothing is queued once the client is known to be fine");

    // The layer is still off at the first look: the hooks never forced it, so no catch-up.
    reset_platform_state();
    np_compat_note_app(platform_mgr, 1);
    check(np_compat_platform_catch_up() == 0 && logon_launches == 0,
          "a client whose layer is off gets no catch-up");

    // Without SetAppPlatformOverride the catch-up stays off altogether.
    reset_platform_state();
    platform_mgr[0x810] = 1;
    g_set_platform_override = NULL;
    np_compat_note_app(platform_mgr, 1);
    check(g_platform_queued == 0 && np_compat_platform_catch_up() == 0,
          "a missing function turns the catch-up off");
    g_set_platform_override = stub_set_override;

    // One that logged on with the layer off.
    reset_platform_state();
    platform_mgr[0x810] = 1;
    check(np_compat_platform_catch_up() == 0, "no catch-up before any manager is seen");
    np_compat_note_app(platform_mgr, 1);
    np_compat_note_app(platform_mgr, 1);
    np_compat_note_app(platform_mgr, 600);
    np_compat_note_app(platform_mgr, 2000);
    check(g_platform_queued == 1, "only a Windows-only app is queued, and once");
    check(np_compat_platform_catch_up() == 1 && logon_launches == 1,
          "a client that skipped its logon compat job has it launched");
    check(np_compat_platform_catch_up() == 0 && logon_launches == 1, "the job is launched once");
    uint32_t installed[] = { 2, 3, 1, 600 };
    np_compat_note_apps(installed, 4);
    check(g_platform_queued == 3, "installed Windows-only apps join the queue");
    check(np_compat_check_noted_apps() == 3 && checks_run == 3 && overrides_dropped == 3,
          "every queued app has its override dropped and is checked");
    check(check_after_drop == 3, "each check follows the drop of that app's override");
    check(g_platform_queued == 0, "an app the check asks about is not queued again");
    check(np_compat_check_noted_apps() == 0, "an empty queue checks nothing");

    // The batch limit spreads a big library over several jobs.
    reset_platform_state();
    platform_mgr[0x810] = 1;
    np_compat_note_app(platform_mgr, 1);
    np_compat_platform_catch_up();
    for (uint32_t id = 10; id < 10 + NP_COMPAT_PLATFORM_CHECK_BATCH + 5; id++)
        np_compat_note_app(platform_mgr, id);
    check(np_compat_check_noted_apps() == NP_COMPAT_PLATFORM_CHECK_BATCH,
          "one job checks at most a batch");
    check(np_compat_check_noted_apps() == 6, "the next job checks the rest");

    reset_platform_state();
    g_enabled_off = COMPAT_MANAGER_ENABLED_OFF;
    g_get_valid_platforms = NULL;
}

int main(void) {
    confirm_layout();   // the reference layout, unless a case says otherwise
    concurrent_fallback_cases();
    probe_cases();
    head_cases();
    oslist_cases();
    enabled_cases();
    manager_cases();
    registration_cases();
    tool_list_cases();
    tool_launch_cases();
    stale_tool_cases();
    installed_fn_cases();
    platform_cases();
    shortcut_probe_cases();
    shortcut_exe_cases();

    if (failures) {
        printf("==> compat: %d check(s) failed\n", failures);
        return 1;
    }
    printf("==> compat: layout probes hold, the tool array walk is bounded, "
           "installed functions answer\n");
    return 0;
}
