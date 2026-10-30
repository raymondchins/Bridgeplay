// HID game controller profiles: report descriptor parser, SDL GUID, gamecontrollerdb
// lookup, input report decoder and Xbox report encoder. See np_pad.h for the contract.
//
// Numbering follows SDL2's IOKit joystick backend (src/joystick/darwin/SDL_iokitjoystick.c),
// because gamecontrollerdb "Mac OS X" lines refer to its indices:
//   - axes:    GenericDesktop X..Wheel (0x30-0x38) and Simulation Rudder, Throttle,
//              Accelerator, Brake (0xBA, 0xBB, 0xC4, 0xC5);
//   - hats:    GenericDesktop Hat switch (0x39);
//   - buttons: Button page, Consumer page, and GenericDesktop D-pad Up/Down/Right/Left,
//              Start, Select, System Main Menu;
//   each list is ordered by usage number alone (page ignored), ties kept in descriptor
//   order (SDL's insertion sort with "usage >= current"). SDL drops an element only when
//   it has seen the same IOHIDElement (cookie) before; every element this parser creates
//   is distinct, so nothing is dropped by usage.
// One deliberate difference: SDL counts the elements of every top-level collection of a
// device whose primary usage is a gamepad, and skips devices whose primary usage is not.
// This parser takes only the GenericDesktop Joystick/GamePad/Multi-axis collection(s),
// whatever the primary usage, so a pad that also exposes Consumer, Keyboard, Mouse or
// vendor collections (GameSir over Bluetooth, Flydigi) is numbered as its gamepad part
// alone, and only the report IDs of that part are decoded.

#include "hid_profile_internal.h"

#include <CoreFoundation/CoreFoundation.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

#define PAGE_GD 0x01
#define PAGE_SIM 0x02
#define PAGE_BUTTON 0x09
#define PAGE_CONSUMER 0x0C

#define MAX_ELEMENTS 4096
#define MAX_LOCAL_USAGES 256
#define MAX_DEPTH 32
#define MAX_PUSH 16
#define MAX_BINDINGS 64

// ---------------------------------------------------------------------------------------
// Devices left alone: the system's GameController framework and games already handle them.
// product 0 = every product of the vendor. Apple's VID (0x05AC) is deliberately absent:
// older third-party pads (GameSir T3, 05ac:061a) report it and are plain HID pads. Nacon's
// PS4-licensed pads (146b, 3285) are absent too: Sony's driver does not take them.
static const struct { uint16_t vendor, product; } native_pads[] = {
    {0x045E, 0},      // Microsoft: every Xbox controller
    {0x054C, 0},      // Sony: DualShock 3/4, DualSense, DualSense Edge
    {0x057E, 0x2006}, // Nintendo Joy-Con (L)
    {0x057E, 0x2007}, // Nintendo Joy-Con (R)
    {0x057E, 0x2009}, // Nintendo Switch Pro Controller
    {0x057E, 0x200E}, // Nintendo Joy-Con charging grip (L+R)
};

static int is_native_pad(uint16_t vendor, uint16_t product, const char *name) {
    for (size_t i = 0; i < sizeof native_pads / sizeof native_pads[0]; i++)
        if (native_pads[i].vendor == vendor &&
            (native_pads[i].product == 0 || native_pads[i].product == product))
            return 1;
    return name && strcasestr(name, "Xbox") != NULL;
}

// ---------------------------------------------------------------------------------------
// Parsed elements.

enum { EL_VAR, EL_ARRAY };

typedef struct {
    uint16_t page, usage;
    uint8_t report_id, size, kind, in_pad;
    uint32_t bit;     // offset of the (first) field, counted after the report ID byte
    uint32_t count;   // EL_ARRAY: number of fields
    int32_t lmin, lmax;
    int32_t match;    // EL_ARRAY: field value that selects this element's usage
} hid_element;

enum { IN_BUTTON, IN_AXIS, IN_HAT };
enum { OUT_BUTTON, OUT_AXIS };
enum { AX_LX, AX_LY, AX_RX, AX_RY, AX_LT, AX_RT, AX_COUNT };

typedef struct {
    uint8_t in_type, out_type, out_index, hat_mask;
    uint16_t in_index;          // SDL index of the input axis, button or hat
    float imin, imax, omin, omax;
} binding;

struct np_profile {
    char guid[33];
    char name[128];
    int uses_ids;
    hid_element *el;
    int nel;
    int *axes, *buttons, *hats;  // SDL index -> element index
    int naxes, nbuttons, nhats;
    int32_t *raw;                // last value per element (EL_ARRAY: 1 = selected)
    binding bind[MAX_BINDINGS];
    int nbind;
    uint8_t mapped[256];         // report IDs that carry a mapped control
};

// ---------------------------------------------------------------------------------------
// Report descriptor parser.

