// Anchor validation. Resolves every sig in every database against the loaded
// steamclient.dylib by the same path the dylib uses, then checks each against the address
// and bytes recorded when the database was cut. Loaded rather than on disk because dyld
// rebases and ObjC rewrites selector slots. Other builds must land on the live addresses.
// Usage: out/anchorcheck [--client-dir DIR] [--build N] [path-to-sigdb.json ...]
//        out/anchorcheck [--client-dir DIR] --rebase TEMPLATE OUT   (see rebase_fixture)
// --client-dir loads the modules from DIR instead of the installed client, e.g. Valve's
// packages unzipped into one folder (scripts/steam-canary.py). --build names the client's
// build, so the database for it is the one held to its recorded addresses, and none is when
// none has that build; without it the build is recognised from the addresses (pick_live).

#include "cJSON.h"
#include "../util/file.h"
#include "../resolver/sigdb.h"
#include "../resolver/resolver.h"
#include "../resolver/anchor.h"
#include "../resolver/aob.h"
#include "../core/macho.h"

#include <dirent.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define STEAM_MACOS \
    "/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/"
#define MAX_IMAGES 4
#define SIGDB_DIR "signatures/macos.arm64"
#define MAX_DBS   16

// Locate the loaded image whose name ends with `suffix`.
static const struct mach_header_64 *find_image(const char *suffix,
                                               intptr_t *slide_out,
                                               const char **path_out) {
    size_t want = strlen(suffix);
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        size_t len = strlen(name);
        if (len < want) continue;
        if (strcmp(name + len - want, suffix) != 0) continue;
        *slide_out = _dyld_get_image_vmaddr_slide(i);
        *path_out  = name;
        return (const struct mach_header_64 *)_dyld_get_image_header(i);
    }
    return NULL;
}

typedef struct {
    char                          module[64];
    const struct mach_header_64  *mh;
    intptr_t                      slide;
    uintptr_t                     text;
    size_t                        text_sz;
    const char                   *path;
} image_t;

static image_t g_images[MAX_IMAGES];
static int     g_image_count;
static const char *g_client_dir;

static const image_t *image_for(const char *module) {
    for (int i = 0; i < g_image_count; i++)
        if (strcmp(g_images[i].module, module) == 0) return &g_images[i];
    return NULL;
}

static int load_image(const char *module) {
    if (image_for(module)) return 0;
    if (g_image_count >= MAX_IMAGES) return -1;

    char path[1024], suffix[128];
    if (g_client_dir) {
        snprintf(path, sizeof(path), "%s/%s", g_client_dir, module);
    } else {
        const char *home = getenv("HOME");
        snprintf(path, sizeof(path), "%s%s%s", home ? home : "", STEAM_MACOS, module);
    }
    snprintf(suffix, sizeof(suffix), "/%s", module);

    if (!dlopen(path, RTLD_LAZY | RTLD_LOCAL)) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return -1;
    }

    image_t *im = &g_images[g_image_count];
    im->mh = find_image(suffix, &im->slide, &im->path);
    if (!im->mh) {
        fprintf(stderr, "%s not found after dlopen\n", module);
        return -1;
    }
    if (np_find_segment(im->mh, im->slide, "__TEXT", &im->text, &im->text_sz) != 0) {
        fprintf(stderr, "%s has no __TEXT\n", module);
        return -1;
    }
    snprintf(im->module, sizeof(im->module), "%s", module);
    g_image_count++;

    printf("image  : %s\n", im->path);
    printf("slide  : 0x%lx\n", (unsigned long)im->slide);
    printf("__TEXT : 0x%lx (%zu bytes)\n\n", im->text, im->text_sz);
    return 0;
}

// An independent read on the anchor result, meaningful only against the build the
// pattern was recorded from.
static uintptr_t resolve_by_aob(np_sig_entry_t *sig,
                                uintptr_t text, size_t text_sz) {
    return np_aob_site(sig, text, text_sz);
}

static const char *kind_name(np_match_kind_t k) {
    switch (k) {
        case NP_MATCH_STRING:            return "string";
        case NP_MATCH_VTABLE_SLOT:       return "vtable_slot";
        case NP_MATCH_INSN_AFTER_STRING: return "insn_after_string";
        case NP_MATCH_INSN_PAIR_IN_FN:   return "insn_pair";
        case NP_MATCH_AOB:               return "aob";
        case NP_MATCH_CALL_TARGET:       return "call_target";
        case NP_MATCH_CALLS:             return "calls";
        default:                          return "none";
    }
}

