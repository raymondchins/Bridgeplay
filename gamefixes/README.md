# gamefixes

Per-game overrides, one `<appid>.conf` per game, `KEY=VALUE` lines and `#` comments.

Allowed keys: `BACKEND` (dxmt|dxvk|wined3d|d3dmetal), `DLLOVERRIDES` (Wine syntax), `MSYNC`, `RETINA`, and
env vars starting with `DXMT_`, `DXVK_`, `MVK_`, `VKD3D_`, `D3DM_`, or exactly `MTL_HUD_ENABLED`, `WINEDEBUG`,
`WINE_LARGE_ADDRESS_AWARE`, `WINE_CPU_TOPOLOGY`.

Rule: add a file only with evidence, and cite the source in a comment (PCGamingWiki page, a
umu-protonfixes `gamefixes-steam/<appid>.py`, or a test run in `compat/runs/`). Most umu-protonfixes
entries (launch arguments, file creation, winetricks) have no equivalent key here and are not seeded.
Checked 2026-10-09 against all appids in `compat/games.json`: only 782330, 1245620, 377160, 22380,
489830 have a protonfix, and none maps to the allowed keys.
