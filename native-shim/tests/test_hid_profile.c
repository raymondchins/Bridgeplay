// Unit tests for hid_profile.c, without IOKit devices. Run through tests/run.sh.

#include "../hid_profile_internal.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "%s:%d: CHECK failed: %s\n", \
    __FILE__, __LINE__, #cond); exit(1); } } while (0)
#define NEAR(a, b) CHECK(fabsf((float)(a) - (float)(b)) < 1e-3f)
#define BTN(n) (1u << (n))

static const char *fixtures;

static size_t read_hex(const char *path, uint8_t *out, size_t cap) {
    FILE *f = fopen(path, "r");
    CHECK(f);
    size_t n = 0;
    int hi = -1, c;
    while ((c = fgetc(f)) != EOF) {
        int v = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10
              : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
        if (v < 0) continue;
        if (hi < 0) hi = v;
        else { CHECK(n < cap); out[n++] = (uint8_t)(hi << 4 | v); hi = -1; }
    }
    fclose(f);
    return n;
}

// Copy of the arithmetic of relay_report() in gamepad_shim.c (the hand-written
// GameSir G7 Pro translator this module replaces).
static int reference_relay(const uint8_t *report, long length, uint8_t x[18]) {
    if (report[0] != 7 || length < 10) return 0;
    memset(x, 0, 18);
    x[0] = 1;
    unsigned v[6] = {report[1] * 257u, report[2] * 257u, report[3] * 257u, report[4] * 257u,
                     report[9] * 1023u / 255u, report[8] * 1023u / 255u};
    for (int i = 0; i < 6; i++) { x[1 + 2 * i] = v[i] & 0xff; x[2 + 2 * i] = v[i] >> 8; }
    unsigned hat = report[5] & 0x0f;
    x[13] = hat < 8 ? hat + 1 : 0;
    x[14] = report[6];
    x[15] = report[7];
    return 1;
}

static np_profile *decode_hex(np_profile *p, const char *hex, np_pad_state *s) {
    uint8_t r[64];
    size_t n = 0;
    for (const char *c = hex; c[0] && c[1]; ) {
        if (c[0] == ' ') { c++; continue; }
        unsigned v;
        CHECK(sscanf(c, "%2x", &v) == 1);
        r[n++] = (uint8_t)v;
        c += 2;
    }
    CHECK(np_profile_decode(p, r[0], r, (long)n, s));
    return p;
}