typedef struct {
    uint32_t page, size, count, id;
    int32_t lmin, lmax;
    uint32_t lmax_raw;
    unsigned lmax_bytes;
} hid_globals;

typedef struct {
    uint32_t min, max;  // usage, with the page in the high 16 bits when ext
    uint8_t ext;
} usage_range;

typedef struct {
    usage_range r[MAX_LOCAL_USAGES];
    int n;
    uint32_t pending_min;
    uint8_t pending_ext, has_min;
} hid_locals;

typedef struct {
    hid_element *el;
    int nel, cap;
    int uses_ids, has_pad;
} parse_result;

static void add_range(hid_locals *l, uint32_t min, uint32_t max, uint8_t ext) {
    if (l->n >= MAX_LOCAL_USAGES) return;
    if (max < min) max = min;
    l->r[l->n].min = min;
    l->r[l->n].max = max;
    l->r[l->n].ext = ext;
    l->n++;
}

static uint32_t usage_total(const hid_locals *l) {
    uint64_t total = 0;
    for (int i = 0; i < l->n; i++) total += (uint64_t)(l->r[i].max - l->r[i].min) + 1;
    return total > MAX_ELEMENTS ? MAX_ELEMENTS : (uint32_t)total;
}

// i-th usage of the local list as page << 16 | usage; page is the one in effect now
// (at the main item) unless the usage carried its own (4-byte usage).
static uint32_t usage_at(const hid_locals *l, uint32_t page, uint32_t i) {
    for (int k = 0; k < l->n; k++) {
        uint32_t span = l->r[k].max - l->r[k].min;
        if (i <= span) {
            uint32_t u = l->r[k].min + i;
            return l->r[k].ext ? u : (page << 16) | (u & 0xffff);
        }
        i -= span + 1;
    }
    return 0;
}

static int add_element(parse_result *o, const hid_element *e) {
    if (o->nel >= MAX_ELEMENTS) return 0;
    if (o->nel == o->cap) {
        int cap = o->cap ? o->cap * 2 : 64;
        hid_element *grown = realloc(o->el, (size_t)cap * sizeof *grown);
        if (!grown) return 0;
        o->el = grown;
        o->cap = cap;
    }
    o->el[o->nel++] = *e;
    return 1;
}

static void parse_input(parse_result *o, const hid_globals *g, const hid_locals *l,
                        uint32_t flags, uint8_t in_pad, uint32_t bit) {
    if (flags & 1) return;  // Constant: padding
    uint32_t total = usage_total(l);
    if (!total || g->size == 0 || g->size > 32 || g->count == 0) return;
    int32_t lmax = g->lmax;
    // Logical Maximum is signed per spec, but devices write e.g. 25 FF meaning 255.
    if (g->lmin >= 0 && lmax < g->lmin && g->lmax_bytes < 4)
        lmax = (int32_t)g->lmax_raw;
    hid_element e = {0};
    e.report_id = (uint8_t)g->id;
    e.size = (uint8_t)g->size;
    e.in_pad = in_pad;
    e.lmin = g->lmin;
    e.lmax = lmax;
    if (flags & 2) {  // Variable: one field per usage, the last usage repeats
        e.kind = EL_VAR;
        uint32_t count = g->count > MAX_ELEMENTS ? MAX_ELEMENTS : g->count;
        for (uint32_t f = 0; f < count; f++) {
            uint32_t u = usage_at(l, g->page, f < total ? f : total - 1);
            e.page = (uint16_t)(u >> 16);
            e.usage = (uint16_t)u;
            e.bit = bit + f * g->size;
            if (!add_element(o, &e)) return;
        }
    } else {  // Array: IOKit exposes one button element per usage of the list
        e.kind = EL_ARRAY;
        e.bit = bit;
        e.count = g->count;
        for (uint32_t k = 0; k < total; k++) {
            uint32_t u = usage_at(l, g->page, k);
            e.page = (uint16_t)(u >> 16);
            e.usage = (uint16_t)u;
            e.match = (int32_t)((int64_t)g->lmin + k);
            if (!add_element(o, &e)) return;
        }
    }
}

