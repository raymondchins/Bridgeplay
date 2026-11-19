// Compatibility tool support
#include "compat.h"
#include "../util/log.h"
#include "../util/file.h"
#include "../util/a64.h"
#include "../util/ptr.h"

#include <dirent.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// The client maps Cloud's Windows path roots into the compat prefix only when
// the tool's name contains "proton" so without a match every AutoCloud rule silently
// skips the app.
#define TOOL_DIR_NAME "bridgeplay-proton"
// The prefix tools had before Bridgeplay 3.0. The app renames them, and until it has, a
// tool under the old name is still ours.
#define LEGACY_TOOL_DIR_NAME "notproton"
#define TOOL_RUN      "/run"

#define COMPAT_MANAGER_ENABLED_OFF  0x7B0
#define COMPAT_MANAGER_USER_OFF     0x300  // CUser *
#define COMPAT_TOOL_STRIDE          0x130
#define COMPAT_TOOL_FLAGS_OFF       0x28  // bit 0: tool needs no downloaded app
#define COMPAT_TOOL_FLAG_NO_APP     0x1
#define COMPAT_TOOL_FROM_OSLIST_OFF 0x70
#define COMPAT_TOOL_TO_OSLIST_OFF   0x78

#define COMPAT_MAPPING_PRIORITY_GLOBAL 75
#define COMPAT_MAPPING_PRIORITY_APP    250

static const char TOOL_MANIFEST[] =
    "\"manifest\"\n"
    "{\n"
    "  \"version\" \"2\"\n"
    "  \"commandline\" \"" TOOL_RUN " %verb%\"\n"
    "}\n";

// Steam's compatibilitytools.d scanner registers a tool when this file is present
// in the tool subdirectory. install_path is "." because the manifest lives inside
// the tool directory. to_oslist is macos
static const char TOOL_DECLARATION_FMT[] =
    "\"compatibilitytools\"\n"
    "{\n"
    "  \"compat_tools\"\n"
    "  {\n"
    "    \"%s\"\n"
    "    {\n"
    "      \"install_path\" \".\"\n"
    "      \"display_name\" \"%s\"\n"
    "      \"from_oslist\" \"windows\"\n"
    "      \"to_oslist\" \"macos\"\n"
    "    }\n"
    "  }\n"
    "}\n";

#include "compat_run.h"  // RUN_SCRIPT, generated from compat_run.sh

// Written to a temporary file next to path and renamed over it, so a game launched
// while Steam starts never runs a half-written run script.
static int write_file(const char *path, const char *content, int executable) {
    char tmp[1024];
    if (snprintf(tmp, sizeof tmp, "%s.XXXXXX", path) >= (int)sizeof tmp) return -1;
    int fd = mkstemp(tmp);
    if (fd < 0) return -1;
    FILE *f = fdopen(fd, "w");
    if (!f) {
        close(fd);
        unlink(tmp);
        return -1;
    }
    int err = fputs(content, f) < 0;
    err |= fchmod(fd, executable ? 0755 : 0644) != 0;
    err |= fclose(f) != 0;
    if (err || rename(tmp, path) != 0) {
        unlink(tmp);
        return -1;
    }
    return 0;
}

static int ensure_dir(const char *path) {
    struct stat st;
    if (stat(path, &st) == 0)
        return S_ISDIR(st.st_mode) ? 0 : -1;
    return mkdir(path, 0755);
}

// g_tool_shift is how far the install dir moved, which counts the head insertion too;
// g_head_shift is how far the fields from COMPAT_TOOL_HEAD_OFF up to the install dir moved.
static int32_t g_tool_shift;
static int32_t g_head_shift;
static int     g_head_probed;
static int     g_tail_probed;

// LDR Wt,[X0,#imm]. Writes the byte offset and destination register.
static int ldr32_from_x0(uint32_t w, uint32_t *off, uint32_t *rt) {
    if ((w & 0xFFC003E0u) != 0xB9400000u) return 0;
    *rt  = w & 0x1Fu;
    *off = ((w >> 10) & 0xFFFu) * 4u;
    return 1;
}

// LDR Xt,[Xn,#imm] for a named base register.
static int ldr64_from(uint32_t w, uint32_t base, uint32_t *off) {
    if ((w & 0xFFC00000u) != 0xF9400000u) return 0;
    if (((w >> 5) & 0x1Fu) != base) return 0;
    *off = ((w >> 10) & 0xFFFu) * 8u;
    return 1;
}

static int ldr64_from_x0(uint32_t w, uint32_t *off) {
    return ldr64_from(w, 0, off);
}

// LDRB Wt,[Xn,#imm] for a named base register.
static int ldrb_from(uint32_t w, uint32_t base, uint32_t *off) {
    if ((w & 0xFFC00000u) != 0x39400000u) return 0;
    if (((w >> 5) & 0x1Fu) != base) return 0;
    *off = (w >> 10) & 0xFFFu;
    return 1;
}

// MOV Xd,X0, which assembles as ORR Xd,XZR,X0. Writes the destination register.
static int mov_from_x0(uint32_t w, uint32_t *rd) {
    if ((w & 0xFFFFFFE0u) != 0xAA0003E0u) return 0;
    *rd = w & 0x1Fu;
    return 1;
}

