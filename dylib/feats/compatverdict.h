// Players' verdicts and anti-cheat names for the Bridgeplay panel and the game page. The app
// writes compat-verdicts.tsv from the compat-data export (CompatVerdicts.swift); the dylib
// only reads it, when Steam loads the page, so nothing here touches the network.
#ifndef NOTPROTON_FEATS_COMPATVERDICT_H
#define NOTPROTON_FEATS_COMPATVERDICT_H

#include <stddef.h>

#define NP_VERDICT_FILE   "compat-verdicts.tsv"
#define NP_VERDICT_HEADER "bridgeplay-compat-verdicts"
// Larger files are not read: about 60,000 games.
#define NP_VERDICT_FILE_MAX (2u << 20)

// "\n;globalThis.MSCXVerdicts={...};" from the file in home's support folder, malloc'd, or
// NULL when there is no usable file. Only digits, lower-case ids, dots and the separators
// reach the page; a line that is anything else is skipped.
char *np_compatverdict_javascript(const char *home);

// The same from text already read, for the tests.
char *np_compatverdict_from(const char *text, size_t len);

#endif // NOTPROTON_FEATS_COMPATVERDICT_H