static void parse_descriptor(const uint8_t *d, size_t len, parse_result *o) {
    hid_globals g = {0}, stack[MAX_PUSH];
    int sp = 0;
    hid_locals l;
    memset(&l, 0, sizeof l);
    uint64_t bits[256] = {0};
    uint8_t pad[MAX_DEPTH];
    int depth = 0;
    size_t i = 0;
    while (i < len) {
        uint8_t prefix = d[i++];
        if (prefix == 0xFE) {  // long item: size, tag, data
            if (i + 2 > len) break;
            i += 2 + (size_t)d[i];
            continue;
        }
        unsigned size = prefix & 3;
        if (size == 3) size = 4;
        unsigned type = (prefix >> 2) & 3, tag = prefix >> 4;
        if (i + size > len) break;
        uint32_t u = 0;
        for (unsigned k = 0; k < size; k++) u |= (uint32_t)d[i + k] << (8 * k);
        int32_t s = size == 1 ? (int8_t)u : size == 2 ? (int16_t)u : (int32_t)u;
        i += size;

        if (type == 1) {  // Global
            switch (tag) {
            case 0: g.page = u & 0xffff; break;
            case 1: g.lmin = s; break;
            case 2: g.lmax = s; g.lmax_raw = u; g.lmax_bytes = size; break;
            case 7: g.size = u; break;
            case 8: g.id = u & 0xff; o->uses_ids = 1; break;
            case 9: g.count = u; break;
            case 10: if (sp < MAX_PUSH) stack[sp++] = g; break;
            case 11: if (sp > 0) g = stack[--sp]; break;
            }
        } else if (type == 2) {  // Local
            uint8_t ext = size == 4;
            switch (tag) {
            case 0: add_range(&l, u, u, ext); break;
            case 1: l.pending_min = u; l.pending_ext = ext; l.has_min = 1; break;
            case 2:
                if (l.has_min) {
                    uint32_t max = l.pending_ext && !ext ? (l.pending_min & 0xffff0000u) | (u & 0xffff) : u;
                    add_range(&l, l.pending_min, max, l.pending_ext);
                    l.has_min = 0;
                }
                break;
            }
        } else if (type == 0) {  // Main
            uint8_t in_pad = depth > 0 && pad[(depth < MAX_DEPTH ? depth : MAX_DEPTH) - 1];
            switch (tag) {
            case 8:  // Input
                parse_input(o, &g, &l, u, in_pad, (uint32_t)bits[g.id & 0xff]);
                bits[g.id & 0xff] += (uint64_t)g.size * g.count;
                break;
            case 10: {  // Collection
                uint32_t usage = l.n ? usage_at(&l, g.page, 0) : 0;
                uint8_t is_pad = in_pad;
                if ((usage >> 16) == PAGE_GD) {
                    uint16_t gd = usage & 0xffff;
                    if (gd == 0x04 || gd == 0x05 || gd == 0x08) is_pad = 1;
                }
                if (is_pad) o->has_pad = 1;
                if (depth < MAX_DEPTH) pad[depth] = is_pad;
                depth++;
                break;
            }
            case 12: if (depth > 0) depth--; break;
            }
            memset(&l, 0, sizeof l);
        }
    }
}

// ---------------------------------------------------------------------------------------
// SDL classification and decoding helpers.

enum { CLS_NONE, CLS_AXIS, CLS_BUTTON, CLS_HAT };

static int classify(const hid_element *e) {
    switch (e->page) {
    case PAGE_GD:
        if (e->usage >= 0x30 && e->usage <= 0x38) return CLS_AXIS;
        if (e->usage == 0x39) return CLS_HAT;
        if ((e->usage >= 0x90 && e->usage <= 0x93) || e->usage == 0x3D || e->usage == 0x3E ||
            e->usage == 0x85)
            return CLS_BUTTON;
        return CLS_NONE;
    case PAGE_SIM:
        return e->usage == 0xBA || e->usage == 0xBB || e->usage == 0xC4 || e->usage == 0xC5
                   ? CLS_AXIS : CLS_NONE;
    case PAGE_BUTTON:
    case PAGE_CONSUMER:
        return CLS_BUTTON;
    }
    return CLS_NONE;
}

// SDL's insertion: after every element whose usage is <= this one.
static void insert_sorted(int *list, int *n, const hid_element *el, int index) {
    int at = *n;
    while (at > 0 && el[list[at - 1]].usage > el[index].usage) {
        list[at] = list[at - 1];
        at--;
    }
    list[at] = index;
    (*n)++;
}

static int read_field(const uint8_t *data, long len, uint32_t bit, unsigned size, int sign,
                      int32_t *out) {
    if (size == 0 || size > 32 || (uint64_t)bit + size > (uint64_t)len * 8) return 0;
    uint64_t v = 0;
    unsigned got = 0;
    while (got < size) {
        uint32_t b = bit + got;
        unsigned shift = b & 7, take = 8 - shift;
        if (take > size - got) take = size - got;
        v |= (uint64_t)((data[b >> 3] >> shift) & ((1u << take) - 1)) << got;
        got += take;
    }
    if (sign && size < 64 && (v >> (size - 1)) & 1) *out = (int32_t)((int64_t)v - ((int64_t)1 << size));
    else *out = (int32_t)(uint32_t)v;
    return 1;
}

static void update_element(np_profile *p, int index, unsigned id, const uint8_t *data, long len) {
    const hid_element *e = &p->el[index];
    if (e->report_id != id) return;
    int sign = e->lmin < 0;
    int32_t v;
    if (e->kind == EL_VAR) {
        if (read_field(data, len, e->bit, e->size, sign, &v)) p->raw[index] = v;
        return;
    }
    int32_t hit = 0;
    for (uint32_t f = 0; f < e->count; f++) {
        if (!read_field(data, len, e->bit + f * e->size, e->size, sign, &v)) break;
        if (v == e->match) { hit = 1; break; }
    }
    p->raw[index] = hit;
}

