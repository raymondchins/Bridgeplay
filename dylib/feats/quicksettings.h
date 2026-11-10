#ifndef NP_QUICKSETTINGS_H
#define NP_QUICKSETTINGS_H

#include <stddef.h>
#include <time.h>

// Whether the in-game sidebar may set key to value.
int np_quick_settings_allowed(const char *key, const char *value);

// Reads and removes dir/<appid>.conf files into {"<appid>":{"KEY":"VALUE",...},...}.
// A file last written before since is removed unread and counted in *stale: it is from an
// earlier Steam session, which may have been another Steam account's.
// Returns how many apps had accepted changes, or -1 when json is too small.
int np_quick_settings_take(const char *dir, time_t since, char *json, size_t cap, int *stale);

#endif
