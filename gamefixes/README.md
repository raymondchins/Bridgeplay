# gamefixes

Per-game defaults shipped with Bridgeplay: one `<appid>.conf` per game, plus `default.conf`
for every game. `make app-payload` bundles them into the app, which installs them into
`~/Library/Application Support/bridgeplay/gamefixes-default/`. The format, the allowed keys
and the order the files are read in are in [docs/GAMEFIXES.md](../docs/GAMEFIXES.md).

Add a file only with evidence, and cite it in a comment: a PCGamingWiki page, a umu-protonfixes
`gamefixes-steam/<appid>.py`, or a test run in `compat/runs/`. Launch arguments from
umu-protonfixes go in `ARGS`. File creation and winetricks have no equivalent key here and
are not seeded. Checked 2026-10-09 against all appids in `compat/games.json`: only 782330,
1245620, 377160, 22380, 489830 have a protonfix.