static float axis_value(const np_profile *p, int sdl_axis) {
    const hid_element *e = &p->el[p->axes[sdl_axis]];
    if (e->lmax == e->lmin) return 0.0f;
    double n = ((double)p->raw[p->axes[sdl_axis]] - e->lmin) / ((double)e->lmax - e->lmin) * 2.0 - 1.0;
    return (float)(n < -1.0 ? -1.0 : n > 1.0 ? 1.0 : n);
}

// SDL_HAT_* bits: up 1, right 2, down 4, left 8.
static int hat_bits(const np_profile *p, int sdl_hat) {
    static const uint8_t pos[8] = {1, 3, 2, 6, 4, 12, 8, 9};
    const hid_element *e = &p->el[p->hats[sdl_hat]];
    int64_t range = (int64_t)e->lmax - e->lmin + 1;
    int64_t v = (int64_t)p->raw[p->hats[sdl_hat]] - e->lmin;
    if (range == 4) v *= 2;
    else if (range != 8) v = -1;
    return v >= 0 && v < 8 ? pos[v] : 0;
}

// ---------------------------------------------------------------------------------------
// gamecontrollerdb.

typedef struct {
    uint8_t guid[16];
    char *name, *mapping;
} db_entry;

static db_entry *db;
static int db_count, db_cap;
static pthread_once_t db_once = PTHREAD_ONCE_INIT;

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static void db_add_line(const char *line, int need_platform) {
    while (*line == ' ' || *line == '\t') line++;
    if (!*line || *line == '#') return;
    const char *c1 = strchr(line, ',');
    if (!c1 || c1 - line != 32) return;
    const char *c2 = strchr(c1 + 1, ',');
    if (!c2) return;
    uint8_t guid[16];
    for (int i = 0; i < 16; i++) {
        int hi = hexval(line[2 * i]), lo = hexval(line[2 * i + 1]);
        if (hi < 0 || lo < 0) return;
        guid[i] = (uint8_t)(hi << 4 | lo);
    }
    // Lines for another platform number their elements differently: never use them.
    const char *plat = strstr(c2, "platform:");
    if (plat) {
        plat += 9;
        size_t n = strcspn(plat, ",\r\n");
        if (n != 8 || strncasecmp(plat, "Mac OS X", 8) != 0) return;
    } else if (need_platform) {
        return;
    }
    size_t end = strcspn(c2 + 1, "\r\n");
    char *name = strndup(c1 + 1, (size_t)(c2 - c1 - 1));
    char *mapping = strndup(c2 + 1, end);
    if (!name || !mapping) { free(name); free(mapping); return; }
    if (db_count == db_cap) {
        int cap = db_cap ? db_cap * 2 : 64;
        db_entry *grown = realloc(db, (size_t)cap * sizeof *grown);
        if (!grown) { free(name); free(mapping); return; }
        db = grown;
        db_cap = cap;
    }
    memcpy(db[db_count].guid, guid, 16);
    db[db_count].name = name;
    db[db_count].mapping = mapping;
    db_count++;
}

static void db_load_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    char *line = NULL;
    size_t cap = 0;
    while (getline(&line, &cap, f) > 0) db_add_line(line, 1);
    free(line);
    fclose(f);
}

static void db_load_once(void) {
    const char *path = getenv("NP_GAMECONTROLLERDB");
    if (path && *path) {
        db_load_file(path);
    } else {
        const char *home = getenv("HOME");
        if (home) {
            // The notproton folder is read until the app moves it to bridgeplay.
            char buf[1024];
            struct stat st;
            snprintf(buf, sizeof buf, "%s/Library/Application Support/bridgeplay", home);
            const char *dir = stat(buf, &st) == 0 ? "bridgeplay" : "notproton";
            snprintf(buf, sizeof buf, "%s/Library/Application Support/%s/gamecontrollerdb.txt", home, dir);
            db_load_file(buf);
        }
    }
    const char *env = getenv("SDL_GAMECONTROLLERCONFIG");
    if (env && *env) {
        char *copy = strdup(env), *save = NULL;
        if (copy) {
            for (char *l = strtok_r(copy, "\n", &save); l; l = strtok_r(NULL, "\n", &save))
                db_add_line(l, 0);
            free(copy);
        }
    }
}

void np_db_load(void) {
    pthread_once(&db_once, db_load_once);
}

// ---------------------------------------------------------------------------------------
// Mapping strings -> bindings.

