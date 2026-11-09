# Apple Game Porting Toolkit: how Bridgeplay meets its license

The installer zip (`Bridgeplay-Installer.zip`, which the native installer and the app's Setup
Assistant also download) ships Apple's Game Porting Toolkit redistributables (`external/`, with
`D3DMetal.framework` and `libd3dshared.dylib`, and `wine/`, from the toolkit's `/redist/lib`
directory). They are Apple software under
Apple's license, shipped as `GPTK-License.rtf`; they are not in this repository. This page
maps each condition of that license (Game Porting Toolkit 4.0 beta 3) to what Bridgeplay
does. It is a record of the project's reading, not legal advice.

| License term | What it asks | How Bridgeplay meets it |
|---|---|---|
| 2A(i) | Install, internally use and test the software "for the sole purpose of developing, testing, or evaluating video games for use on Apple-branded products" | Unresolved. Distribution rests on 2A(iii), a separate grant, but the people who install Bridgeplay use the toolkit to play games they own, which is not plainly developing, testing or evaluating them. The project has no settled reading of how 2A(i) applies to that use and records the question here rather than an answer. |
| 2A(iii) | Distribute "solely for non-commercial purposes" | Bridgeplay is free: no price, paid tier, ads, donations or sponsorship, in the app, the site or the repository. README and NOTICE say so. |
| 2A, 2C | Keep Apple's copyright and proprietary notices on each copy | The installer ships Apple's `License.rtf` as `GPTK-License.rtf`, and the framework keeps its own `Resources/LICENSE`. `scripts/package-installer.sh` stops if the license file is missing. |
| 2C | Only the Framework "in its entirety" or parts of the Redistributables may be distributed apart from the toolkit | Only `D3DMetal.framework` (whole) and files from `/redist` are shipped. |
| 2D | No modifying or creating derivative works | Shipped unmodified. `package-installer.sh` refuses any Mach-O in the GPTK folder that does not carry Apple's own signature (`codesign -R 'anchor apple'`). |
| 2C | Not on non-Apple devices | The installer and the app require an Apple Silicon Mac. |
| 2C | No renting, selling, hosting or service bureau use | Users run it on their own Mac; nothing is hosted or resold. |
| 7B | Use only with materials you may legally use | Users play games they own in their own Steam library. |

Not covered by an automated check: the Windows DLLs under `wine/x86_64-windows` are PE files
that `codesign` cannot verify, so their integrity rests on copying them straight from Apple's
DMG. They are not Wine: they are Apple's proprietary D3DMetal front ends (`d3d10`, `d3d11`,
`d3d12`, `d3d12core`, `dxgi`, `nvapi64` and `nvngx-on-metalfx.dll`), under Apple's license
only. Apple publishes no source for them and Bridgeplay offers none. `wine/x86_64-unix` holds
only symlinks to `external/libd3dshared.dylib`. Bridgeplay's own `SOURCE.txt` note in the
local GPTK folder is left out of the installer.

When Apple ships a new toolkit version, reread its license and update this table.
