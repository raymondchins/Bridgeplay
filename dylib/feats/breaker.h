// Crash-loop breaker, Pause and the health files the app's Status reads.
//
// Files, in the per-user support folder:
//   boot.json        the start being counted: key, pid, t0, stage, strikes, notified
//   health.json      what this Steam start did (np_health_t), written by steam_osx
//   health-web.json  the compat UI gates, written by Steam Helper
//   paused           made and removed by the app: while it exists nothing installs
//   pause-list.*     the signed pause list and its fetch state (pauselist.h)
//
// The app's "Try Again" deletes boot.json, which clears the strikes. It does not lift a pause
// from the list, which ends when the list drops the entry, expires or Bridgeplay updates.
#ifndef NOTPROTON_FEATS_BREAKER_H
#define NOTPROTON_FEATS_BREAKER_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    NP_MODE_ACTIVE = 0,
    NP_MODE_PASSIVE,   // two bad starts on this key, or the pause list: no hooks, no insert
    NP_MODE_OFF,       // paused by the user
} np_mode_t;

// Pause, the strikes and the pause list all start Steam with no hooks. That Steam configures
// every installed Windows game for macOS and removes its content (Update Required, then a
// deletion on update), so all three stay off: the paused file and the list are ignored and a
// start past the strikes stays active. The app hides Pause to match
// (SteamHealthStore.offModesEnabled).
// CEILING: off modes disabled outright — re-enable once a paused start keeps the compat layer in.
#ifndef NP_BREAKER_OFF_MODES
#define NP_BREAKER_OFF_MODES 0
#endif

#define NP_BOOT_STRIKES_MAX     2
#define NP_BOOT_HEALTHY_SECONDS 120

#define NP_STAGE_BOOT    "boot"
#define NP_STAGE_CLIENT  "client"
#define NP_STAGE_HEALTHY "healthy"
#define NP_STAGE_EXITED  "exited"
#define NP_STAGE_PASSIVE "passive"

#define NP_BOOT_FILE       "boot.json"
#define NP_HEALTH_FILE     "health.json"
#define NP_HEALTH_WEB_FILE "health-web.json"
#define NP_PAUSED_FILE     "paused"

// health.json "mode_reason"
#define NP_REASON_PAUSED     "paused"
#define NP_REASON_STRIKES    "strikes"
#define NP_REASON_PAUSE_LIST "pause_list"

typedef struct {
    char      key[64];     // "<steam build>:<BRIDGEPLAY_BUILD>"
    int       pid;
    long long t0;
    char      stage[16];
    int       strikes;
    int       notified;
} np_boot_t;

typedef struct {
    const char *key;
    int         pid;
    long long   now;
    long long   own_start;     // this process's start time, 0 when unknown
    int         paused;
    int         listed;        // the pause list names this Steam build
    int         prev_running;  // prev->pid is another steam_osx that is still running
} np_boot_env_t;

typedef enum {
    NP_BOOT_RECORD = 0,  // write `next`
    NP_BOOT_PAUSED,      // nothing counted
    NP_BOOT_LISTED,      // passive from the pause list, nothing counted
    NP_BOOT_SECOND,      // another steam_osx owns the state
} np_boot_verdict_t;

typedef struct {
    long long          written;
    int                pid;
    int                patch_build;
    unsigned long long steam_build;
    char               channel[64];
    unsigned long long sigdb_build;
    np_mode_t          mode;
    int                strikes;
    int                signatures_resolved;
    int                signatures_required;
    int                hooks_installed;
    int                hooks_total;
    int                layout_known;
    char               reason[16];        // NP_REASON_*, empty while active
    char               pause_list[16];    // np_pl_status_name
    unsigned long long pause_serial;
    long long          pause_expires;
    char               pause_note[256];   // the entry that paused this start
    char               pause_fixed_in[32];
    char               pause_url[256];
} np_health_t;

// Pure parts, tested by breakercheck.
np_boot_verdict_t np_boot_decide(const np_boot_t *prev, const np_boot_env_t *env,
                                 np_boot_t *next, np_mode_t *mode, int *notify);
int  np_boot_advance(np_boot_t *s, int pid, const char *stage);
int  np_boot_read(const char *path, np_boot_t *out);
int  np_boot_write(const char *path, const np_boot_t *s);
int  np_steam_build(const char *package_dir, char *out, size_t cap);
void np_steam_channel(const char *package_dir, char *out, size_t cap);
char *np_health_format(const np_health_t *h);
const char *np_mode_name(np_mode_t mode);
int  np_write_atomic(const char *path, const char *bytes, size_t len);

// steam_osx constructor. A mode other than active has already dropped the insert,
// written health.json and, on a new trip, posted the one notification.
np_mode_t np_breaker_start(void);
// Any process: steam_osx's own decision, or for Steam Helper the paused file and the
// mode in health.json.
np_mode_t np_breaker_mode(void);
void np_breaker_drop_insert(void);

void np_breaker_client_seen(void);
// Starts the 120 s after which this start counts as healthy and clears the strikes.
void np_breaker_arm_healthy(void);
void np_breaker_exit(void);

void np_health_signatures(int resolved, int required);
void np_health_hooks(int installed, int total);
void np_health_sigdb(uint64_t build);
void np_health_layout(int known);
void np_health_flush(void);

// Steam Helper, after the web patch looked at a chunk carrying a compat UI.
void np_health_web(const char *shape, size_t applied, size_t total, int drifted);

#endif // NOTPROTON_FEATS_BREAKER_H