static const char *const button_keys[NP_BTN_COUNT] = {
    "a", "b", "x", "y", "back", "guide", "start", "leftstick", "rightstick",
    "leftshoulder", "rightshoulder", "dpup", "dpdown", "dpleft", "dpright", "misc1",
};
static const char *const axis_keys[AX_COUNT] = {
    "leftx", "lefty", "rightx", "righty", "lefttrigger", "righttrigger",
};

static long parse_uint(const char **s) {
    if (**s < '0' || **s > '9') return -1;
    long v = 0;
    while (**s >= '0' && **s <= '9') {
        v = v * 10 + (**s - '0');
        if (v > 100000) return -1;
        (*s)++;
    }
    return v;
}

// Returns 0 when the pair names an input the device does not have (the line is wrong for
// this device), 1 otherwise (bound, or a key that is not a control and was skipped).
static int parse_pair(np_profile *p, const char *key, size_t klen, const char *val, size_t vlen) {
    char out_half = 0;
    if (klen && (*key == '+' || *key == '-')) { out_half = *key; key++; klen--; }
    binding b = {0};
    int found = 0;
    for (int i = 0; i < NP_BTN_COUNT && !found; i++)
        if (strlen(button_keys[i]) == klen && !strncmp(key, button_keys[i], klen)) {
            b.out_type = OUT_BUTTON; b.out_index = (uint8_t)i; found = 1;
        }
    for (int i = 0; i < AX_COUNT && !found; i++)
        if (strlen(axis_keys[i]) == klen && !strncmp(key, axis_keys[i], klen)) {
            b.out_type = OUT_AXIS; b.out_index = (uint8_t)i; found = 1;
            if (i >= AX_LT) { b.omin = 0; b.omax = 1; }
            else if (out_half == '+') { b.omin = 0; b.omax = 1; }
            else if (out_half == '-') { b.omin = 0; b.omax = -1; }
            else { b.omin = -1; b.omax = 1; }
        }
    if (!found || !vlen) return 1;

    char tmp[32];
    if (vlen >= sizeof tmp) return 1;
    memcpy(tmp, val, vlen);
    tmp[vlen] = 0;
    const char *s = tmp;
    char in_half = 0;
    if (*s == '+' || *s == '-') in_half = *s++;
    char kind = *s++;
    long index = parse_uint(&s);
    if (index < 0) return 1;
    if (kind == 'a') {
        if (index >= p->naxes) return 0;
        b.in_type = IN_AXIS;
        if (in_half == '+') { b.imin = 0; b.imax = 1; }
        else if (in_half == '-') { b.imin = 0; b.imax = -1; }
        else { b.imin = -1; b.imax = 1; }
        if (*s == '~') { float t = b.imin; b.imin = b.imax; b.imax = t; }
    } else if (kind == 'b') {
        if (index >= p->nbuttons) return 0;
        b.in_type = IN_BUTTON;
    } else if (kind == 'h') {
        if (index >= p->nhats || *s++ != '.') return index >= p->nhats ? 0 : 1;
        long mask = parse_uint(&s);
        if (mask <= 0 || mask > 15) return 1;
        b.in_type = IN_HAT;
        b.hat_mask = (uint8_t)mask;
    } else {
        return 1;
    }
    b.in_index = (uint16_t)index;
    if (p->nbind < MAX_BINDINGS) p->bind[p->nbind++] = b;
    return 1;
}

// Replaces the profile's bindings with mapping's. Returns 0 (and leaves no bindings) when
// the mapping references an axis, button or hat the descriptor does not have.
static int apply_mapping(np_profile *p, const char *mapping) {
    p->nbind = 0;
    const char *s = mapping;
    while (*s) {
        size_t n = strcspn(s, ",");
        const char *colon = memchr(s, ':', n);
        if (colon && !parse_pair(p, s, (size_t)(colon - s), colon + 1, n - (size_t)(colon - s) - 1)) {
            p->nbind = 0;
            return 0;
        }
        s += n;
        if (*s == ',') s++;
    }
    return 1;
}

static int find_axis(const np_profile *p, uint16_t page, uint16_t usage) {
    for (int i = 0; i < p->naxes; i++) {
        const hid_element *e = &p->el[p->axes[i]];
        if (e->page == page && e->usage == usage) return i;
    }
    return -1;
}

