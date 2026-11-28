# Bridgeplay compatibility data

Players' reports of how Windows games ran on their Macs with [Bridgeplay](https://github.com/raymondchins/Bridgeplay),
exported every hour from the report Discussions by `scripts/compat-export.py`. Players sent these
reports from the app. The maintainers have not checked them.

| File | What it holds |
|---|---|
| `reports/YYYY-MM.ndjson` | One JSON object per line, one line per report, by the month it was sent |
| `compat.json` | Reports grouped per game, with a verdict (the data behind bridgeplay.dev/compatibility) |
| `compat-index.json` | AppID → verdict, counts, newest Bridgeplay build and date |
| `board.md` | Failing reports grouped by crash signature, for maintainers |

## A report line

| Field | Meaning |
|---|---|
| `n` | Discussion number: `https://github.com/raymondchins/Bridgeplay/discussions/<n>` |
| `date` | When the report was sent, UTC |
| `appid`, `name` | Steam AppID and the game's name. AppIDs of 2147483648 and up are non-Steam shortcuts |
| `status` | `platinum`, `gold`, `silver` ran well; `bronze` ran with issues; `borked` did not run |
| `chip` | Chip family (`M1` … `M5 Max`), or `Other` |
| `memory`, `macos` | RAM size (`16 GB`) and macOS version without the patch level (`macOS 26.1`) |
| `version`, `build` | Bridgeplay version (`0.7.66 (83)`) and its build number |
| `steam`, `steam_channel` | Steam client build and branch (`stable`, `publicbeta`), from schema 2 reports; `null` before |
| `engine`, `backend` | Wine engine (`WineCX 11.17 (msync, D3DMetal)`) and graphics backend (`d3dmetal`, `dxmt`, `dxvk`, `wined3d`) |
| `source` | `tap` (the player answered) or `auto` (the app inferred it) |
| `issue` | For `bronze`: `performance`, `crash`, `graphics`, `sound`, `controls` or `launcher` |
| `note` | The player's own words, shortened to 140 characters, with links, addresses, handles and numbers removed |
| `low_power`, `thermal` | Low Power Mode was on; the Mac's thermal state |
| `health`, `minutes`, `exit_status` | From the run log: `healthy`, `failed` or `unknown`; session length; the game's exit status |
| `gamefix` | Settings a gamefix applied, e.g. `{"BACKEND": "dxvk"}`. Launch arguments are left out |
| `sig` | For reports that did not run well: the first crash line with numbers, addresses and paths taken out, or a known cause such as `anti-cheat` |
| `schema` | The report's format: `1`, or `2` from Bridgeplay builds after 0.7.68 |
| `voter` | Schema 2: a code that is the same for one Mac's reports of one game and unrelated across games, so a Mac counts once per game. `null` when the player agreed only to the older consent text |
| `engine_id` | The engine's id (`winecx-11.17`), schema 2 |
| `launch` | Schema 2: how the last launch ended, `{code, seconds, window}`. `code` is the run script's outcome word (`ok`, `crashed`, `quit_early` …); `window` is seconds to the first window, `null` when none was seen |
| `bulk` | The answer came from Report Your Games…, one answer for several games |
| `channel` | The Bridgeplay build's channel (`stable`, `beta`) |

The verdict rule is in [`scripts/compat-export.md`](https://github.com/raymondchins/Bridgeplay/blob/main/scripts/compat-export.md).

## What is left out

No logs, and nothing that points to a person: no GitHub or Steam account, install ID, email, IP
address, Mac model, display, GPU core count or home-folder name. `voter` is made on the server
from the install ID and the AppID with a key that is not published: it links one Mac's reports
of the same game, never its reports of different games. Hardware goes down to the chip
family. The export refuses to publish when a file still matches an email, Steam ID, IP address or
home-folder pattern. A report deleted from the Discussions leaves this data within a day.

Ratings from other sites (AppleGamingWiki's `compat/reported.json`) are not part of this data.

## Licence

[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Credit "Bridgeplay players, via
github.com/raymondchins/Bridgeplay" and link here. Say "players report", with the number of
reports, rather than "verified". Bridgeplay is not affiliated with Valve or Apple.
