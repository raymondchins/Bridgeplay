#include "macho.h"
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <sys/mman.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t g_await_stop;

void np_await_stop(void) {
    g_await_stop = 1;
}

static int image_index_by_name(const char *needle) {
    uint32_t n = _dyld_image_count();
    for (uint32_t idx = 0; idx < n; idx++) {
        const char *path = _dyld_get_image_name(idx);
        if (path && strstr(path, needle))
            return (int)idx;
    }
    return -1;
}

int np_await_image(const char *name, int timeout_ms,
                         const struct mach_header_64 **out_mh, intptr_t *out_slide) {
    for (int waited = 0; waited < timeout_ms; waited += 100) {
        if (g_await_stop) return -1;

        int idx = image_index_by_name(name);
        if (idx >= 0) {
            *out_mh    = (const struct mach_header_64 *)_dyld_get_image_header((uint32_t)idx);
            *out_slide = _dyld_get_image_vmaddr_slide((uint32_t)idx);
            return 0;
        }
        usleep(100000);
    }
    return -1;
}

static const struct load_command *lc_at(const struct mach_header_64 *mh,
                                        const uint8_t *cursor) {
    const uint8_t *lc_end = (const uint8_t *)(mh + 1) + mh->sizeofcmds;
    if (cursor > lc_end || (size_t)(lc_end - cursor) < sizeof(struct load_command))
        return NULL;

    const struct load_command *lc = (const struct load_command *)cursor;
    if (lc->cmdsize < sizeof(*lc) || lc->cmdsize > (size_t)(lc_end - cursor))
        return NULL;
    return lc;
}

int np_find_segment(const struct mach_header_64 *mh, intptr_t slide,
                   const char *segname, uintptr_t *out_base, size_t *out_size) {
    if (!mh || !segname) return -1;

    const uint8_t *cursor = (const uint8_t *)(mh + 1);
    uint32_t remaining = mh->ncmds;

    while (remaining--) {
        const struct load_command *lc = lc_at(mh, cursor);
        if (!lc)
            return -1;   // corrupt or truncated
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)cursor;
            if (strncmp(sc->segname, segname, sizeof(sc->segname)) == 0) {
                *out_base = (uintptr_t)sc->vmaddr + (uintptr_t)slide;
                *out_size = (size_t)sc->vmsize;
                return 0;
            }
        }
        cursor += lc->cmdsize;
    }
    return -1;
}

static const uint8_t *fn_starts_table(const struct mach_header_64 *mh,
                                      intptr_t slide, size_t *out_size) {
    const uint8_t *cursor = (const uint8_t *)(mh + 1);
    uint32_t remaining = mh->ncmds;

    const struct linkedit_data_command *fs = NULL;
    uint64_t le_vmaddr = 0, le_fileoff = 0, le_filesize = 0;
    int have_le = 0;

    while (remaining--) {
        const struct load_command *lc = lc_at(mh, cursor);
        if (!lc) return NULL;

        if (lc->cmd == LC_FUNCTION_STARTS && lc->cmdsize >= sizeof(*fs)) {
            fs = (const struct linkedit_data_command *)cursor;
        } else if (lc->cmd == LC_SEGMENT_64 &&
                   lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)cursor;
            if (strncmp(sc->segname, SEG_LINKEDIT, sizeof(sc->segname)) == 0) {
                le_vmaddr   = sc->vmaddr;
                le_fileoff  = sc->fileoff;
                le_filesize = sc->filesize;
                have_le     = 1;
            }
        }
        cursor += lc->cmdsize;
    }

    if (!fs || !have_le || !fs->datasize) return NULL;
    if (fs->dataoff < le_fileoff) return NULL;

    uint64_t rel = (uint64_t)fs->dataoff - le_fileoff;
    if (rel > le_filesize || (uint64_t)fs->datasize > le_filesize - rel) return NULL;

    *out_size = fs->datasize;
    return (const uint8_t *)(uintptr_t)(le_vmaddr + rel + (uint64_t)slide);
}

int np_function_bounds(const struct mach_header_64 *mh, intptr_t slide,
                       uintptr_t addr, uintptr_t *out_start, uintptr_t *out_end) {
    if (!mh || !out_start || !out_end) return -1;

    size_t size = 0;
    const uint8_t *p = fn_starts_table(mh, slide, &size);
    if (!p) return -1;

    const uint8_t *end = p + size;
    uintptr_t va = (uintptr_t)mh;
    uintptr_t start = 0;

    while (p < end) {
        uint64_t delta = 0;
        unsigned shift = 0;
        int complete = 0;

        while (p < end) {
            uint8_t b = *p++;
            if (shift < 64) delta |= (uint64_t)(b & 0x7F) << shift;
            shift += 7;
            if (!(b & 0x80)) { complete = 1; break; }
        }
        if (!complete) break;
        if (!delta) break;

        va += (uintptr_t)delta;
        if (va <= addr) {
            start = va;
            continue;
        }
        if (!start) return -1;
        *out_start = start;
        *out_end   = va;
        return 0;
    }

    return -1;
}