static void test_gamesir(void) {
    char path[1024];
    uint8_t desc[1024];
    snprintf(path, sizeof path, "%s/gamesir_g7pro_bt.hex", fixtures);
    size_t len = read_hex(path, desc, sizeof desc);
    CHECK(len == 284);

    np_profile *p = np_profile_create_from_descriptor(desc, len, 0x3537, 0x1022, 0x011b,
                                                      "GameSir-G7 Pro");
    CHECK(p);
    CHECK(!strcmp(np_profile_guid(p), "0300000037350000221000001b010000"));
    CHECK(!strcmp(np_profile_name(p), "GameSir G7 Pro (Bluetooth)"));
    int axes, buttons, hats;
    np_profile_counts(p, &axes, &buttons, &hats);
    // Gamepad collection only: X Y Z Rz Accel Brake, buttons 1-16, one hat. The Consumer,
    // Keyboard and Mouse collections of the same device are not counted.
    CHECK(axes == 6 && buttons == 16 && hats == 1);

    // Reports of the other collections are not decoded.
    np_pad_state s;
    uint8_t consumer[] = {2, 0x01, 0x00, 0x00};
    uint8_t mouse[] = {6, 0x01, 0x10, 0x00, 0x10, 0x00, 0x00, 0x00};
    CHECK(!np_profile_decode(p, 2, consumer, sizeof consumer, &s));
    CHECK(!np_profile_decode(p, 6, mouse, sizeof mouse, &s));

    // Every recorded report: decode + encode == the hand-written translator, except for
    // the button bits the DB line leaves unmapped (b2 b5 b8 b9 b12 b15), which the old
    // translator copied through blindly and which are no Xbox control.
    const uint16_t mapped_bits = 0x6CDB;
    snprintf(path, sizeof path, "%s/gamesir_g7pro_bt_reports.txt", fixtures);
    FILE *f = fopen(path, "r");
    CHECK(f);
    char line[256];
    int compared = 0;
    while (fgets(line, sizeof line, f)) {
        unsigned id, n;
        int off;
        if (sscanf(line, "id=%u len=%u:%n", &id, &n, &off) != 2) continue;
        uint8_t r[64];
        const char *c = line + off;
        for (unsigned i = 0; i < n; i++) {
            unsigned v;
            int used;
            CHECK(sscanf(c, " %2x%n", &v, &used) == 1);
            r[i] = (uint8_t)v;
            c += used;
        }
        uint8_t want[18], got[18];
        CHECK(reference_relay(r, n, want));
        CHECK(np_profile_decode(p, id, r, n, &s));
        np_xbox_encode(&s, got);
        uint16_t want_b = (uint16_t)(want[14] | want[15] << 8) & mapped_bits;
        uint16_t got_b = (uint16_t)(got[14] | got[15] << 8);
        if (memcmp(want, got, 14) || want_b != got_b || got[16] || got[17]) {
            fprintf(stderr, "mismatch for %s", line);
            for (int i = 0; i < 18; i++) fprintf(stderr, " %02x/%02x", want[i], got[i]);
            fprintf(stderr, "\n");
            exit(1);
        }
        compared++;
    }
    fclose(f);
    CHECK(compared == 119);

    // Spot checks.
    uint8_t x[18];
    decode_hex(p, "07 80 82 81 82 0f 01 00 00 00 00", &s);  // A
    CHECK(s.buttons == BTN(NP_BTN_A));
    np_xbox_encode(&s, x);
    CHECK(x[0] == 1 && x[14] == 0x01 && x[15] == 0 && x[13] == 0);
    decode_hex(p, "07 80 82 81 82 00 00 00 00 00 00", &s);  // hat up
    CHECK(s.buttons == BTN(NP_BTN_DPAD_UP));
    np_xbox_encode(&s, x);
    CHECK(x[13] == 1);
    decode_hex(p, "07 80 82 81 82 03 00 00 00 00 00", &s);  // hat down-right
    CHECK(s.buttons == (BTN(NP_BTN_DPAD_DOWN) | BTN(NP_BTN_DPAD_RIGHT)));
    np_xbox_encode(&s, x);
    CHECK(x[13] == 4);
    decode_hex(p, "07 80 82 81 82 0f 00 00 00 ff 00", &s);  // brake = LT
    NEAR(s.lt, 1.0f);
    NEAR(s.rt, 0.0f);
    np_xbox_encode(&s, x);
    CHECK((x[9] | x[10] << 8) == 1023 && (x[11] | x[12] << 8) == 0);
    decode_hex(p, "07 00 ff 80 80 0f c0 0c 00 00 00", &s);  // LB RB back start, stick corner
    NEAR(s.lx, -1.0f);
    NEAR(s.ly, 1.0f);
    CHECK(s.buttons == (BTN(NP_BTN_LEFTSHOULDER) | BTN(NP_BTN_RIGHTSHOULDER) |
                        BTN(NP_BTN_BACK) | BTN(NP_BTN_START)));
    np_xbox_encode(&s, x);
    CHECK((x[1] | x[2] << 8) == 0 && (x[3] | x[4] << 8) == 65535);
    CHECK((x[14] | x[15] << 8) == (0x40 | 0x80 | 0x400 | 0x800));
    decode_hex(p, "07 80 82 81 82 0f 00 60 00 00 00", &s);  // L3 R3
    CHECK(s.buttons == (BTN(NP_BTN_LEFTSTICK) | BTN(NP_BTN_RIGHTSTICK)));
    np_profile_free(p);
    printf("ok  GameSir G7 Pro BT: %d recorded reports match relay_report\n", compared);
}

