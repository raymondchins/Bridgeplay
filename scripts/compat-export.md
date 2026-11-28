# compat-export

`scripts/compat-export.py` copies players' compatibility reports out of the GitHub Discussions
and publishes them as static files on the orphan branch `compat-data`
(`.github/workflows/compat-export.yml`, hourly). bridgeplay.dev reads `compat.json` instead of
re-reading every Discussion, and the app can read `compat-index.json`. What each file holds and
what is left out for privacy: [`compat/data/README.md`](../compat/data/README.md), which is
published with the data.

```sh
GH_TOKEN=… scripts/compat-export.py fetch out           # add new reports to out/reports/
scripts/compat-export.py fetch out --full               # re-read every report
scripts/compat-export.py fetch out --prune              # also drop deleted reports
scripts/compat-export.py fetch out --from nodes.json    # offline, from Discussion nodes
scripts/compat-export.py build out                      # compat.json, compat-index.json, board.md
make compat-export-check                                # the fixture tests
```

The workflow adds new reports hourly, prunes once a day and runs `--full` on Sundays (UTC),
so a report edited after it was read is picked up within a week.

A `--full` read that finds under 90% of the stored reports, or a prune listing under half, stops
without changing the store (`--force` accepts it). `build` writes nothing when a file would match
an email, Steam ID, IP address, install ID or home-folder pattern.

## The verdict rule (rule 1)

Each game in `compat.json` gets
`verdict: {label, answer, n, p, i, b, since}`; `compat-index.json` carries the same as `v, n, p, i, b, since`.

1. **Window.** Reports from the last 120 days count. A game with nothing that recent keeps its
   older reports.
2. **One vote per Mac.** A schema 2 report carries `voter`, the report bot's code for one install
   and one game (an HMAC of the install ID and the AppID; another game gets an unrelated code).
   Each voter's newest report counts. A report without one (schema 1, a player who agreed to the
   first consent text, or no key on the server) falls back to its setup: chip, memory and macOS.
   The app asks once per game per Bridgeplay version, so several reports of one setup on one build
   are several Macs. The same setup on an older build is taken to be those Macs again and drops
   out, also when a voter reported that setup on the same or a newer build.
3. `n` counted Macs: `p` ran well (platinum, gold, silver), `i` ran with issues (bronze), `b` did
   not run (borked).
4. The first rule that matches wins:

| Label | When | `answer` |
|---|---|---|
| `one_report` | n < 2 | "One report so far: it ran well." |
| `broken_since` | It ran well on at least half the Macs up to the newest build it ran well on; then at least 2 Macs did not run it on newer Bridgeplay builds, and they are most of the reports on those builds. `since` is the oldest of those versions. The same test then runs on the Steam client build (schema 2's `steamBuild`): `since` reads "Steam build N" | "Ran well before 0.7.66, but did not run on 2 Macs since." |
| `playable` | p ≥ 2 and p ≥ 60% of n | "Ran well on 9 of 11 Macs." |
| `doesnt_run` | b ≥ 2 and b ≥ 60% of n | "Did not run on 5 of 6 Macs." |
| `mixed` | otherwise | "Mixed: 3 ran well, 2 had issues, 2 did not run." |

`total`, `counts` and `status` stay as `/api/compat` has them (every report, the old rule), so
the site can switch to `verdict` on its own schedule. The maintainers' `compat/games.json` is
not part of the verdict; the site's merge decides how the two meet.

The numbers live at the top of the script (`WINDOW_DAYS`, `MIN_REPORTS`, `SHARE`, `BROKEN_MIN`).
A change to them is a new rule number (`RULE`), so readers can tell verdicts apart.

## Anti-cheat names

`build --anticheat FILE` reads AreWeAntiCheatYet's `games.json` (MIT; the workflow downloads it
and builds without it when the download fails) and adds `anticheat: {"<appid>": ["eac", …]}` to
`compat-index.json`. Names map to the ids the Bridgeplay panel knows (`eac`, `battleye`,
`ricochet`, `vanguard`, `ace`, `xigncode3`, `nprotect`, `javelin`, `denuvo`, `vac`); any other
name is `other`, at most 4 per game. Games it lists as Running are left out, since they start
under Proton anyway. The app writes the names with the verdicts into `compat-verdicts.tsv` for the
panel ([dylib/feats/compatverdict.c](../dylib/feats/compatverdict.c)).

## Report schemas

The bot's ```json block says `schema: 1` or `schema: 2`; both are read, and a later number is
read as 2 with its unknown fields ignored. Schema 2 (app builds after 0.7.68, bridgeplay-web
`api/report.mjs`) adds `steamBuild`, `steamChannel`, `engineID`, `launch` (`code`, `seconds`,
`window`: the last launch's outcome record, `window: null` when the launch panel saw no
window), `bulk` (one answer from Report Your Games…) and, for consent 2, `voter`. `buildChannel`
and `updateState` come with both.

## Signature board

`board.md` groups the last 30 days of reports that did not run or had issues by signature: a
known cause from the `KNOWN` table in the script (anti-cheat, exFAT prefix, …), or the first
crash line of the report's error lines with numbers, addresses and quoted paths taken out.
"Look first" marks an unknown signature seen twice or more, or on the newest build. Below it,
games with 8 or more reports that failed in at least 60% of them. Add a `KNOWN` row when a cause
is understood.