// SDL "generic" style layout from the descriptor alone.
static void apply_generic(np_profile *p) {
    char m[512] = "";
    size_t n = 0;
#define ADD(...) n += (size_t)snprintf(m + n, n < sizeof m ? sizeof m - n : 0, __VA_ARGS__)
    int x = find_axis(p, PAGE_GD, 0x30), y = find_axis(p, PAGE_GD, 0x31);
    int z = find_axis(p, PAGE_GD, 0x32), rx = find_axis(p, PAGE_GD, 0x33);
    int ry = find_axis(p, PAGE_GD, 0x34), rz = find_axis(p, PAGE_GD, 0x35);
    int accel = find_axis(p, PAGE_SIM, 0xC4), brake = find_axis(p, PAGE_SIM, 0xC5);
    int lt = -1, rt = -1;
    if (x >= 0) ADD("leftx:a%d,", x);
    if (y >= 0) ADD("lefty:a%d,", y);
    if (z >= 0 && rz >= 0) {
        ADD("rightx:a%d,righty:a%d,", z, rz);
        if (rx >= 0 && ry >= 0) { lt = rx; rt = ry; }
    } else if (rx >= 0 && ry >= 0) {
        ADD("rightx:a%d,righty:a%d,", rx, ry);
    }
    if (accel >= 0 && brake >= 0) { lt = brake; rt = accel; }
    if (lt >= 0) ADD("lefttrigger:a%d,righttrigger:a%d,", lt, rt);
    static const char *const order[] = {
        "a", "b", "x", "y", "leftshoulder", "rightshoulder", "lefttrigger", "righttrigger",
        "back", "start", "leftstick", "rightstick", "guide",
    };
    for (int i = 0; i < (int)(sizeof order / sizeof order[0]) && i < p->nbuttons; i++) {
        if ((i == 6 || i == 7) && lt >= 0) continue;  // analog triggers already bound
        ADD("%s:b%d,", order[i], i);
    }
    if (p->nhats > 0) ADD("dpup:h0.1,dpright:h0.2,dpdown:h0.4,dpleft:h0.8,");
#undef ADD
    apply_mapping(p, m);
    snprintf(p->name, sizeof p->name, "Generic HID gamepad");
}

// DB match ignoring the CRC field (bytes 2-3), optionally the version too (bytes 12-13).
// Later lines win. A line that does not fit the descriptor is skipped.
static int apply_db(np_profile *p, const uint8_t guid[16], int ignore_version) {
    for (int i = db_count - 1; i >= 0; i--) {
        const uint8_t *g = db[i].guid;
        if (memcmp(g, guid, 2) || memcmp(g + 4, guid + 4, 8) || memcmp(g + 14, guid + 14, 2))
            continue;
        if (!ignore_version && memcmp(g + 12, guid + 12, 2)) continue;
        if (!apply_mapping(p, db[i].mapping)) continue;
        snprintf(p->name, sizeof p->name, "%s", db[i].name);
        return 1;
    }
    return 0;
}

static void make_guid(uint8_t g[16], uint16_t vendor, uint16_t product, uint16_t version,
                      const char *name) {
    memset(g, 0, 16);
    g[0] = 0x03;  // SDL_HARDWARE_BUS_USB: SDL's IOKit backend uses it for every device
    // g[2..3] = CRC16 of the name in SDL; gamecontrollerdb lines carry 0 and SDL ignores it.
    if (vendor) {
        g[4] = vendor & 0xff; g[5] = vendor >> 8;
        g[8] = product & 0xff; g[9] = product >> 8;
        g[12] = version & 0xff; g[13] = version >> 8;
    } else if (name) {
        strlcpy((char *)g + 4, name, 12);
    }
}

// ---------------------------------------------------------------------------------------
// Public API.

np_profile *np_profile_create_from_descriptor(const uint8_t *descriptor, size_t length,
                                              uint16_t vendor, uint16_t product,
                                              uint16_t version, const char *name) {
    if (!descriptor || !length || is_native_pad(vendor, product, name)) return NULL;
    parse_result o = {0};
    parse_descriptor(descriptor, length, &o);
    np_profile *p = NULL;
    if (!o.has_pad || !o.nel || !(p = calloc(1, sizeof *p))) goto fail;
    p->el = o.el;
    p->nel = o.nel;
    p->uses_ids = o.uses_ids;
    p->axes = calloc((size_t)o.nel, sizeof(int));
    p->buttons = calloc((size_t)o.nel, sizeof(int));
    p->hats = calloc((size_t)o.nel, sizeof(int));
    p->raw = calloc((size_t)o.nel, sizeof(int32_t));
    if (!p->axes || !p->buttons || !p->hats || !p->raw) goto fail_profile;
    for (int i = 0; i < o.nel; i++) {
        if (!o.el[i].in_pad) continue;
        switch (classify(&o.el[i])) {
        case CLS_AXIS: insert_sorted(p->axes, &p->naxes, o.el, i); break;
        case CLS_BUTTON: insert_sorted(p->buttons, &p->nbuttons, o.el, i); break;
        case CLS_HAT: insert_sorted(p->hats, &p->nhats, o.el, i); break;
        }
    }
    if (!p->naxes && !p->nbuttons && !p->nhats) goto fail_profile;
    // Axes rest at their centre and hats at "none" until the first report says otherwise.
    for (int i = 0; i < p->naxes; i++) {
        const hid_element *e = &p->el[p->axes[i]];
        p->raw[p->axes[i]] = (int32_t)(((int64_t)e->lmin + e->lmax + 1) / 2);
    }
    for (int i = 0; i < p->nhats; i++)
        p->raw[p->hats[i]] = (int32_t)((uint32_t)p->el[p->hats[i]].lmax + 1u);

    uint8_t guid[16];
    make_guid(guid, vendor, product, version, name);
    for (int i = 0; i < 16; i++) snprintf(p->guid + 2 * i, 3, "%02x", guid[i]);
    np_db_load();
    if (!apply_db(p, guid, 0) && !apply_db(p, guid, 1)) apply_generic(p);

    for (int i = 0; i < p->nbind; i++) {
        const binding *b = &p->bind[i];
        const int *list = b->in_type == IN_AXIS ? p->axes : b->in_type == IN_HAT ? p->hats : p->buttons;
        p->mapped[p->el[list[b->in_index]].report_id] = 1;
    }
    return p;

fail_profile:
    np_profile_free(p);
    return NULL;
fail:
    free(o.el);
    return NULL;
}