// Report ID-less DInput pad: X Y Z Rz (8 bit), hat, 12 buttons.
static const uint8_t generic_desc[] = {
    0x05, 0x01, 0x09, 0x04, 0xa1, 0x01,
    0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x04,
    0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x35, 0x81, 0x02,
    0x09, 0x39, 0x15, 0x00, 0x25, 0x07, 0x35, 0x00, 0x46, 0x3b, 0x01, 0x65, 0x14,
    0x75, 0x04, 0x95, 0x01, 0x81, 0x42,
    0x65, 0x00, 0x75, 0x04, 0x95, 0x01, 0x81, 0x03,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x0c, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x0c, 0x81, 0x02,
    0x75, 0x04, 0x95, 0x01, 0x81, 0x03,
    0xc0,
};

static void test_generic(void) {
    np_profile *p = np_profile_create_from_descriptor(generic_desc, sizeof generic_desc,
                                                      0x1234, 0x5678, 0x0100, "USB Gamepad");
    CHECK(p);
    CHECK(!strcmp(np_profile_guid(p), "03000000341200007856000000010000"));
    // The Windows line for this GUID is ignored.
    CHECK(!strcmp(np_profile_name(p), "Generic HID gamepad"));
    int axes, buttons, hats;
    np_profile_counts(p, &axes, &buttons, &hats);
    CHECK(axes == 4 && buttons == 12 && hats == 1);

    np_pad_state s;
    uint8_t r[7] = {0x80, 0x80, 0x80, 0x80, 0x0f, 0x00, 0x00};
    CHECK(np_profile_decode(p, 0, r, sizeof r, &s));
    CHECK(s.buttons == 0);
    NEAR(s.lx, 0.0039f);
    NEAR(s.lt, 0.0f);
    r[0] = 0x00; r[1] = 0xff; r[2] = 0xff; r[3] = 0x00;
    r[4] = 0x02;              // hat right
    r[5] = 0x01 | 0x10 | 0x40; // b0 (A), b4 (LB), b6 (LT digital)
    r[6] = 0x02 | 0x08;       // b9 (start), b11 (RS)
    CHECK(np_profile_decode(p, 0, r, sizeof r, &s));
    NEAR(s.lx, -1.0f);
    NEAR(s.ly, 1.0f);
    NEAR(s.rx, 1.0f);   // Z
    NEAR(s.ry, -1.0f);  // Rz
    NEAR(s.lt, 1.0f);
    NEAR(s.rt, 0.0f);
    CHECK(s.buttons == (BTN(NP_BTN_A) | BTN(NP_BTN_LEFTSHOULDER) | BTN(NP_BTN_DPAD_RIGHT) |
                        BTN(NP_BTN_START) | BTN(NP_BTN_RIGHTSTICK)));
    uint8_t x[18];
    np_xbox_encode(&s, x);
    CHECK(x[13] == 3 && (x[9] | x[10] << 8) == 1023);
    CHECK((x[14] | x[15] << 8) == (0x01 | 0x40 | 0x800 | 0x4000));
    // Short report: fields past the end keep their last value.
    CHECK(np_profile_decode(p, 0, r, 2, &s));
    np_profile_free(p);

    // A Mac line whose indices the device does not have is ignored.
    p = np_profile_create_from_descriptor(generic_desc, sizeof generic_desc, 0x1234, 0x5679,
                                          0x0100, "USB Gamepad");
    CHECK(p && !strcmp(np_profile_name(p), "Generic HID gamepad"));
    np_profile_free(p);

    // No exact GUID: the line without a version matches.
    p = np_profile_create_from_descriptor(generic_desc, sizeof generic_desc, 0x1234, 0x567a,
                                          0x0105, "USB Gamepad");
    CHECK(p && !strcmp(np_profile_name(p), "Versionless Pad"));
    uint8_t up[7] = {0x80, 0x80, 0x80, 0x80, 0x00, 0x01, 0x00};
    CHECK(np_profile_decode(p, 0, up, sizeof up, &s));
    CHECK(s.buttons == (BTN(NP_BTN_B) | BTN(NP_BTN_DPAD_UP)));  // a:b1,b:b0
    np_profile_free(p);

    // A Joystick with one Slider and no DB line: no standard control, so nothing is bound.
    static const uint8_t slider_desc[] = {
        0x05, 0x01, 0x09, 0x04, 0xa1, 0x01,
        0x09, 0x36, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02,
        0xc0,
    };
    p = np_profile_create_from_descriptor(slider_desc, sizeof slider_desc, 0x1234, 0x567b,
                                          0x0100, "Handbrake");
    CHECK(p && !strcmp(np_profile_name(p), "Generic HID gamepad"));
    np_profile_counts(p, &axes, &buttons, &hats);
    CHECK(axes == 1 && buttons == 0 && hats == 0);
    uint8_t slider[1] = {0x40};
    CHECK(!np_profile_decode(p, 0, slider, sizeof slider, &s));
    np_profile_free(p);
    printf("ok  generic DInput pad: default mapping, DB fallbacks\n");
}