int np_get_section_containing(const struct mach_header_64 *mh, intptr_t slide,
                             uintptr_t addr, uintptr_t *out_base,
                             size_t *out_size) {
    if (!mh || !out_base || !out_size) return -1;

    const uint8_t *cursor = (const uint8_t *)(mh + 1);
    uint32_t remaining = mh->ncmds;

    while (remaining--) {
        const struct load_command *lc = lc_at(mh, cursor);
        if (!lc)
            return -1;   // corrupt or truncated
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *sc =
                (const struct segment_command_64 *)cursor;

            if (lc->cmdsize - sizeof(*sc) < (uint64_t)sc->nsects * sizeof(struct section_64))
                return -1;

            const struct section_64 *sect = (const struct section_64 *)(sc + 1);
            for (uint32_t i = 0; i < sc->nsects; i++) {
                uintptr_t base = (uintptr_t)sect[i].addr + (uintptr_t)slide;
                if (addr < base || addr >= base + (uintptr_t)sect[i].size)
                    continue;
                *out_base = base;
                *out_size = (size_t)sect[i].size;
                return 0;
            }
        }
        cursor += lc->cmdsize;
    }
    return -1;
}

int np_find_section(const struct mach_header_64 *mh, intptr_t slide,
                    const char *segname, const char *sectname,
                    uintptr_t *out_base, size_t *out_size) {
    if (!mh || !segname || !sectname || !out_base || !out_size) return -1;

    const uint8_t *cursor = (const uint8_t *)(mh + 1);
    uint32_t remaining = mh->ncmds;

    while (remaining--) {
        const struct load_command *lc = lc_at(mh, cursor);
        if (!lc)
            return -1;
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *sc =
                (const struct segment_command_64 *)cursor;

            if (lc->cmdsize - sizeof(*sc) < (uint64_t)sc->nsects * sizeof(struct section_64))
                return -1;

            if (strncmp(sc->segname, segname, sizeof(sc->segname)) == 0) {
                const struct section_64 *sect = (const struct section_64 *)(sc + 1);
                for (uint32_t i = 0; i < sc->nsects; i++) {
                    if (strncmp(sect[i].sectname, sectname, sizeof(sect[i].sectname)) != 0)
                        continue;
                    *out_base = (uintptr_t)sect[i].addr + (uintptr_t)slide;
                    *out_size = (size_t)sect[i].size;
                    return 0;
                }
            }
        }
        cursor += lc->cmdsize;
    }
    return -1;
}

typedef struct {
    const struct nlist_64 *syms;
    uint32_t               nsyms;
    const char            *strings;
    uint32_t               strsize;
    const uint32_t        *indirect;
    uint32_t               nindirect;
} symbols_t;

static int in_linkedit(const struct segment_command_64 *le,
                       uint64_t fileoff, uint64_t len) {
    if (fileoff < le->fileoff) return 0;
    uint64_t rel = fileoff - le->fileoff;
    return rel <= le->filesize && len <= le->filesize - rel;
}

static int load_symbols(const struct mach_header_64 *mh, intptr_t slide,
                        symbols_t *out) {
    const struct symtab_command     *symtab   = NULL;
    const struct dysymtab_command   *dysymtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const uint8_t *cursor = (const uint8_t *)(mh + 1);

    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = lc_at(mh, cursor);
        if (!lc)
            return -1;
        if (lc->cmd == LC_SYMTAB && lc->cmdsize >= sizeof(struct symtab_command))
            symtab = (const struct symtab_command *)cursor;
        else if (lc->cmd == LC_DYSYMTAB && lc->cmdsize >= sizeof(struct dysymtab_command))
            dysymtab = (const struct dysymtab_command *)cursor;
        else if (lc->cmd == LC_SEGMENT_64
                 && lc->cmdsize >= sizeof(struct segment_command_64)
                 && strcmp(((const struct segment_command_64 *)cursor)->segname, SEG_LINKEDIT) == 0)
            linkedit = (const struct segment_command_64 *)cursor;
        cursor += lc->cmdsize;
    }
    if (!symtab || !dysymtab || !linkedit || !dysymtab->nindirectsyms)
        return -1;

    if (!in_linkedit(linkedit, symtab->symoff, (uint64_t)symtab->nsyms * sizeof(struct nlist_64)) ||
        !in_linkedit(linkedit, symtab->stroff, symtab->strsize) ||
        !in_linkedit(linkedit, dysymtab->indirectsymoff,
                     (uint64_t)dysymtab->nindirectsyms * sizeof(uint32_t)))
        return -1;

    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    out->syms      = (const struct nlist_64 *)(base + symtab->symoff);
    out->nsyms     = symtab->nsyms;
    out->strings   = (const char *)(base + symtab->stroff);
    out->strsize   = symtab->strsize;
    out->indirect  = (const uint32_t *)(base + dysymtab->indirectsymoff);
    out->nindirect = dysymtab->nindirectsyms;
    return 0;
}

