// The signed pause list: Steam builds and channels on which Bridgeplay stays out of Steam.
//
// pause-list.json and pause-list.json.sig sit on the `pause-list` release
// (pause-list/README.md). The list can only turn Bridgeplay off, and it expires. At each
// Steam start, before anything installs:
//   1. a pair fetched by an earlier start (pause-list.json.new, pause-list.json.sig.new)
//      replaces pause-list.cache when its signature checks out and its serial is higher;
//   2. pause-list.cache is checked again (signature, expiry) and matched against this Steam
//      build, channel and Bridgeplay build;
//   3. unless Bridgeplay is paused, /usr/bin/curl starts detached to fetch the list for the
//      next start, at most every NP_PL_FETCH_EVERY seconds.
// Steam's start never waits on the network. With no key built in (pauselist_key.h), or with
// BRIDGEPLAY_PAUSE_LIST=0, nothing is read or fetched.
#ifndef NOTPROTON_FEATS_PAUSELIST_H
#define NOTPROTON_FEATS_PAUSELIST_H

#include <stddef.h>
#include <stdint.h>

#define NP_PL_MAX_ENTRIES   32
#define NP_PL_MAX_BYTES     65536
#define NP_PL_MAX_LIFETIME  (31LL * 86400)
#define NP_PL_FETCH_EVERY   600

#define NP_PL_CACHE_FILE "pause-list.cache"
#define NP_PL_NEW_FILE   "pause-list.json.new"
#define NP_PL_NEW_SIG    "pause-list.json.sig.new"
#define NP_PL_STATE_FILE "pause-list-state.json"

#define NP_PAUSE_LIST_URL \
    "https://github.com/raymondchins/Bridgeplay/releases/download/pause-list/pause-list.json"

typedef enum {
    NP_PL_UNKEYED = 0,  // no public key built in: the list is off
    NP_PL_IGNORED,      // BRIDGEPLAY_PAUSE_LIST=0
    NP_PL_NONE,         // nothing cached yet
    NP_PL_OK,
    NP_PL_EXPIRED,
    NP_PL_INVALID,      // signature, length or format refused
} np_pl_status_t;

typedef struct {
    int                has_min, has_max, has_patch_max;
    unsigned long long steam_min, steam_max;
    int                patch_max;
    char               channel[64];
    char               note[256];
    char               fixed_in[32];
    char               url[256];
} np_pl_entry_t;

typedef struct {
    unsigned long long serial;
    long long          issued, expires;
    int                count;
    np_pl_entry_t      entries[NP_PL_MAX_ENTRIES];
} np_pl_list_t;

typedef struct {
    np_pl_status_t     status;
    unsigned long long serial;
    long long          expires;
    int                matched;
    int                fetched;   // a fetch was started for the next start
    np_pl_entry_t      entry;     // the entry that matched
} np_pl_result_t;

// Pure parts, tested by pauselistcheck.
const char *np_pl_status_name(np_pl_status_t status);
int np_pl_base64(const char *in, size_t len, uint8_t *out, size_t cap);
int np_pl_parse_sig(const char *text, size_t len, uint8_t sig[64], size_t *length);
int np_pl_parse(const char *json, size_t len, np_pl_list_t *out);
np_pl_status_t np_pl_check(const uint8_t *json, size_t len, const char *sig, size_t sig_len,
                           const uint8_t key[32], long long now, np_pl_list_t *out);
const np_pl_entry_t *np_pl_match(const np_pl_list_t *list, unsigned long long steam_build,
                                 const char *channel, int patch_build);

// Steps 1 to 3 above. `dir` is the support folder; `off` (the app's Pause) skips the fetch.
void np_pause_list_start(const char *dir, unsigned long long steam_build, const char *channel,
                         int patch_build, int off, long long now, np_pl_result_t *out);

// 1 once per Steam build, Bridgeplay build and fix version that the list paused; records it.
int np_pause_list_announce(const char *dir, const char *key, const np_pl_entry_t *entry);

#endif // NOTPROTON_FEATS_PAUSELIST_H