// Addresses are reported unslid throughout, so they can be pasted into a
// disassembler.
typedef struct {
    const char     *name;
    np_match_kind_t kind;
    uintptr_t       anchor;
    uintptr_t       recorded;
    uintptr_t       aob;
    int             has_pattern;
} row_t;

typedef struct {
    char      path[512];
    uint64_t  build;
    np_sigdb_t sigdb;
    row_t    *rows;
    int       count;
    int       unresolved;
    int       recorded_match;
    int       recorded_total;
    int       loaded;
} dbcheck_t;

// Class vptrs per client build, read off the disassembly. These address data rather than
// code, so they are not signatures and get checked separately. The CompatManager message
// classes arrived with 1789086785, so the older build has only the one row.
static const struct { uint64_t build; const char *type_name; uintptr_t vptr; } expected_vptr[] = {
    {1788400362, "14CCompatManager",                              0x1715a00},

    {1789086785, "14CCompatManager",                              0x1743ed0},
    {1789086785, "21CMsgCompatManagerTool",                       0x16ad000},
    {1789086785, "22CMsgCompatManagerAlias",                      0x16ad0b0},
    {1789086785, "37CCompatManager_GetCompatTools_Request",        0x16ad160},
    {1789086785, "38CCompatManager_GetCompatTools_Response",       0x16ad210},
    {1789086785, "40CCompatManager_SpecifyCompatTool_Request",     0x16ad2c0},
    {1789086785, "41CCompatManager_SpecifyCompatTool_Response",    0x16ad370},
    {1789086785, "40CCompatManager_StateChanged_Notification",     0x16ad420},

    {1790904859, "14CCompatManager",                              0x1743d20},
    {1790904859, "21CMsgCompatManagerTool",                       0x16acff0},
    {1790904859, "22CMsgCompatManagerAlias",                      0x16ad0a0},
    {1790904859, "37CCompatManager_GetCompatTools_Request",        0x16ad150},
    {1790904859, "38CCompatManager_GetCompatTools_Response",       0x16ad200},
    {1790904859, "40CCompatManager_SpecifyCompatTool_Request",     0x16ad2b0},
    {1790904859, "41CCompatManager_SpecifyCompatTool_Response",    0x16ad360},
    {1790904859, "40CCompatManager_StateChanged_Notification",     0x16ad410},
    {1790904859, "14CUserShortcuts",                              0x1793de0},
};

static int run_rtti(const struct mach_header_64 *mh, intptr_t slide,
                    uintptr_t text, size_t text_sz, uint64_t build) {
    int ok = 0, bad = 0, checked = 0;

    for (size_t i = 0; i < sizeof(expected_vptr) / sizeof(expected_vptr[0]); i++) {
        if (expected_vptr[i].build != build) continue;
        checked++;

        const char *name = expected_vptr[i].type_name;
        uintptr_t got = np_rtti_vptr(mh, slide, text, text_sz, name);
        unsigned long got_u = got ? (unsigned long)(got - (uintptr_t)slide) : 0;
        unsigned long want  = (unsigned long)expected_vptr[i].vptr;

        const char *verdict = !got ? "UNRESOLVED" : (got_u == want ? "OK" : "WRONG");
        if (got && got_u == want) ok++; else bad++;

        printf("%-48s vptr=0x%-9lx want=0x%-9lx %s\n", name, got_u, want, verdict);
    }

    if (!checked) {
        printf("no vptr expectations recorded for build %llu\n", (unsigned long long)build);
        return 0;
    }
    printf("\n%d vptr correct, %d incorrect (of %d)\n", ok, bad, checked);
    return bad ? 1 : 0;
}

static int ends_with_json(const char *name) {
    size_t n = strlen(name);
    return n > 5 && strcmp(name + n - 5, ".json") == 0;
}

