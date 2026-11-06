#ifndef NP_QUICKSETTINGS_H
#define NP_QUICKSETTINGS_H

#include <stddef.h>

// Whether the in-game sidebar may set key to value.
int np_quick_settings_allowed(const char *key, const char *value);

// Reads and removes dir/<appid>.conf files into {"<appid>":{"KEY":"VALUE",...},...}.
// Returns how many apps had accepted changes, or -1 when json is too small.
int np_quick_settings_take(const char *dir, char *json, size_t cap);

#endif