// CBZ Wt. Writes the branch target.
static int cbz32(uintptr_t pc, uint32_t w, uint32_t rt, uintptr_t *target) {
    if ((w & 0xFF000000u) != 0x34000000u) return 0;
    if ((w & 0x1Fu) != rt) return 0;
    int32_t imm = (int32_t)((w >> 5) & 0x7FFFFu);
    imm = (imm << 13) >> 13;
    *target = pc + (uintptr_t)(imm * 4);
    return 1;
}

// The oslist gate compares both oslist strings, so its two loads sit at the far
// end of the struct and corroborate a shift derived at the near end. The base
// register is whatever the compiler picked, so a build that stops using the one
// seen here yields nothing and the shift stands on the near-end pair alone.
// Returns the number of offsets written.
static int probe_oslist_offsets(uintptr_t oslist_gate, uint32_t base,
                                uint32_t *from_off, uint32_t *to_off) {
    if (!oslist_gate) return 0;

    uint32_t seen[2];
    int n = 0;
    for (uintptr_t pc = oslist_gate - 0x40; pc <= oslist_gate + 0x20; pc += 4) {
        uint32_t off;
        if (!ldr64_from(*(const uint32_t *)pc, base, &off)) continue;
        if (n > 0 && seen[0] == off) continue;
        if (n > 1 && seen[1] == off) continue;
        if (n == 2) return 0;
        seen[n++] = off;
    }
    if (n != 2) return 0;

    // to_oslist sits above from_oslist in the struct, whichever order the
    // comparison happens to load them in.
    *to_off   = seen[0] > seen[1] ? seen[0] : seen[1];
    *from_off = seen[0] > seen[1] ? seen[1] : seen[0];
    return 2;
}

// LDR Xt,[Xn,#imm]! (pre-index). Writes the base register and the signed offset.
static int ldr64_pre(uint32_t w, uint32_t *rn, int32_t *off) {
    if ((w & 0xFFE00C00u) != 0xF8400C00u) return 0;
    int32_t imm = (int32_t)((w >> 12) & 0x1FFu);
    *off = (imm << 23) >> 23;
    *rn  = (w >> 5) & 0x1Fu;
    return 1;
}

// MOV Xd,Xm (ORR Xd,XZR,Xm). Writes both registers.
static int mov_reg(uint32_t w, uint32_t *rd, uint32_t *rm) {
    if ((w & 0xFFE0FFE0u) != 0xAA0003E0u) return 0;
    *rd = w & 0x1Fu;
    *rm = (w >> 16) & 0x1Fu;
    return 1;
}

int np_compat_probe_tool_head(uintptr_t yld_register_tool) {
    g_head_probed = 0;
    if (!yld_register_tool) return 0;

    // YldRegisterTool(manager, tool) copies the tool pointer out of x1 before its first
    // call and logs the name first, so the first 64-bit load through a copy of x1 is
    // the name. Only copies made before x1 is reused for a call argument count.
    uint32_t alias = 1u << 1;
    for (int i = 0; i < 48; i++) {
        uint32_t w = *(const uint32_t *)(yld_register_tool + (uintptr_t)i * 4);
        uint32_t rd, rm, rn, rt, off;
        int32_t  soff;
        if (mov_reg(w, &rd, &rm)) {
            if (alias & (1u << rm)) alias |= 1u << rd;
            else alias &= ~(1u << rd);
            continue;
        }
        int found = 0;
        if (ldr64_pre(w, &rn, &soff) && (alias & (1u << rn)) && soff > 0) {
            off = (uint32_t)soff;
            found = 1;
        } else if ((w & 0xFFC00000u) == 0xF9400000u && (alias & (1u << ((w >> 5) & 0x1Fu)))) {
            off = ((w >> 10) & 0xFFFu) * 8u;
            found = 1;
        }
        if (found) {
            int32_t head = (int32_t)off - COMPAT_TOOL_NAME_OFF;
            if (head < 0 || head > 0x20 || (head & 7)) {
                NP_ERR("np_compat_probe_tool_head: the first tool load is at 0x%x, which is "
                       "not where a name can sit", off);
                return 0;
            }
            g_head_shift  = head;
            g_head_probed = 1;
            if (head)
                NP_LOG("np_compat_probe_tool_head: tool fields from 0x%x onward are %+d "
                       "from the baseline (name 0x%x)", COMPAT_TOOL_HEAD_OFF, head, off);
            return 1;
        }
        // A call clobbers the argument and scratch registers x0-x18, so a copy left in
        // x1 is no longer the tool after one. Other branches and stores write no register;
        // their low bits are an offset or a source. Anything else that writes one (loads,
        // moves, arithmetic) keeps the destination in bits 0-4 and drops it from the copies.
        if ((w & 0x7C000000u) == 0x14000000u && (w & 0x80000000u)) {  // BL
            alias &= ~0x7FFFFu;
            continue;
        }
        if ((w & 0xFFFFFC1Fu) == 0xD63F0000u) {                       // BLR
            alias &= ~0x7FFFFu;
            continue;
        }
        if ((w & 0x7C000000u) == 0x14000000u ||                       // B
            (w & 0xFF000010u) == 0x54000000u ||                       // B.cond
            (w & 0x7E000000u) == 0x34000000u ||                       // CBZ, CBNZ
            (w & 0x7E000000u) == 0x36000000u ||                       // TBZ, TBNZ
            (w & 0xFE000000u) == 0xD6000000u)                         // BR, RET
            continue;
        if ((w & 0x0A000000u) == 0x08000000u && (w & 0x00400000u) == 0) continue; // stores
        rt = w & 0x1Fu;
        alias &= ~(1u << rt);
    }
    NP_ERR("np_compat_probe_tool_head: no load through the tool argument in "
           "YldRegisterTool at 0x%lx", (unsigned long)yld_register_tool);
    return 0;
}