// Every database in the signature directory, sorted by name so the output runs
// oldest build first.
static int collect_dbs(char paths[][512], int max) {
    DIR *dh = opendir(SIGDB_DIR);
    if (!dh) return 0;

    int n = 0;
    struct dirent *e;
    while ((e = readdir(dh)) != NULL && n < max) {
        if (e->d_name[0] == '.' || !ends_with_json(e->d_name)) continue;
        snprintf(paths[n], 512, "%s/%s", SIGDB_DIR, e->d_name);
        n++;
    }
    closedir(dh);

    for (int i = 1; i < n; i++) {
        char tmp[512];
        snprintf(tmp, sizeof(tmp), "%s", paths[i]);
        int j = i - 1;
        while (j >= 0 && strcmp(paths[j], tmp) > 0) {
            snprintf(paths[j + 1], 512, "%s", paths[j]);
            j--;
        }
        snprintf(paths[j + 1], 512, "%s", tmp);
    }
    return n;
}

// One database against the live image: what its anchors found, and what its
// recorded evidence claims.
static int check_db(dbcheck_t *db) {
    if (!db->loaded && np_load_profile(db->path, &db->sigdb) != 0) {
        fprintf(stderr, "cannot load sigdb '%s'\n", db->path);
        return -1;
    }
    db->build = db->sigdb.steam_build;
    db->count = db->sigdb.sig_count;
    db->rows  = calloc((size_t)db->count, sizeof(row_t));
    if (!db->rows) { fprintf(stderr, "out of memory\n"); return -1; }

    for (int i = 0; i < db->count; i++) {
        np_sig_entry_t *sig = &db->sigdb.signatures[i];
        row_t *r = &db->rows[i];

        r->name        = sig->name;
        r->kind        = sig->anchor.kind;
        r->recorded    = sig->func_addr_this_build;
        r->has_pattern = sig->aob_hex[0] != '\0';

        const image_t *im = image_for(sig->module);
        if (!im) {
            fprintf(stderr, "no image loaded for module '%s'\n", sig->module);
            return -1;
        }

        uintptr_t anc = (sig->anchor.kind == NP_MATCH_NONE)
                          ? 0
                          : np_locate_anchor(im->mh, im->slide, im->text, im->text_sz,
                                             &sig->anchor);
        uintptr_t aob = resolve_by_aob(sig, im->text, im->text_sz);

        r->anchor = anc ? anc - (uintptr_t)im->slide : 0;
        r->aob    = aob ? aob - (uintptr_t)im->slide : 0;

        if (!r->anchor) db->unresolved++;
        if (r->recorded) {
            db->recorded_total++;
            if (r->anchor == r->recorded) db->recorded_match++;
        }
    }
    return 0;
}

static int check_aob_fallback(const char *path) {
    np_sigdb_t db = {0};
    if (np_load_profile(path, &db) != 0) {
        fprintf(stderr, "cannot reload sigdb '%s'\n", path);
        return 1;
    }
    for (int i = 0; i < db.sig_count; i++) {
        db.signatures[i].anchor.str[0]      = '\001';
        db.signatures[i].anchor.str[1]      = '\0';
        db.signatures[i].anchor.va          = 0;
        db.signatures[i].anchor.calls[0][0] = '\001';
    }

    int bad = 0, checked = 0;
    printf("byte-pattern fallback with every anchor forced to miss\n");
    for (int m = 0; m < g_image_count; m++) {
        np_resolve_result_t res = {0};
        np_resolve_signatures(g_images[m].mh, g_images[m].slide, &db,
                              g_images[m].module, &res);

        for (int i = 0; i < db.sig_count; i++) {
            np_sig_entry_t *sig = &db.signatures[i];
            if (strcmp(sig->module, g_images[m].module) != 0) continue;
            if (sig->deprecated || !sig->aob_hex[0] || !sig->func_addr_this_build) continue;

            uintptr_t got  = np_lookup_address(&res, sig->name);
            uintptr_t want = sig->func_addr_this_build + (uintptr_t)g_images[m].slide;
            checked++;
            if (!got) {
                printf("  %-56s recorded=0x%-9lx  PATTERN DID NOT RESOLVE\n",
                       sig->name, (unsigned long)sig->func_addr_this_build);
                bad++;
            } else if (got != want) {
                printf("  %-56s aob=0x%-9lx recorded=0x%-9lx  WRONG ADDRESS\n",
                       sig->name, (unsigned long)(got - (uintptr_t)g_images[m].slide),
                       (unsigned long)sig->func_addr_this_build);
                bad++;
            }
        }
        np_free_resolution(&res);
    }
    printf("  %d signatures with a pattern and a recorded address, %d wrong\n\n",
           checked, bad);
    np_free_profile(&db);
    return bad;
}

