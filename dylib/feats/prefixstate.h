// What the Compatibility page needs to know about a game's prefix before it runs.
#ifndef NOTPROTON_FEATS_PREFIXSTATE_H
#define NOTPROTON_FEATS_PREFIXSTATE_H

#include <limits.h>
#include <stddef.h>
#include <stdint.h>

#define NP_PREFIX_FIELD_MAX 256

typedef struct {
    // Where to look. server_root is Wine's /tmp/.wine-<uid>.
    const char *steam_root;
    const char *support_root;
    const char *server_root;
} np_prefix_roots_t;

typedef struct {
    int  has_prefix;
    char compatdata[PATH_MAX];
    char prefix_arch[16];
    char last_build[NP_PREFIX_FIELD_MAX];
    char last_display[NP_PREFIX_FIELD_MAX];
    char tool[NP_PREFIX_FIELD_MAX];
    char tool_build[NP_PREFIX_FIELD_MAX];
    char tool_flavor[NP_PREFIX_FIELD_MAX];
    char tool_display[NP_PREFIX_FIELD_MAX];
    int  needs_rebuild;
    // A wineserver holds the prefix, so the game or a Wine tool is running.
    int  running;
    // setup, copy or finish while the app rebuilds, then done, done-backup or failed.
    char rebuild[16];
    // The app the installer recorded, empty when it is gone.
    char app[PATH_MAX];
} np_prefix_state_t;

// Appids with a manifest in any library folder, up to max. Returns how many it wrote.
size_t np_prefix_installed_apps(const char *steam_root, uint32_t *appids, size_t max);

// Fills `st` for `appid` as `tool` would run it.
void np_prefix_state(uint32_t appid, const char *tool, const np_prefix_roots_t *roots,
                     np_prefix_state_t *st);

// 1 while a rebuild is under way.
int np_prefix_rebuilding(const np_prefix_state_t *st);

// The page's JSON. Returns the length written, or -1 when it does not fit.
int np_prefix_state_json(uint32_t appid, const np_prefix_state_t *st, char *out, size_t cap);

#endif // NOTPROTON_FEATS_PREFIXSTATE_H