int np_compat_layout_known(void) {
    return g_head_probed && g_tail_probed && g_head_shift <= g_tool_shift;
}

int np_compat_probe_tool_layout(uintptr_t appid_gate, uintptr_t oslist_gate) {
    g_tail_probed = 0;
    if (!appid_gate) return 0;

    uint32_t appid_off, rt;
    if (!ldr32_from_x0(*(const uint32_t *)appid_gate, &appid_off, &rt)) {
        NP_WARN("np_compat_probe_tool_layout: 0x%lx is not the appid load",
                (unsigned long)appid_gate);
        return 0;
    }

    uintptr_t local_path;
    if (!cbz32(appid_gate + 4, *(const uint32_t *)(appid_gate + 4), rt, &local_path)) {
        NP_WARN("np_compat_probe_tool_layout: no appid branch after 0x%lx",
                (unsigned long)appid_gate);
        return 0;
    }

    // The install field is the first thing the local path wants, within a few
    // instructions of the branch landing.
    uint32_t install_off = 0;
    for (uintptr_t pc = local_path; pc < local_path + 0x20; pc += 4) {
        if (ldr64_from_x0(*(const uint32_t *)pc, &install_off)) break;
    }
    if (!install_off) {
        NP_WARN("np_compat_probe_tool_layout: no install load at 0x%lx",
                (unsigned long)local_path);
        return 0;
    }

    int32_t by_appid   = (int32_t)appid_off   - COMPAT_TOOL_APPID_OFF;
    int32_t by_install = (int32_t)install_off - COMPAT_TOOL_INSTALL_OFF;
    if (by_appid != by_install) {
        NP_ERR("np_compat_probe_tool_layout: appid moved %+d but install moved %+d; "
               "the tool layout no longer shifts as one block",
               by_appid, by_install);
        return 0;
    }

    // COMPAT_TOOL_TO_OSLIST_OFF is the highest field written into a registration,
    // so agreement there means the shift holds across every field in use rather
    // than only the two it was read from.
    uint32_t from_off = 0, to_off = 0;
    if (probe_oslist_offsets(oslist_gate, 21, &from_off, &to_off) == 2) {
        int32_t by_from = (int32_t)from_off - COMPAT_TOOL_FROM_OSLIST_OFF;
        int32_t by_to   = (int32_t)to_off   - COMPAT_TOOL_TO_OSLIST_OFF;
        if (by_from != by_appid || by_to != by_appid) {
            NP_ERR("np_compat_probe_tool_layout: near fields moved %+d but oslist "
                   "moved %+d/%+d; the tool layout no longer shifts as one block",
                   by_appid, by_from, by_to);
            return 0;
        }
        NP_DBG("np_compat_probe_tool_layout: oslist offsets 0x%x/0x%x agree on %+d",
               from_off, to_off, by_appid);
    }

    g_tool_shift = by_appid;
    g_tail_probed = 1;
    if (g_tool_shift)
        NP_LOG("np_compat_probe_tool_layout: tool fields from install onward are "
               "%+d from the baseline (appid 0x%x, install 0x%x)",
               g_tool_shift, appid_off, install_off);
    return 1;
}

// The manager is a much larger object than a tool entry and grows in the middle,
// so a single distance does not describe it the way one does for the tool tail:
// the tool array and its count sit below the growth and do not move, while the
// enabled flag sits above it and does. Reading the flag's own offset back keeps
// the two independent.
static uint32_t g_enabled_off = COMPAT_MANAGER_ENABLED_OFF;

int np_compat_probe_enabled_off(uintptr_t bis_enabled) {
    if (!bis_enabled) return 0;

    // this arrives in X0 and is parked in a callee-saved register before the
    // profiling call clobbers it, so the flag is read through that register.
    uint32_t base = 0;
    int have_base = 0;
    for (uintptr_t pc = bis_enabled; pc < bis_enabled + 0x40; pc += 4) {
        if (mov_from_x0(*(const uint32_t *)pc, &base)) { have_base = 1; break; }
    }
    if (!have_base) {
        NP_WARN("np_compat_probe_enabled_off: this is never parked in a register "
                "at 0x%lx", (unsigned long)bis_enabled);
        return 0;
    }

    // The flag is the first thing the body tests, ahead of any other byte read
    // through that register.
    uint32_t off = 0;
    int found = 0;
    for (uintptr_t pc = bis_enabled; pc < bis_enabled + 0x80; pc += 4) {
        if (ldrb_from(*(const uint32_t *)pc, base, &off)) { found = 1; break; }
    }
    if (!found) {
        NP_WARN("np_compat_probe_enabled_off: no flag load through x%u at 0x%lx",
                base, (unsigned long)bis_enabled);
        return 0;
    }

    // A tiny offset would mean the match landed on some unrelated early byte
    // read rather than on the flag, which sits far into the object.
    if (off < 0x100) {
        NP_ERR("np_compat_probe_enabled_off: 0x%x is too low to be the enabled "
               "flag; refusing to write it", off);
        return 0;
    }

    if (off != g_enabled_off)
        NP_LOG("np_compat_probe_enabled_off: enabled flag at 0x%x, %+d from the "
               "baseline", off, (int32_t)off - COMPAT_MANAGER_ENABLED_OFF);
    g_enabled_off = off;
    return 1;
}