static int pick_by_build(const dbcheck_t *dbs, int n, uint64_t build) {
    for (int i = 0; i < n; i++)
        if (dbs[i].build == build) return i;
    return -1;
}

// The database whose recorded addresses the anchors actually landed on describes
// the running client. Nothing in the app bundle reports the client build, so it
// has to be recognised rather than read.
static int pick_live(const dbcheck_t *dbs, int n) {
    int best = -1, best_hits = 0;
    for (int i = 0; i < n; i++) {
        if (dbs[i].recorded_match > best_hits) {
            best_hits = dbs[i].recorded_match;
            best = i;
        }
    }
    return best_hits ? best : -1;
}

static int report_db(const dbcheck_t *db, int is_live, int misses_excused) {
    int bad = 0;

    printf("%s  build %llu%s\n", db->path, (unsigned long long)db->build,
           is_live ? "  [live client]" : "");

    for (int i = 0; i < db->count; i++) {
        const row_t *r = &db->rows[i];
        const char *verdict;

        if (r->kind == NP_MATCH_NONE)          { verdict = "NO ANCHOR";     bad++; }
        else if (!r->anchor)                   { verdict = (r->has_pattern && r->aob)
                                                             ? "ANCHOR FAILED (aob resolves)"
                                                             : "ANCHOR FAILED";
                                                 if (!misses_excused) bad++; }
        else if (!is_live)                     { verdict = (r->has_pattern && r->aob && r->aob != r->anchor)
                                                             ? "stale pattern hit elsewhere"
                                                             : "resolved";           }
        else if (r->recorded && r->anchor != r->recorded) {
                                                 verdict = "WRONG";         bad++; }
        else if (!r->recorded)                 { verdict = "no recorded address";  }
        else if (r->has_pattern && r->aob != r->anchor) {
                                                 verdict = "AOB DISAGREES"; bad++; }
        else                                   { verdict = "OK";                   }

        printf("  %-56s %-13s anchor=0x%-8lx recorded=0x%-8lx aob=0x%-8lx  %s\n",
               r->name, kind_name(r->kind), (unsigned long)r->anchor,
               (unsigned long)r->recorded, (unsigned long)r->aob, verdict);
    }

    printf("  %d anchors resolved, %d unresolved", db->count - db->unresolved, db->unresolved);
    if (is_live)
        printf("; %d of %d recorded addresses matched\n", db->recorded_match, db->recorded_total);
    else
        printf("; recorded addresses and patterns describe another build\n");
    printf("\n");
    return bad;
}

// An anchor that finds a different function depending on which database it was
// read from would make the resolution order matter, and the dylib loads only one.
static int report_cross_db(const dbcheck_t *dbs, int n) {
    int bad = 0;
    for (int i = 0; i < n; i++) {
        for (int r = 0; r < dbs[i].count; r++) {
            const row_t *a = &dbs[i].rows[r];
            if (!a->anchor) continue;

            for (int j = i + 1; j < n; j++) {
                for (int s = 0; s < dbs[j].count; s++) {
                    const row_t *b = &dbs[j].rows[s];
                    if (strcmp(a->name, b->name) != 0 || !b->anchor) continue;
                    if (a->anchor == b->anchor) continue;

                    printf("CROSS-DB DISAGREEMENT %-40s %llu=0x%lx %llu=0x%lx\n",
                           a->name, (unsigned long long)dbs[i].build,
                           (unsigned long)a->anchor,
                           (unsigned long long)dbs[j].build,
                           (unsigned long)b->anchor);
                    bad++;
                }
            }
        }
    }
    if (bad) printf("\n");
    return bad;
}

// The first data slot holding `fn`, read after dyld has bound the image.
static uintptr_t data_slot_holding(const image_t *im, uintptr_t fn) {
    static const char *const segs[] = {"__DATA_CONST", "__AUTH_CONST", "__DATA"};
    for (size_t s = 0; s < sizeof(segs) / sizeof(segs[0]); s++) {
        uintptr_t base;
        size_t size;
        if (np_find_segment(im->mh, im->slide, segs[s], &base, &size) != 0) continue;
        for (size_t off = 0; off + sizeof(uintptr_t) <= size; off += sizeof(uintptr_t))
            if (*(const uintptr_t *)(base + off) == fn) return base + off;
    }
    return 0;
}