// Report ID 3: X Y Rx Ry signed 16 bit, 4 buttons; plus a Consumer collection (ID 4).
static const uint8_t signed_desc[] = {
    0x05, 0x01, 0x09, 0x05, 0xa1, 0x01, 0x85, 0x03,
    0x16, 0x00, 0x80, 0x26, 0xff, 0x7f, 0x75, 0x10, 0x95, 0x04,
    0x09, 0x30, 0x09, 0x31, 0x09, 0x33, 0x09, 0x34, 0x81, 0x02,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x04, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x04, 0x81, 0x02,
    0x75, 0x04, 0x95, 0x01, 0x81, 0x03,
    0xc0,
    0x05, 0x0c, 0x09, 0x01, 0xa1, 0x01, 0x85, 0x04,
    0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x19, 0x01, 0x29, 0x08, 0x81, 0x02,
    0xc0,
};

static void put16s(uint8_t *at, int v) {
    at[0] = (uint8_t)(v & 0xff);
    at[1] = (uint8_t)((v >> 8) & 0xff);
}

static void test_signed16(void) {
    np_profile *p = np_profile_create_from_descriptor(signed_desc, sizeof signed_desc,
                                                      0x2222, 0x3333, 0x0001, "Pad16");
    CHECK(p);
    CHECK(!strcmp(np_profile_name(p), "Env Line"));  // SDL_GAMECONTROLLERCONFIG wins
    int axes, buttons, hats;
    np_profile_counts(p, &axes, &buttons, &hats);
    CHECK(axes == 4 && buttons == 4 && hats == 0);

    np_pad_state s;
    uint8_t r[10] = {3};
    put16s(r + 1, -32768); put16s(r + 3, -32768); put16s(r + 5, 32767); put16s(r + 7, -32768);
    r[9] = 0x02;
    CHECK(np_profile_decode(p, 3, r, sizeof r, &s));
    NEAR(s.lx, -1.0f);
    NEAR(s.ly, 1.0f);   // lefty:a1~
    NEAR(s.lt, 1.0f);   // lefttrigger:+a2
    NEAR(s.rt, 0.0f);   // righttrigger:-a2
    CHECK(s.buttons == (BTN(NP_BTN_A) | BTN(NP_BTN_DPAD_UP)));  // a:b1, dpup:-a3
    uint8_t x[18];
    np_xbox_encode(&s, x);
    CHECK((x[1] | x[2] << 8) == 0 && (x[3] | x[4] << 8) == 65535);

    put16s(r + 1, 32767); put16s(r + 3, 0); put16s(r + 5, -32768); put16s(r + 7, 0);
    r[9] = 0x01;
    CHECK(np_profile_decode(p, 3, r, sizeof r, &s));
    NEAR(s.lx, 1.0f);
    NEAR(s.ly, 0.0f);
    NEAR(s.lt, 0.0f);
    NEAR(s.rt, 1.0f);
    CHECK(s.buttons == BTN(NP_BTN_B));
    put16s(r + 1, -16384);
    CHECK(np_profile_decode(p, 3, r, sizeof r, &s));
    NEAR(s.lx, -0.5f);

    uint8_t consumer[2] = {4, 0xff};
    CHECK(!np_profile_decode(p, 4, consumer, sizeof consumer, &s));
    np_profile_free(p);
    printf("ok  signed 16-bit axes: normalisation, +/-/~ modifiers, report IDs\n");
}