static int number_property(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    int out = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &out);
    return out;
}

np_profile *np_profile_create(IOHIDDeviceRef device) {
    if (!device) return NULL;
    CFTypeRef desc = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDReportDescriptorKey));
    if (!desc || CFGetTypeID(desc) != CFDataGetTypeID()) return NULL;
    char name[256] = "";
    CFTypeRef product = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    if (product && CFGetTypeID(product) == CFStringGetTypeID() &&
        !CFStringGetCString((CFStringRef)product, name, sizeof name, kCFStringEncodingUTF8))
        name[0] = 0;
    return np_profile_create_from_descriptor(
        CFDataGetBytePtr((CFDataRef)desc), (size_t)CFDataGetLength((CFDataRef)desc),
        (uint16_t)number_property(device, CFSTR(kIOHIDVendorIDKey)),
        (uint16_t)number_property(device, CFSTR(kIOHIDProductIDKey)),
        (uint16_t)number_property(device, CFSTR(kIOHIDVersionNumberKey)), name);
}

void np_profile_free(np_profile *p) {
    if (!p) return;
    free(p->el);
    free(p->axes);
    free(p->buttons);
    free(p->hats);
    free(p->raw);
    free(p);
}

void np_profile_counts(const np_profile *p, int *axes, int *buttons, int *hats) {
    if (axes) *axes = p ? p->naxes : 0;
    if (buttons) *buttons = p ? p->nbuttons : 0;
    if (hats) *hats = p ? p->nhats : 0;
}

const char *np_profile_guid(const np_profile *p) { return p ? p->guid : ""; }
const char *np_profile_name(const np_profile *p) { return p ? p->name : ""; }

// Allocation-free. Keeps the last value of every element in the profile, so controls spread
// over several reports combine; one profile must not be decoded from two threads at once.
int np_profile_decode(np_profile *p, uint32_t reportID, const uint8_t *report, long length,
                      np_pad_state *state) {
    if (!p || !report || !state || length <= 0) return 0;
    unsigned id = 0;
    const uint8_t *data = report;
    long len = length;
    if (p->uses_ids) {
        id = report[0];
        if (reportID && reportID != id) return 0;
        data++;
        len--;
    }
    if (!p->mapped[id]) return 0;
    for (int i = 0; i < p->naxes; i++) update_element(p, p->axes[i], id, data, len);
    for (int i = 0; i < p->nbuttons; i++) update_element(p, p->buttons[i], id, data, len);
    for (int i = 0; i < p->nhats; i++) update_element(p, p->hats[i], id, data, len);

    float axes[AX_COUNT] = {0};
    uint32_t buttons = 0;
    for (int i = 0; i < p->nbind; i++) {
        const binding *b = &p->bind[i];
        int pressed = 0, have_value = 0;
        float value = 0;
        if (b->in_type == IN_AXIS) {
            float v = axis_value(p, b->in_index);
            float lo = fminf(b->imin, b->imax), hi = fmaxf(b->imin, b->imax);
            if (v < lo || v > hi) continue;
            float t = (v - b->imin) / (b->imax - b->imin);
            if (b->out_type == OUT_AXIS) { value = b->omin + t * (b->omax - b->omin); have_value = 1; }
            else pressed = t >= 0.5f;
        } else {
            pressed = b->in_type == IN_BUTTON ? p->raw[p->buttons[b->in_index]] != 0
                                              : (hat_bits(p, b->in_index) & b->hat_mask) != 0;
            if (b->out_type == OUT_AXIS && pressed) { value = b->omax; have_value = 1; }
        }
        if (b->out_type == OUT_BUTTON) {
            if (pressed) buttons |= 1u << b->out_index;
        } else if (have_value && fabsf(value) > fabsf(axes[b->out_index])) {
            axes[b->out_index] = value;
        }
    }
    for (int i = 0; i < AX_COUNT; i++) {
        float lo = i >= AX_LT ? 0.0f : -1.0f;
        axes[i] = axes[i] < lo ? lo : axes[i] > 1.0f ? 1.0f : axes[i];
    }
    state->lx = axes[AX_LX];
    state->ly = axes[AX_LY];
    state->rx = axes[AX_RX];
    state->ry = axes[AX_RY];
    state->lt = axes[AX_LT];
    state->rt = axes[AX_RT];
    state->buttons = buttons;
    return 1;
}