// The shortest exact run of bytes from `fn` that occurs nowhere else in __TEXT.
static int sole_pattern_at(const image_t *im, uintptr_t fn, char *out, size_t out_sz) {
    for (size_t len = 16; len <= 256 && len * 3 <= out_sz; len += 4) {
        if (fn + len > im->text + im->text_sz) return -1;
        size_t pos = 0;
        for (size_t i = 0; i < len; i++)
            pos += (size_t)snprintf(out + pos, out_sz - pos, i ? " %02X" : "%02X",
                                    ((const uint8_t *)fn)[i]);
        np_byte_pattern_t pat;
        if (np_compile_pattern(out, &pat) != 0) return -1;
        uintptr_t hit = np_scan_sole_match(im->text, im->text_sz, &pat);
        np_release_pattern(&pat);
        if (hit == fn) return 0;
    }
    return -1;
}

// Writes `tmpl` to `out` with the build-specific fields taken from the installed client,
// so a fixture that has to describe the running client keeps doing so after a Steam update.
// Each signature's anchor is resolved here; its result becomes func_addr_this_build. A
// signature marked "fixture_rebase": "vtable_slot" also gets its anchor swapped for a data
// slot holding that function and a byte pattern that matches only there.
static int rebase_fixture(const char *tmpl, const char *out) {
    np_sigdb_t db = {0};
    if (np_load_profile(tmpl, &db) != 0) {
        fprintf(stderr, "cannot load fixture template '%s'\n", tmpl);
        return 2;
    }
    size_t len = 0;
    uint8_t *text = np_read_whole_file(tmpl, &len);
    cJSON *root = text ? cJSON_ParseWithLength((const char *)text, len) : NULL;
    free(text);
    cJSON *arr = root ? cJSON_GetObjectItem(root, "signatures") : NULL;
    if (!arr || cJSON_GetArraySize(arr) != db.sig_count) {
        fprintf(stderr, "cannot parse fixture template '%s'\n", tmpl);
        cJSON_Delete(root);
        np_free_profile(&db);
        return 2;
    }

    int rc = 0;
    for (int i = 0; i < db.sig_count && !rc; i++) {
        np_sig_entry_t *sig = &db.signatures[i];
        cJSON *elem = cJSON_GetArrayItem(arr, i);
        const image_t *im = load_image(sig->module) == 0 ? image_for(sig->module) : NULL;
        uintptr_t fn = im ? np_locate_anchor(im->mh, im->slide, im->text, im->text_sz,
                                             &sig->anchor) : 0;
        if (!fn) {
            fprintf(stderr, "%s: the anchor of '%s' does not resolve in the installed "
                    "client, so this fixture cannot be built here\n", tmpl, sig->name);
            rc = 3;
            break;
        }

        char hex[32];
        cJSON *mode = cJSON_GetObjectItem(elem, "fixture_rebase");
        if (cJSON_IsString(mode) && strcmp(mode->valuestring, "vtable_slot") == 0) {
            uintptr_t slot = data_slot_holding(im, fn);
            char pattern[sizeof(sig->aob_hex)];
            if (!slot || sole_pattern_at(im, fn, pattern, sizeof(pattern)) != 0) {
                fprintf(stderr, "%s: no data slot or unique byte pattern for '%s' in the "
                        "installed client\n", tmpl, sig->name);
                rc = 3;
                break;
            }
            snprintf(hex, sizeof(hex), "0x%lx", (unsigned long)(slot - (uintptr_t)im->slide));
            cJSON *anchor = cJSON_CreateObject();
            cJSON_AddStringToObject(anchor, "kind", "vtable_slot");
            cJSON_AddStringToObject(anchor, "va", hex);
            cJSON_ReplaceItemInObject(elem, "anchor", anchor);
            cJSON_DeleteItemFromObject(elem, "aob_hex");
            cJSON_AddStringToObject(elem, "aob_hex", pattern);
        } else if (mode) {
            fprintf(stderr, "%s: unknown fixture_rebase for '%s'\n", tmpl, sig->name);
            rc = 2;
            break;
        }
        cJSON_DeleteItemFromObject(elem, "fixture_rebase");
        snprintf(hex, sizeof(hex), "0x%lx", (unsigned long)(fn - (uintptr_t)im->slide));
        cJSON_DeleteItemFromObject(elem, "func_addr_this_build");
        cJSON_AddStringToObject(elem, "func_addr_this_build", hex);
    }

    if (!rc) {
        char *json = cJSON_Print(root);
        FILE *fh = json ? fopen(out, "w") : NULL;
        if (!fh || fputs(json, fh) < 0 || fclose(fh) != 0) {
            fprintf(stderr, "cannot write '%s'\n", out);
            rc = 2;
        }
        free(json);
    }
    cJSON_Delete(root);
    np_free_profile(&db);
    return rc;
}

