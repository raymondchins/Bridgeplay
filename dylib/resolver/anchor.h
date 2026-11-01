// Anchor-based function resolution
#ifndef NOTPROTON_RESOLVER_ANCHOR_H
#define NOTPROTON_RESOLVER_ANCHOR_H

#include <stdint.h>
#include <stddef.h>
#include <mach-o/loader.h>

typedef enum {
    NP_MATCH_NONE = 0,
    NP_MATCH_STRING,             // entry point that loads one unique C string
    NP_MATCH_VTABLE_SLOT,        // pointer parked at a fixed data address
    NP_MATCH_INSN_AFTER_STRING,  // the instruction one past the Nth BLR,
                                  // counting from a string load
    NP_MATCH_INSN_PAIR_IN_FN,    // the sole adjacent opcode pair inside the function
                                  // a string reference identifies
    NP_MATCH_AOB,
    NP_MATCH_CALL_TARGET,
    NP_MATCH_CALLS,
} np_match_kind_t;

#define NP_CALL_PATH_MAX 4

// Selectors use the NP_SELECTOR_MARK prefix.
#define NP_CALLS_MAX      8
#define NP_CALL_NAME_MAX  96
#define NP_SELECTOR_MARK  '@'

typedef struct {
    uint32_t first, first_mask;
    uint32_t second, second_mask;
    uint32_t tie_mask;
    int      land_on_second;
} np_insn_pair_t;

typedef struct {
    np_match_kind_t kind;
    char             str[256];   // the referenced string, for the two string kinds
    uintptr_t        va;         // unslid data address of the vtable slot
    int              nth;        // 1-based index of the wanted opcode match

    int              nth_xref;

    np_insn_pair_t   pair;       // for NP_MATCH_INSN_PAIR_IN_FN

    // Some functions reach their string through a pointer slot (ADRP+LDR)
    // instead of materialising its address (ADRP+ADD). ObjC selector stubs
    // are the most common example.
    int              indirect;

    int              caller_hops;
    int              caller_tail;

    int              call_path[NP_CALL_PATH_MAX];
    int              call_depth;

    char             calls[NP_CALLS_MAX][NP_CALL_NAME_MAX];
    int              call_count;
    int              calls_exact;    // the body makes these calls and no others
    int              no_data_refs;   // reject ADRP instructions
} np_anchor_t;

// Upper bound on a function body when scanning for a pair.
#define NP_FN_SPAN_MAX 0x400

// Resolve an anchor to a runtime address (slide applied), or 0.
uintptr_t np_locate_anchor(const struct mach_header_64 *mh, intptr_t slide,
                            uintptr_t text_base, size_t text_size,
                            const np_anchor_t *anchor);

uintptr_t np_rtti_vptr(const struct mach_header_64 *mh, intptr_t slide,
                       uintptr_t text_base, size_t text_size,
                       const char *type_name);

#endif // NOTPROTON_RESOLVER_ANCHOR_H
