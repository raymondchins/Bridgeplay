# Upstream README (NotProton-WineHQ), kept for history

The current developer guide is [DEVELOPING.md](DEVELOPING.md).

> **This is a fork of [NotProton](https://github.com/NotProtonNot/NotProton).**
>
> I built this for my girlfriend. She only plays occasionally, maybe once or twice a month, and
> buying a CrossOver license for that just isn't worth it for us. So this fork adds a free WineHQ
> engine that runs without CrossOver.
>
> I'll keep maintaining it until someone asks me to stop. That said, don't expect it to stay up to
> date: I only work on it when I find the time and motivation, or when something breaks. This fork
> may lag far behind upstream.
>
> **If you actually want to support the developers**, please read
> [NotProtonNot/NotProton#37](https://github.com/NotProtonNot/NotProton/issues/37) first. It explains
> why the main project chose not to support WineHQ. If you can afford it, consider using the
> upstream project with CrossOver as intended.
>
> This fork is not affiliated with or endorsed by the NotProton developers, the Wine project
> (WineHQ), CodeWeavers or Valve. "Wine" and "CrossOver" are trademarks of their respective
> owners and are only used here to describe what the software works with. Please report problems
> with this fork [here](https://github.com/raymondchins/Bridgeplay/issues), not upstream.
>
> Modified by Leon Seemann, 2026. Like upstream, this fork is licensed under the GPLv3; see
> [NOTICE](NOTICE) for details.

---

## NotProton (upstream)

_From upstream's README._

NotProton enables the Steam Play experience from Linux Steam in the macOS Steam client.

This is done by forcibly enabling the Steam Play functionality in macOS Steam (which is
present and inert) as well as by porting some components of Valve's Proton to macOS.

This tool is intended to be used with the stable Steam Client (version 1791918634) as well as the beta Steam Client (version 1791686101) paired with **CrossOver 26.3 or CrossOver [Preview](https://www.codeweavers.com/preview)
20261006 / 20260821 / 20261015**, with more supported versions to come.

**NTFS file systems/drivers are not currently supported.**

Supporting specifically CrossOver is a design goal of this project. Better support for modifying CrossOver (using custom builds of DXMT/patched D3DMetal/MacGameVideoFix) will come in a future update, but support for alternatives to CrossOver itself is not planned.

Both the FEX and the Rosetta versions are supported. I recommend using the FEX version of the 
Preview 20261006, as it includes both the FEX version as well as the Rosetta one. 

I further recommend going into Steam Settings - Compatibility and selecting the Rosetta version as your default compatibility tool. You can select FEX on a per game basis by right clicking a game in Steam, going into Properties - Compatibility and selecting FEX there.

If a game has a native macOS version as well as a Windows one, Steam will download the macOS version. To override this behavior, right click on the game, select Properties, select Compatibility. Enable 'Force the use of a specific Steam Play compatibility tool'. Select whichever version of CrossOver you want to use. That will make Steam download the Windows version. Unchecking the 'Force the use...' box or selecting 'No Compatibility Tool' in the drop down list will revert to the macOS version of the game, with the specifics there varying based on your Steam version.

**Valve Anti-Cheat is not supported.** Proton itself does not support VAC in Valve titles; Valve ships native Linux ports instead. Bridgeplay does not promise that VAC titles work. 

## Free Wine engine (no CrossOver needed)

Bridgeplay can also run entirely on free software. Under Compatibility Tool, **Download & Set Up**
fetches the WineHQ 11.15 macOS build from [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds)
(hash pinned), unpacks it into `~/Library/Application Support/bridgeplay/engines/` and sets the
compatibility tool up from it exactly like a CrossOver copy. No CrossOver license is involved; the
license check is skipped only for loaders whose hash pins the free build.

11.15 is chosen because it is the Wine the bridge components (`lsteamclient`, `steam.exe`) are built
against. Differences from CrossOver to be aware of:

- It is an x86_64 build and runs under Rosetta 2, like the Rosetta build of CrossOver.
- Direct3D 10/11 goes through [DXMT](https://github.com/3Shain/dxmt) (master `e94c312`, LGPL-2.1+,
  see `docs/DXMT.md`), downloaded and pinned alongside Wine, which translates straight to Metal.
  Wine's own wined3d cannot reach feature level 11 on macOS OpenGL. D3DMetal is Apple's and needs
  CrossOver's Wine changes, so this engine does not use it; the WineCX engine can, with a Game
  Porting Toolkit you supply (`docs/WINECX.md`).
- DXMT needs macdrv functions upstream Wine hides; Bridgeplay ships a rebuilt `winemac.so`
  that exports them (see `winemac-patch/`).
- D3D 12 has no fast path; vkd3d over the bundled MoltenVK is limited.
- WineHQ has no msync/esync, so CPU-heavy games can run slower than under CrossOver or Sikarugir.
- The graphics backend options in the Steam panel have no effect on this engine.

To support another WineHQ build, run `ntdll-patch/resolve.py` against its Wine tree, build the
payloads with `ntdll-patch/build.sh` / `build32.sh`, and add the hashes to `SupportedRunners`,
`NtdllPatcher.byBuild` and `FreeEngine`.

Please read NOTICE for license information.

Please open issue reports with any issues. PRs are welcome and encouraged.

There are many people who worked on similar ideas, similar projects. I did not base NotProton on their work, but I still want to 
give thanks to the people who came before me:

[Nat Brown](https://github.com/natbro) made [Kaon](https://github.com/natbro/kaon), which is similar in goals to NotProton.

mont127's [Neutron](https://github.com/mont127/Neutron) is also a similar idea, but implemented differently. 

[Gio](https://github.com/giodotblue) was working enabling Steam Play inside of Steam on macOS prior to the release of NotProton itself. 
I would have done things differently had I been aware of that. 

Thanks to everyone who has positively contributed to macOS gaming. 

Developer Notes:

As far as the source structure goes, the macOS app itself is located in the ```app``` folder. The core logic is in ```dylib```.
```lsteamclient``` is a macOS port of Valve's lsteamclient. ```steam-shim```is a port of Valve's
steam-helper from Proton 9.0. ntdll-patch patches the copy of CrossOver that the app
makes/places in the ```~/Library/Application Support/bridgeplay/runners/``` folder so that
lsteamclient is loaded.