// Exit 1 is a database with problems, 2 one that could not be read, 3 this machine being
// unable to answer. Callers feeding deliberately broken databases need those apart: a
// rejected database is a result, an unloadable client image means nothing was checked.
int main(int argc, char **argv) {
    uint64_t build = 0;
    while (argc > 2 && (strcmp(argv[1], "--client-dir") == 0 || strcmp(argv[1], "--build") == 0)) {
        if (strcmp(argv[1], "--build") == 0) {
            char *end = NULL;
            build = strtoull(argv[2], &end, 10);
            if (!build || *end) { fprintf(stderr, "bad --build '%s'\n", argv[2]); return 2; }
        } else {
            DIR *dh = argv[2][0] ? opendir(argv[2]) : NULL;
            if (!dh) { fprintf(stderr, "cannot open client dir '%s'\n", argv[2]); return 3; }
            closedir(dh);
            g_client_dir = argv[2];
            printf("client : %s\n", g_client_dir);
        }
        argv += 2;
        argc -= 2;
    }
    if (argc > 1 && (strcmp(argv[1], "--client-dir") == 0 || strcmp(argv[1], "--build") == 0)) {
        fprintf(stderr, "usage: anchorcheck [--client-dir DIR] [--build N] [sigdb.json ...]\n");
        return 2;
    }
    if (!g_client_dir && !getenv("HOME")) { fprintf(stderr, "HOME unset\n"); return 3; }

    if (load_image(NP_MODULE_DEFAULT) != 0) return 3;

    if (argc > 1 && strcmp(argv[1], "--rebase") == 0) {
        if (argc != 4) { fprintf(stderr, "usage: anchorcheck --rebase TEMPLATE OUT\n"); return 2; }
        return rebase_fixture(argv[2], argv[3]);
    }

    char paths[MAX_DBS][512];
    int n = 0;
    for (int i = 1; i < argc && n < MAX_DBS; i++)
        snprintf(paths[n++], 512, "%s", argv[i]);
    if (!n) n = collect_dbs(paths, MAX_DBS);
    if (!n) { fprintf(stderr, "no signature databases in %s\n", SIGDB_DIR); return 3; }

    dbcheck_t dbs[MAX_DBS] = {0};
    for (int i = 0; i < n; i++) {
        snprintf(dbs[i].path, sizeof(dbs[i].path), "%s", paths[i]);
        if (np_load_profile(dbs[i].path, &dbs[i].sigdb) != 0) {
            fprintf(stderr, "cannot load sigdb '%s'\n", dbs[i].path);
            return 2;
        }
        dbs[i].loaded = 1;
        for (int j = 0; j < dbs[i].sigdb.sig_count; j++) {
            const char *mod = dbs[i].sigdb.signatures[j].module;
            if (load_image(mod) == 0) continue;
            fprintf(stderr, "sigdb '%s' names module '%s', which will not load\n",
                    dbs[i].path, mod);
            return strcmp(mod, NP_MODULE_DEFAULT) == 0 ? 3 : 2;
        }
    }
    for (int i = 0; i < n; i++) {
        if (check_db(&dbs[i]) != 0) return 2;
    }

    int live = build ? pick_by_build(dbs, n, build) : pick_live(dbs, n);

    int bad = 0;
    for (int i = 0; i < n; i++) bad += report_db(&dbs[i], i == live, live >= 0 && i != live);
    bad += report_cross_db(dbs, n);

    if (live < 0) {
        printf("no database describes the running client, so only the anchors were "
               "checked. Anchors are what the dylib resolves from, so this is not a "
               "failure.\n");
    } else {
        const image_t *sc = image_for(NP_MODULE_DEFAULT);
        bad += run_rtti(sc->mh, sc->slide, sc->text, sc->text_sz, dbs[live].build);
        bad += check_aob_fallback(dbs[live].path);
    }

    for (int i = 0; i < n; i++) {
        free(dbs[i].rows);
        np_free_profile(&dbs[i].sigdb);
    }
    return bad ? 1 : 0;
}