static const char *indirect_symbol_name(const symbols_t *syms, uint64_t slot) {
    if (slot >= syms->nindirect) return NULL;

    uint32_t index = syms->indirect[slot];
    if (index & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) return NULL;
    if (index >= syms->nsyms) return NULL;

    uint32_t strx = syms->syms[index].n_un.n_strx;
    if (strx >= syms->strsize) return NULL;
    return syms->strings + strx;
}

// reserved2 is the stub stride, reserved1 the first indirect-symbol index.
static int is_stub_section(const struct section_64 *sect) {
    return (sect->flags & SECTION_TYPE) == S_SYMBOL_STUBS && sect->reserved2 != 0;
}

static const struct section_64 *segment_sections(const struct load_command *lc,
                                                 uint32_t *out_count) {
    if (lc->cmdsize < sizeof(struct segment_command_64))
        return NULL;

    const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
    if (lc->cmdsize - sizeof(*seg) < (uint64_t)seg->nsects * sizeof(struct section_64))
        return NULL;
    *out_count = seg->nsects;
    return (const struct section_64 *)(seg + 1);
}

const char *np_import_stub_symbol(const struct mach_header_64 *mh, intptr_t slide,
                                  uintptr_t stub) {
    symbols_t syms;
    if (!mh || !stub || load_symbols(mh, slide, &syms) != 0) return NULL;

    const uint8_t *cursor = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = lc_at(mh, cursor);
        if (!lc) return NULL;
        cursor += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64) continue;

        uint32_t nsects = 0;
        const struct section_64 *sect = segment_sections(lc, &nsects);
        if (!sect) return NULL;

        for (uint32_t j = 0; j < nsects; j++, sect++) {
            if (!is_stub_section(sect)) continue;

            uintptr_t base = (uintptr_t)sect->addr + (uintptr_t)slide;
            if (stub < base || stub >= base + (uintptr_t)sect->size) continue;

            uintptr_t offset = stub - base;
            if (offset % sect->reserved2) return NULL;
            return indirect_symbol_name(&syms,
                                        (uint64_t)sect->reserved1 +
                                        offset / sect->reserved2);
        }
    }
    return NULL;
}

uintptr_t np_import_stub_for_symbol(const struct mach_header_64 *mh, intptr_t slide,
                                    const char *symbol) {
    symbols_t syms;
    if (!mh || !symbol || !*symbol || load_symbols(mh, slide, &syms) != 0) return 0;

    uintptr_t found = 0;
    const uint8_t *cursor = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = lc_at(mh, cursor);
        if (!lc) return 0;
        cursor += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64) continue;

        uint32_t nsects = 0;
        const struct section_64 *sect = segment_sections(lc, &nsects);
        if (!sect) return 0;

        for (uint32_t j = 0; j < nsects; j++, sect++) {
            if (!is_stub_section(sect)) continue;

            uintptr_t base  = (uintptr_t)sect->addr + (uintptr_t)slide;
            uint64_t  count = sect->size / sect->reserved2;
            for (uint64_t k = 0; k < count; k++) {
                const char *name = indirect_symbol_name(&syms,
                                                        (uint64_t)sect->reserved1 + k);
                if (!name || strcmp(name, symbol) != 0) continue;
                if (found) return 0;
                found = base + (uintptr_t)(k * sect->reserved2);
            }
        }
    }
    return found;
}

int np_rebind_import(const struct mach_header_64 *mh, intptr_t slide,
                     const char *symbol, void *replacement) {
    if (!mh || !symbol || !replacement) return -1;

    symbols_t syms;
    if (load_symbols(mh, slide, &syms) != 0)
        return -1;

    int rebound = 0;
    const uint8_t *cursor = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = lc_at(mh, cursor);
        if (!lc)
            return -1;
        cursor += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64)
            continue;

        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        uint32_t nsects = 0;
        const struct section_64 *sect = segment_sections(lc, &nsects);
        if (!sect)
            return -1;
        for (uint32_t j = 0; j < nsects; j++, sect++) {
            uint32_t type = sect->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS)
                continue;

            void **slots = (void **)((uintptr_t)slide + sect->addr);
            for (uint64_t k = 0; k < sect->size / sizeof(void *); k++) {
                const char *name = indirect_symbol_name(&syms,
                                                        (uint64_t)sect->reserved1 + k);
                if (!name || strcmp(name, symbol) != 0)
                    continue;

                // __DATA_CONST is read-only once dyld is done with it.
                uintptr_t page = (uintptr_t)&slots[k] & ~(uintptr_t)(getpagesize() - 1);
                if (mprotect((void *)page, (size_t)getpagesize(), PROT_READ | PROT_WRITE) != 0)
                    continue;
                slots[k] = replacement;
                if (strcmp(seg->segname, "__DATA_CONST") == 0)
                    mprotect((void *)page, (size_t)getpagesize(), PROT_READ);
                rebound++;
            }
        }
    }
    return rebound;
}