static void test_left_alone(void) {
    const uint8_t *d = generic_desc;
    size_t n = sizeof generic_desc;
    CHECK(!np_profile_create_from_descriptor(d, n, 0x054C, 0x09CC, 0x0100, "Wireless Controller"));
    CHECK(!np_profile_create_from_descriptor(d, n, 0x045E, 0x0B13, 0x0100, "Controller"));
    CHECK(!np_profile_create_from_descriptor(d, n, 0x057E, 0x2009, 0x0100, "Pro Controller"));
    CHECK(!np_profile_create_from_descriptor(d, n, 0x057E, 0x2006, 0x0100, "Joy-Con (L)"));
    CHECK(!np_profile_create_from_descriptor(d, n, 0x0E6F, 0x02A4, 0x0100, "PDP Xbox Controller"));
    // Apple's VID is not "native": old GameSir pads (T3, 05ac:061a) use it.
    np_profile *p = np_profile_create_from_descriptor(d, n, 0x05AC, 0x061A, 0x0100, "GameSir-T3");
    CHECK(p);
    np_profile_free(p);
    // Nacon PS4-licensed pads are not Sony's.
    p = np_profile_create_from_descriptor(d, n, 0x146B, 0x0D01, 0x0100, "Nacon Revolution");
    CHECK(p);
    np_profile_free(p);

    // No gamepad collection: a mouse, and a vendor-page interface (Flydigi style).
    static const uint8_t mouse[] = {
        0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x09, 0x01, 0xa1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x03, 0x81, 0x02,
        0x75, 0x05, 0x95, 0x01, 0x81, 0x03,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x02, 0x81, 0x06,
        0xc0, 0xc0,
    };
    static const uint8_t vendor[] = {
        0x06, 0xa0, 0xff, 0x09, 0x01, 0xa1, 0x01,
        0x09, 0x02, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x20, 0x81, 0x02, 0xc0,
    };
    CHECK(!np_profile_create_from_descriptor(mouse, sizeof mouse, 0x1111, 0x2222, 1, "Mouse"));
    CHECK(!np_profile_create_from_descriptor(vendor, sizeof vendor, 0x04B4, 0x2412, 1, "Flydigi"));
    CHECK(!np_profile_create_from_descriptor(NULL, 0, 0x1111, 0x2222, 1, "x"));
    // Garbage must not crash.
    uint8_t junk[300];
    for (size_t i = 0; i < sizeof junk; i++) junk[i] = (uint8_t)(i * 73 + 11);
    np_profile_free(np_profile_create_from_descriptor(junk, sizeof junk, 0x1111, 0x2222, 1, "x"));
    // Collections nested past the parser's 32 levels, then an axis: it stays in the pad.
    uint8_t deep[100] = {0x05, 0x01, 0x09, 0x05};
    size_t m = 4;
    for (int i = 0; i < 40; i++) { deep[m++] = 0xa1; deep[m++] = 0x01; }
    static const uint8_t deep_axis[] = {0x09, 0x30, 0x15, 0x00, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02};
    memcpy(deep + m, deep_axis, sizeof deep_axis);
    m += sizeof deep_axis;
    p = np_profile_create_from_descriptor(deep, m, 0x1111, 0x2222, 1, "Deep");
    CHECK(p);
    int axes, buttons, hats;
    np_profile_counts(p, &axes, &buttons, &hats);
    CHECK(axes == 1 && buttons == 0 && hats == 0);
    np_profile_free(p);
    // A hat whose Logical Maximum has no room above it.
    static const uint8_t wide_hat[] = {
        0x05, 0x01, 0x09, 0x05, 0xa1, 0x01,
        0x09, 0x39, 0x15, 0x00, 0x27, 0xff, 0xff, 0xff, 0x7f, 0x75, 0x20, 0x95, 0x01, 0x81, 0x42,
        0xc0,
    };
    p = np_profile_create_from_descriptor(wide_hat, sizeof wide_hat, 0x1111, 0x2222, 1, "Wide");
    CHECK(p);
    np_profile_counts(p, &axes, &buttons, &hats);
    CHECK(axes == 0 && buttons == 0 && hats == 1);
    np_profile_free(p);
    printf("ok  left alone: Sony, Microsoft, Nintendo, \"Xbox\", non-gamepads\n");
}