static void put16(uint8_t *at, unsigned v) {
    at[0] = v & 0xff;
    at[1] = (v >> 8) & 0xff;
}

static unsigned stick16(float v) {
    if (!(v >= -1.0f)) v = -1.0f;
    if (v > 1.0f) v = 1.0f;
    // Round half down so rest (0) gives 32767; 8-bit inputs land exactly on x * 257.
    return (unsigned)floor(((double)v + 1.0) * 0.5 * 65535.0 + 0.499);
}

static unsigned trigger10(float v) {
    if (!(v >= 0.0f)) v = 0.0f;
    if (v > 1.0f) v = 1.0f;
    unsigned t = (unsigned)floor((double)v * 1023.0 + 1e-3);
    return t > 1023 ? 1023 : t;
}

void np_xbox_encode(const np_pad_state *s, uint8_t out[NP_XBOX_REPORT_LEN]) {
    static const int8_t xbox_bit[NP_BTN_COUNT] = {
        [NP_BTN_A] = 0, [NP_BTN_B] = 1, [NP_BTN_X] = 3, [NP_BTN_Y] = 4,
        [NP_BTN_BACK] = 10, [NP_BTN_GUIDE] = 12, [NP_BTN_START] = 11,
        [NP_BTN_LEFTSTICK] = 13, [NP_BTN_RIGHTSTICK] = 14,
        [NP_BTN_LEFTSHOULDER] = 6, [NP_BTN_RIGHTSHOULDER] = 7,
        [NP_BTN_DPAD_UP] = -1, [NP_BTN_DPAD_DOWN] = -1, [NP_BTN_DPAD_LEFT] = -1,
        [NP_BTN_DPAD_RIGHT] = -1, [NP_BTN_MISC1] = -1,
    };
    memset(out, 0, NP_XBOX_REPORT_LEN);
    out[0] = 0x01;
    put16(out + 1, stick16(s->lx));
    put16(out + 3, stick16(s->ly));
    put16(out + 5, stick16(s->rx));
    put16(out + 7, stick16(s->ry));
    put16(out + 9, trigger10(s->lt));
    put16(out + 11, trigger10(s->rt));
    uint32_t b = s->buttons;
    int up = (b >> NP_BTN_DPAD_UP) & 1, down = (b >> NP_BTN_DPAD_DOWN) & 1;
    int left = (b >> NP_BTN_DPAD_LEFT) & 1, right = (b >> NP_BTN_DPAD_RIGHT) & 1;
    if (up && down) up = down = 0;
    if (left && right) left = right = 0;
    uint8_t hat = 0;
    if (up) hat = right ? 2 : left ? 8 : 1;
    else if (down) hat = right ? 4 : left ? 6 : 5;
    else if (right) hat = 3;
    else if (left) hat = 7;
    out[13] = hat;
    uint32_t xb = 0;
    for (int i = 0; i < NP_BTN_COUNT; i++)
        if ((b >> i) & 1 && xbox_bit[i] >= 0) xb |= 1u << xbox_bit[i];
    out[14] = xb & 0xff;
    out[15] = (xb >> 8) & 0xff;
    out[16] = (xb >> 16) & 0xff;
    out[17] = (xb >> 24) & 0xff;
}

int np_pad_mode_from(const char *env, int has_unity) {
    if (env && *env) {
        if (!strcasecmp(env, "hid")) return NP_MODE_HID;
        if (!strcasecmp(env, "gc")) return NP_MODE_GC;
        if (!strcasecmp(env, "both")) return NP_MODE_HID | NP_MODE_GC;
        if (!strcasecmp(env, "off")) return NP_MODE_OFF;
    }
    return has_unity ? NP_MODE_HID : NP_MODE_HID | NP_MODE_GC;
}

static int pad_mode;
static pthread_once_t mode_once = PTHREAD_ONCE_INIT;

// Images are all mapped before any initializer runs, so a constructor already sees
// UnityPlayer when the game links it. A later dlopen of UnityPlayer is not noticed.
static void pad_mode_once(void) {
    int unity = 0;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n && !unity; i++) {
        const char *image = _dyld_get_image_name(i);
        unity = image && strstr(image, "UnityPlayer") != NULL;
    }
    pad_mode = np_pad_mode_from(getenv("NP_PAD_MODE"), unity);
}

int np_pad_mode(void) {
    pthread_once(&mode_once, pad_mode_once);
    return pad_mode;
}