uint32_t np_compat_enabled_off(void) {
    return g_enabled_off;
}

static uint32_t g_windows_only_off;

int np_compat_probe_windows_only_off(uintptr_t get_wildcard_mapping, uintptr_t lookup) {
    if (!get_wildcard_mapping || !lookup) return 0;

    // The offset only exists in the code. Right before calling the lookup,
    // GetWildcardMapping puts manager + offset in x0. An x0 built from SP is a
    // local variable.
    for (uintptr_t pc = get_wildcard_mapping; pc < get_wildcard_mapping + 0x100; pc += 4) {
        uintptr_t target;
        if (!a64_bl(pc, *(const uint32_t *)pc, &target) || target != lookup) continue;

        for (int back = 1; back <= 4 && pc - 4u * back >= get_wildcard_mapping; back++) {
            uint32_t rd, rn, imm;
            if (a64_add_imm(*(const uint32_t *)(pc - 4u * back), &rd, &rn, &imm) &&
                rd == 0 && rn != A64_SP) {
                g_windows_only_off = imm;
                NP_LOG("np_compat_probe_windows_only_off: windows-only table at 0x%x", imm);
                return 1;
            }
        }
        break;
    }
    NP_WARN("np_compat_probe_windows_only_off: no table argument for 0x%lx in 0x%lx",
            (unsigned long)lookup, (unsigned long)get_wildcard_mapping);
    return 0;
}

bool np_compat_is_windows_only_table(const void *compat_mgr, const void *map) {
    return compat_mgr && g_windows_only_off &&
           map == (const uint8_t *)compat_mgr + g_windows_only_off;
}

void *np_compat_user(const void *compat_mgr) {
    if (!compat_mgr) return NULL;
    uint64_t user = *(const uint64_t *)((const uint8_t *)compat_mgr + COMPAT_MANAGER_USER_OFF);
    return np_plausible_ptr(user) ? (void *)(uintptr_t)user : NULL;
}

uint32_t np_compat_tool_off(uint32_t reference_off) {
    if (reference_off < COMPAT_TOOL_HEAD_OFF) return reference_off;
    if (reference_off < COMPAT_TOOL_INSTALL_OFF)
        return (uint32_t)((int32_t)reference_off + g_head_shift);
    return (uint32_t)((int32_t)reference_off + g_tool_shift);
}

size_t np_compat_tool_stride(void) {
    return (size_t)((int32_t)COMPAT_TOOL_STRIDE + g_tool_shift);
}

const char *np_compat_tool_name(const void *tool) {
    // Without a confirmed layout no slot is known to hold the name, so nothing is matched
    // or compared by it.
    if (!tool || !np_compat_layout_known()) return NULL;
    const char *name =
        *(const char *const *)((const uint8_t *)tool + np_compat_tool_off(COMPAT_TOOL_NAME_OFF));
    // A layout this build reads wrong puts an int or a flag where the name should be.
    return np_plausible_addr((uint64_t)(uintptr_t)name) ? name : NULL;
}

// The compatibility tool needs to go in the folder Steam normally (on Linux)
// scans for compatibility tools. So the tool is shoved into
// ~/Library/Application Support/Steam/compatibilitytools.d and
// STEAM_EXTRA_COMPAT_TOOLS_PATHS points there.
void np_compat_export_tools_path(void) {
    const char *home = np_home_dir();
    if (!home) return;
    if (getenv("STEAM_EXTRA_COMPAT_TOOLS_PATHS")) return;

    char tools_dir[512];
    snprintf(tools_dir, sizeof(tools_dir),
             "%s/Library/Application Support/Steam/compatibilitytools.d", home);

    setenv("STEAM_EXTRA_COMPAT_TOOLS_PATHS", tools_dir, 1);
    NP_LOG("np_compat_export_tools_path: set STEAM_EXTRA_COMPAT_TOOLS_PATHS=%s",
           tools_dir);
}

typedef struct {
    char name[64];
    char build[64];
    char flavor[16];
    char display[96];
    char dir[640];
} tool_entry_t;

// Steam keeps pointers into g_tools.
static tool_entry_t *g_tools;
static int g_tool_count;
static int g_tool_cap;
static int g_tool_list_present;

static int is_name_char(char c, const char *extra) {
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
        return 1;
    return c && strchr(extra, c);
}

static int is_token(const char *s, const char *extra) {
    if (!*s) return 0;
    for (; *s; s++)
        if (!is_name_char(*s, extra)) return 0;
    return 1;
}

static int has_tool_prefix(const char *s) {
    return strncmp(s, TOOL_DIR_NAME, strlen(TOOL_DIR_NAME)) == 0
        || strncmp(s, LEGACY_TOOL_DIR_NAME, strlen(LEGACY_TOOL_DIR_NAME)) == 0;
}

static int is_tool_name(const char *s) {
    return s && has_tool_prefix(s) && is_token(s, "._-");
}

static int is_display(const char *s) {
    if (!*s) return 0;
    for (; *s; s++)
        if (*s == '"' || *s == '\\' || (unsigned char)*s < 0x20) return 0;
    return 1;
}