static void test_encode_and_mode(void) {
    np_pad_state s = {0};
    uint8_t x[18];
    np_xbox_encode(&s, x);
    CHECK(x[0] == 1 && (x[1] | x[2] << 8) == 32767 && x[13] == 0);
    s.buttons = BTN(NP_BTN_GUIDE) | BTN(NP_BTN_Y) | BTN(NP_BTN_X) | BTN(NP_BTN_DPAD_LEFT) |
                BTN(NP_BTN_DPAD_UP);
    s.rt = 0.5f;
    np_xbox_encode(&s, x);
    CHECK((x[14] | x[15] << 8) == (0x1000 | 0x10 | 0x08) && x[13] == 8);
    CHECK((x[11] | x[12] << 8) == 511);
    s.buttons = BTN(NP_BTN_DPAD_UP) | BTN(NP_BTN_DPAD_DOWN) | BTN(NP_BTN_DPAD_LEFT);
    np_xbox_encode(&s, x);
    CHECK(x[13] == 7);

    CHECK(np_pad_mode_from(NULL, 1) == NP_MODE_HID);
    CHECK(np_pad_mode_from(NULL, 0) == (NP_MODE_HID | NP_MODE_GC));
    CHECK(np_pad_mode_from("gc", 1) == NP_MODE_GC);
    CHECK(np_pad_mode_from("both", 1) == (NP_MODE_HID | NP_MODE_GC));
    CHECK(np_pad_mode_from("off", 0) == NP_MODE_OFF);
    CHECK(np_pad_mode_from("hid", 0) == NP_MODE_HID);
    CHECK(np_pad_mode() == (NP_MODE_HID | NP_MODE_GC));  // no UnityPlayer, env unset
    printf("ok  xbox encode, pad mode\n");
}

int main(int argc, char **argv) {
    fixtures = argc > 1 ? argv[1] : "tests/fixtures";
    char db[1024];
    snprintf(db, sizeof db, "%s/test_gamecontrollerdb.txt", fixtures);
    setenv("NP_GAMECONTROLLERDB", db, 1);
    setenv("SDL_GAMECONTROLLERCONFIG",
           "03000000222200003333000001000000,Env Line,leftx:a0,lefty:a1~,lefttrigger:+a2,"
           "righttrigger:-a2,a:b1,b:b0,dpup:-a3,dpdown:+a3,platform:Mac OS X,\n"
           "03000000222200003333000001000000,Linux Line,a:b3,platform:Linux,\n", 1);
    unsetenv("NP_PAD_MODE");
    test_gamesir();
    test_generic();
    test_signed16();
    test_left_alone();
    test_encode_and_mode();
    printf("all tests passed\n");
    return 0;
}
