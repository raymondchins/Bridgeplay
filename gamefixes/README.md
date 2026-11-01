# gamefixes

Per-game overrides, one `<appid>.conf` per game, `KEY=VALUE` lines and `#` comments.

The allowed keys, the order the files are read in and the rest of the format are in
[docs/GAMEFIXES.md](../docs/GAMEFIXES.md).

Rule: add a file only with evidence, and cite the source in a comment (PCGamingWiki page, a
umu-protonfixes `gamefixes-steam/<appid>.py`, or a test run in `compat/runs/`). Launch arguments
from umu-protonfixes go in `ARGS`. File creation and winetricks have no equivalent key here and
are not seeded. Checked 2026-10-09 against all appids in `compat/games.json`: only 782330,
1245620, 377160, 22380, 489830 have a protonfix.