static int parse_tool_line(char *line, tool_entry_t *out) {
    char *field[4];
    int n = 0;
    char *save = NULL;
    for (char *tok = strtok_r(line, "\t", &save); tok && n < 4;
         tok = strtok_r(NULL, "\t", &save))
        field[n++] = tok;
    if (n != 4) return 0;

    if (!is_tool_name(field[0]) || !is_token(field[1], ".-")
        || (strcmp(field[2], "fex") != 0 && strcmp(field[2], "rosetta") != 0)
        || !is_display(field[3]))
        return 0;
    if (strlen(field[0]) >= sizeof(out->name) || strlen(field[1]) >= sizeof(out->build)
        || strlen(field[3]) >= sizeof(out->display))
        return 0;

    snprintf(out->name, sizeof(out->name), "%s", field[0]);
    snprintf(out->build, sizeof(out->build), "%s", field[1]);
    snprintf(out->flavor, sizeof(out->flavor), "%s", field[2]);
    snprintf(out->display, sizeof(out->display), "%s", field[3]);
    return 1;
}

int np_compat_load_tool_list(const char *path, const char *tools_dir) {
    g_tool_count = 0;
    g_tool_list_present = 0;

    FILE *f = fopen(path, "r");
    if (!f) {
        NP_WARN("np_compat_load_tool_list: %s is missing, so no build has a tool "
                "until Bridgeplay sets one up", path);
        return 0;
    }
    g_tool_list_present = 1;

    char line[512];
    int lineno = 0;
    while (fgets(line, sizeof(line), f)) {
        lineno++;
        line[strcspn(line, "\r\n")] = '\0';
        if (!line[0]) continue;

        tool_entry_t entry;
        if (!parse_tool_line(line, &entry)) {
            NP_WARN("np_compat_load_tool_list: %s line %d is not a tool, skipped",
                    path, lineno);
            continue;
        }

        int taken = 0;
        for (int i = 0; i < g_tool_count; i++)
            taken |= strcmp(g_tools[i].name, entry.name) == 0;
        if (taken) {
            NP_WARN("np_compat_load_tool_list: %s is listed twice, the later line "
                    "(build %s) is skipped", entry.name, entry.build);
            continue;
        }
        if (g_tool_count == g_tool_cap) {
            int cap = g_tool_cap ? g_tool_cap * 2 : 8;
            tool_entry_t *grown = realloc(g_tools, (size_t)cap * sizeof(*grown));
            if (!grown) {
                NP_WARN("np_compat_load_tool_list: out of memory at %s, the rest is skipped",
                        entry.name);
                break;
            }
            g_tools = grown;
            g_tool_cap = cap;
        }

        snprintf(entry.dir, sizeof(entry.dir), "%s/%s", tools_dir, entry.name);
        g_tools[g_tool_count++] = entry;
    }
    fclose(f);
    return g_tool_count;
}

static int tools_dir_path(char *out, size_t size) {
    const char *home = np_home_dir();
    if (!home) return -1;
    snprintf(out, size, "%s/Library/Application Support/Steam/compatibilitytools.d", home);
    return 0;
}

static void load_tool_list(void) {
    const char *home = np_home_dir();
    char tools_dir[512];
    if (!home || tools_dir_path(tools_dir, sizeof(tools_dir)) != 0) return;

    char path[512];
    np_support_path(path, sizeof(path), home, "tools");
    np_compat_load_tool_list(path, tools_dir);
}

static void load_tool_list_once(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, load_tool_list);
}

uint32_t np_compat_manager_tools_max(void) {
    load_tool_list_once();
    return COMPAT_MANAGER_TOOLS_HEADROOM + (uint32_t)g_tool_count;
}

static int write_tool(const tool_entry_t *tool) {
    if (ensure_dir(tool->dir) != 0) {
        NP_WARN("np_compat_ensure_tool_manifest: cannot create %s", tool->dir);
        return -1;
    }

    char declaration[512];
    snprintf(declaration, sizeof(declaration), TOOL_DECLARATION_FMT,
             tool->name, tool->display);

    char path[768];
    int wrote = 0;

    // Rewritten every launch so field changes take effect. A rescan replaces it in
    // place rather than adding a second copy.
    snprintf(path, sizeof(path), "%s/compatibilitytool.vdf", tool->dir);
    if (write_file(path, declaration, 0) == 0) wrote++;
    else NP_WARN("np_compat_ensure_tool_manifest: failed to write %s", path);

    snprintf(path, sizeof(path), "%s/toolmanifest.vdf", tool->dir);
    if (access(path, F_OK) != 0) {
        if (write_file(path, TOOL_MANIFEST, 0) == 0) wrote++;
        else NP_WARN("np_compat_ensure_tool_manifest: failed to write %s", path);
    }

    // The run script is the shim this project owns and updates, so rewrite it
    // every launch rather than leaving a stale copy behind.
    snprintf(path, sizeof(path), "%s/run", tool->dir);
    if (write_file(path, RUN_SCRIPT, 1) == 0) wrote++;
    else NP_WARN("np_compat_ensure_tool_manifest: failed to write %s", path);

    char line[80];
    snprintf(line, sizeof(line), "%s\n", tool->flavor);
    snprintf(path, sizeof(path), "%s/flavor", tool->dir);
    if (write_file(path, line, 0) == 0) wrote++;
    else NP_WARN("np_compat_ensure_tool_manifest: failed to write %s", path);

    snprintf(line, sizeof(line), "%s\n", tool->build);
    snprintf(path, sizeof(path), "%s/build", tool->dir);
    if (write_file(path, line, 0) == 0) wrote++;
    else NP_WARN("np_compat_ensure_tool_manifest: failed to write %s", path);

    if (wrote > 0)
        NP_LOG("np_compat_ensure_tool_manifest: wrote %d file(s) to %s", wrote, tool->dir);

    return 0;
}

#define RUN_SCRIPT_MARK        "\n# bridgeplay CrossOver compatibility tool shim\n"
#define LEGACY_RUN_SCRIPT_MARK "\n# notproton CrossOver compatibility tool shim\n"

static int written_here(const char *tool_dir) {
    char path[768];
    snprintf(path, sizeof(path), "%s/flavor", tool_dir);
    if (access(path, F_OK) == 0) return 1;

    snprintf(path, sizeof(path), "%s/run", tool_dir);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char head[128];
    size_t got = fread(head, 1, sizeof(head) - 1, f);
    fclose(f);
    head[got] = '\0';
    return strstr(head, RUN_SCRIPT_MARK) != NULL || strstr(head, LEGACY_RUN_SCRIPT_MARK) != NULL;
}

static void remove_tool(const char *tools_dir, const char *name) {
    char tool_dir[640];
    snprintf(tool_dir, sizeof(tool_dir), "%s/%s", tools_dir, name);
    if (!written_here(tool_dir)) return;

    char path[768];

    static const char *const files[] = {
        "compatibilitytool.vdf", "toolmanifest.vdf", "run", "flavor", "build",
    };

    for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); i++) {
        snprintf(path, sizeof(path), "%s/%s", tool_dir, files[i]);
        unlink(path);
    }

    if (rmdir(tool_dir) == 0)
        NP_LOG("np_compat_ensure_tool_manifest: removed %s", tool_dir);
    else
        NP_WARN("np_compat_ensure_tool_manifest: %s holds files this did not write, "
                "so it stays", tool_dir);
}

static int is_listed(const char *name) {
    for (int i = 0; i < g_tool_count; i++)
        if (strcmp(g_tools[i].name, name) == 0) return 1;
    return 0;
}

static void remove_unlisted_tools(const char *tools_dir) {
    DIR *dir = opendir(tools_dir);
    if (!dir) return;

    struct dirent *e;
    while ((e = readdir(dir)) != NULL) {
        if (!has_tool_prefix(e->d_name)) continue;
        if (is_listed(e->d_name)) continue;
        remove_tool(tools_dir, e->d_name);
    }
    closedir(dir);
}

int np_compat_ensure_tool_manifest(void) {
    char tools_dir[512];
    if (tools_dir_path(tools_dir, sizeof(tools_dir)) != 0) return -1;

    if (ensure_dir(tools_dir) != 0) {
        NP_WARN("np_compat_ensure_tool_manifest: cannot create %s", tools_dir);
        return -1;
    }

    load_tool_list_once();

    if (!g_tool_list_present) return 0;

    int failed = 0;
    for (int i = 0; i < g_tool_count; i++)
        failed |= write_tool(&g_tools[i]) != 0;

    remove_unlisted_tools(tools_dir);
    return failed ? -1 : 0;
}

static char g_tool_dir[640];

static void resolve_tool_dir(void) {
    load_tool_list_once();

    if (g_tool_count > 0) {
        snprintf(g_tool_dir, sizeof(g_tool_dir), "%s", g_tools[0].dir);
        return;
    }

    char tools_dir[512];
    if (tools_dir_path(tools_dir, sizeof(tools_dir)) == 0)
        snprintf(g_tool_dir, sizeof(g_tool_dir), "%s/%s", tools_dir, TOOL_DIR_NAME);
}

const char *np_compat_tool_dir(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, resolve_tool_dir);
    return g_tool_dir[0] ? g_tool_dir : NULL;
}

int np_compat_runs_tool(const char *cmd) {
    static const char lead[]    = "/compatibilitytools.d/";
    static const char run[]     = "'" TOOL_RUN " ";
    static const char run_dot[] = "/.'" TOOL_RUN " ";
    if (!cmd) return 0;

    for (const char *at = strstr(cmd, lead); at; at = strstr(at + 1, lead)) {
        const char *p = at + sizeof(lead) - 1;
        if (!has_tool_prefix(p)) continue;
        while (is_name_char(*p, "._-"))
            p++;
        if (strncmp(p, run, sizeof(run) - 1) == 0 || strncmp(p, run_dot, sizeof(run_dot) - 1) == 0)
            return 1;
    }
    return 0;
}

const char *np_compat_tool_commandline(void) {
    return TOOL_RUN " %verb%";
}

void np_compat_force_enable(void *compat_mgr) {
    if (!compat_mgr) return;

    uint8_t *base = (uint8_t *)compat_mgr;
    uint32_t off = np_compat_enabled_off();
    uint8_t prev = base[off];
    base[off] = 1;

    // Steam polls compat state frequently. Only log the one transition.
    if (!prev)
        NP_LOG("np_compat_force_enable: compat layer force-enabled (this+0x%X: 0 -> 1)",
               off);
}

typedef uint32_t (*fn_GetValidPlatforms)(void *compat_mgr, uint32_t appid);
static fn_GetValidPlatforms g_get_valid_platforms;

void np_compat_set_valid_platforms_fn(uintptr_t get_valid_platforms) {
    g_get_valid_platforms = (fn_GetValidPlatforms)get_valid_platforms;
}

uint32_t np_compat_valid_platforms(void *compat_mgr, uint32_t appid) {
    if (!g_get_valid_platforms || !compat_mgr)
        return 0;
    return g_get_valid_platforms(compat_mgr, appid);
}

typedef void *(*fn_FindToolForTargetApp)(void *compat_mgr, uint32_t appid);
static fn_FindToolForTargetApp g_find_tool_for_app;

void np_compat_set_find_tool_fn(uintptr_t find_tool_for_target_app) {
    g_find_tool_for_app = (fn_FindToolForTargetApp)find_tool_for_target_app;
}

void *np_compat_tool_for_app(void *compat_mgr, uint32_t appid) {
    if (!g_find_tool_for_app || !compat_mgr)
        return NULL;
    return g_find_tool_for_app(compat_mgr, appid);
}

// The config argument is a tool-specific string the dropdown has no way to set, and
// the client passes it empty from its own handler.
static fn_FindToolForTargetApp g_chosen_tool;

void np_compat_set_chosen_tool_fn(uintptr_t find_tool_for_target_app) {
    g_chosen_tool = (fn_FindToolForTargetApp)find_tool_for_target_app;
}

void *np_compat_chosen_tool(void *compat_mgr, uint32_t appid) {
    if (!g_chosen_tool || !compat_mgr)
        return NULL;
    return g_chosen_tool(compat_mgr, appid);
}

bool np_compat_would_force(void *compat_mgr, uint32_t appid) {
    if (!compat_mgr || !appid)
        return false;
    uint32_t platforms = np_compat_valid_platforms(compat_mgr, appid);
    return (platforms & COMPAT_PLATFORM_WINDOWS) && !(platforms & COMPAT_PLATFORM_MACOS);
}

typedef void *(*fn_FindMapping)(void *compat_mgr, uint32_t appid);
static fn_FindMapping g_find_mapping;

void np_compat_set_app_mapping_fn(uintptr_t find_mapping) {
    g_find_mapping = (fn_FindMapping)find_mapping;
}

// { const char *name; const char *config; int32_t priority }, owned by the client.
static const char *mapping_name(const void *mapping) {
    const char *const *entry = (const char *const *)mapping;
    if (!entry || !entry[0] || !entry[0][0])
        return NULL;
    return entry[0];
}

const char *np_compat_app_mapping(void *compat_mgr, uint32_t appid) {
    if (!g_find_mapping || !compat_mgr || !appid)
        return NULL;
    return mapping_name(g_find_mapping(compat_mgr, appid));
}

static fn_FindMapping g_get_wildcard;

void np_compat_set_wildcard_fn(uintptr_t get_wildcard_mapping) {
    g_get_wildcard = (fn_FindMapping)get_wildcard_mapping;
}

const char *np_compat_wildcard_mapping(void *compat_mgr, uint32_t appid) {
    if (!g_get_wildcard || !compat_mgr || !appid)
        return NULL;
    return mapping_name(g_get_wildcard(compat_mgr, appid));
}

typedef void (*fn_SetCompatToolMapping)(void *compat_mgr, uint32_t appid,
                                        const char *tool_name, const char *config,
                                        uint32_t priority);
static fn_SetCompatToolMapping g_set_mapping;

void np_compat_set_mapping_fn(uintptr_t set_compat_tool_mapping) {
    g_set_mapping = (fn_SetCompatToolMapping)set_compat_tool_mapping;
}

void np_compat_map_tool(void *compat_mgr, uint32_t appid, const char *tool_name) {
    if (!g_set_mapping || !compat_mgr || !tool_name) {
        NP_ERR("np_compat_map_tool: app %u cannot be mapped to %s", appid,
               tool_name ? tool_name : "no tool");
        return;
    }
    g_set_mapping(compat_mgr, appid, tool_name, "",
                  appid ? COMPAT_MAPPING_PRIORITY_APP
                        : COMPAT_MAPPING_PRIORITY_GLOBAL);
}

typedef void (*fn_YldRegisterTool)(void *compat_mgr, void *tool);
static fn_YldRegisterTool g_yld_register_tool;
typedef void (*fn_PlatFree)(void *ptr);
static fn_PlatFree g_free_tool_path;

void np_compat_set_register_fn(uintptr_t yld_register_tool) {
    g_yld_register_tool = (fn_YldRegisterTool)yld_register_tool;
    g_free_tool_path = (fn_PlatFree)dlsym(RTLD_DEFAULT, "Plat_Free");
    if (!g_free_tool_path)
        NP_WARN("np_compat_set_register_fn: Plat_Free unresolved, temporary tool paths will leak");
}

static void free_tool_paths(uint8_t *tool) {
    // YldRegisterTool fills these CUtlStrings in the caller's entry.
    // These need Plat_Free, not free.
    static const uint32_t offsets[] = {0x98, 0xA0, 0xA8, 0xD0, 0xD8, 0xE0, 0xE8, 0x118};
    if (!g_free_tool_path) return;
    for (size_t i = 0; i < sizeof(offsets) / sizeof(*offsets); i++) {
        void **path = (void **)(tool + np_compat_tool_off(offsets[i]));
        if (*path) g_free_tool_path(*path);
        *path = NULL;
    }
}

static void *g_manager;

void *np_compat_manager(void) {
    return g_manager;
}

int np_compat_app_runs_tool(uint32_t appid) {
    const uint8_t *tool = np_compat_tool_for_app(g_manager, appid);

    return tool && is_tool_name(np_compat_tool_name(tool));
}

static void *find_tool(void *compat_mgr, const char *wanted) {
    uint8_t *base = (uint8_t *)compat_mgr;
    uint8_t *array = *(uint8_t **)(base + COMPAT_MANAGER_TOOL_ARRAY_OFF);
    uint32_t count = *(uint32_t *)(base + COMPAT_MANAGER_TOOL_COUNT_OFF);
    if (!array || count > np_compat_manager_tools_max()) {
        // Once, because Steam walks this for every windows-only app as the library
        // redraws and a count this wrong does not correct itself.
        static const char once = 0;
        if (np_log_first_hit(&once, 0))
            NP_ERR("np_compat_registered_tool: the manager reports %u tool(s) at %p, "
                   "which is not a list this reads", count, (const void *)array);
        return NULL;
    }

    for (uint32_t i = 0; i < count; i++) {
        uint8_t *entry = array + (size_t)i * np_compat_tool_stride();
        const char *name = np_compat_tool_name(entry);
        if (name && strcmp(name, wanted) == 0)
            return entry;
    }
    return NULL;
}

void np_compat_register_crossover(void *compat_mgr) {
    static int registered = 0;

    // Every compat query arrives on the instance the properties page reads, which is
    // the one the tool list has to be enumerated from.
    if (compat_mgr)
        g_manager = compat_mgr;

    if (registered || !compat_mgr || !g_yld_register_tool)
        return;
    registered = 1;
    if (!np_compat_layout_known()) {
        // Tools Steam read from compatibilitytools.d itself still show; only the
        // runtime entries, which would be built on a guessed layout, are left out.
        NP_ERR("np_compat_register_crossover: this client's tool layout was not "
               "confirmed, so no tool is registered at runtime");
        return;
    }
    load_tool_list_once();

    // YldRegisterTool copies the entry and its strings. Each buffer carries headroom
    // for a client that inserted a field. to_oslist=macos passes
    // the registration gate, from_oslist=windows intersects the app mask so the
    // dropdown keeps it, and appid 0 marks a manager-local tool the resolver routes
    // to the local run script.
    uint8_t (*buffers)[COMPAT_TOOL_STRIDE + 64] = calloc((size_t)g_tool_count, sizeof(*buffers));
    if (g_tool_count && !buffers) {
        NP_WARN("np_compat_register_crossover: out of memory, no tool registered");
        return;
    }
    static const char from_oslist[] = "windows";
    static const char to_oslist[]   = "macos";

    for (int i = 0; i < g_tool_count; i++) {
        const tool_entry_t *t = &g_tools[i];

        if (find_tool(compat_mgr, t->name)) {
            NP_LOG("np_compat_register_crossover: %s already registered from disk, "
                   "skipping the runtime entry", t->name);
            continue;
        }

        uint8_t *tool = buffers[i];
        memset(tool, 0, sizeof(buffers[i]));
        *(uint32_t *)(tool + np_compat_tool_off(COMPAT_TOOL_FLAGS_OFF))      = COMPAT_TOOL_FLAG_NO_APP;
        *(const char **)(tool + np_compat_tool_off(COMPAT_TOOL_NAME_OFF))    = t->name;
        *(const char **)(tool + np_compat_tool_off(COMPAT_TOOL_DISPLAY_OFF)) = t->display;
        *(const char **)(tool + np_compat_tool_off(COMPAT_TOOL_INSTALL_OFF)) = t->dir;
        *(uint32_t *)(tool + np_compat_tool_off(COMPAT_TOOL_APPID_OFF)) = 0;
        *(const char **)(tool + np_compat_tool_off(COMPAT_TOOL_FROM_OSLIST_OFF)) = from_oslist;
        *(const char **)(tool + np_compat_tool_off(COMPAT_TOOL_TO_OSLIST_OFF))   = to_oslist;

        g_yld_register_tool(compat_mgr, tool);
        free_tool_paths(tool);
        NP_LOG("np_compat_register_crossover: registered %s (build %s) into manager 0x%llx",
               t->name, t->build, (unsigned long long)(uintptr_t)compat_mgr);
    }

    free(buffers);
}

const char *np_compat_fallback_tool_name(void) {
    load_tool_list_once();
    return g_tool_count > 0 ? g_tools[0].name : TOOL_DIR_NAME;
}

size_t np_compat_fex_tools(const char **names, size_t max) {
    load_tool_list_once();
    size_t n = 0;
    for (int i = 0; i < g_tool_count; i++) {
        if (strcmp(g_tools[i].flavor, "fex") != 0) continue;
        if (n == max) {
            static atomic_flag warned = ATOMIC_FLAG_INIT;
            if (!atomic_flag_test_and_set(&warned))
                NP_WARN("np_compat_fex_tools: more than %zu FEX tools, %s and later "
                        "are left out", max, g_tools[i].name);
            break;
        }
        names[n++] = g_tools[i].name;
    }
    return n;
}

void *np_compat_registered_tool(void *compat_mgr) {
    if (!compat_mgr)
        return NULL;

    load_tool_list_once();
    if (g_tool_count == 0) {
        void *entry = find_tool(compat_mgr, TOOL_DIR_NAME);
        return entry ? entry : find_tool(compat_mgr, LEGACY_TOOL_DIR_NAME);
    }

    for (int i = 0; i < g_tool_count; i++) {
        void *entry = find_tool(compat_mgr, g_tools[i].name);
        if (entry)
            return entry;
    }
    return NULL;
}
