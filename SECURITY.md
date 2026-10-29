# Security

Bridgeplay loads code into the Steam client and into games, re-signs Steam, and updates
itself with a signed Sparkle feed. Please report anything that could let someone else run
code through it, read Steam data, or ship a bad update.

## Reporting

Report privately through GitHub: **Security › Report a vulnerability** on
https://github.com/raymondchins/Bridgeplay/security. Please don't open a public issue for a
security problem.

Include what you found, how to reproduce it, and which Bridgeplay version (Status page) and
macOS version you used. You will get a reply within a week. Fixes ship as a normal Sparkle
update, and the release notes credit you unless you prefer not.

## Scope

In scope: the app, `notproton.dylib` and the run script, the installer, the update feed and
the shipped Wine patches.

Out of scope: Steam, Wine/WineCX, DXMT, DXVK and Apple's Game Porting Toolkit themselves;
report those upstream. Anything that needs an attacker who already runs code as your macOS
user is a hardening request, not a vulnerability, but it is still welcome as an issue.

## Known trade-offs

- Releases are signed with the maintainer's Apple Developer ID (Team AF38EA29BA) and notarized by Apple.
  Download only from https://bridgeplay.dev or GitHub.
- Steam is re-signed to load Bridgeplay, with a local "NotProton Local Signing" keychain identity or ad hoc,
  and loses Valve's hardened runtime.
- `notproton.dylib` loads for every macOS user of a shared `/Applications/Steam.app`.
- Setup removes quarantine in three places, each after a check. Bridgeplay.app must carry the
  maintainer's signature and Steam.app Valve's. The Wine engine must match its pinned hashes first. In a
  CrossOver clone only the Wine loader and `ntdll.dll` are pinned; the rest of the clone isn't checked
  file by file. macOS refuses to load a quarantined Wine file once Bridgeplay has patched it and signed
  it ad hoc. Setup also resets Steam's Accessibility, PostEvent and ListenEvent approvals
  (`tccutil`), re-signs Wine loaders ad hoc where needed, and sets Steam's default compatibility tool
  (`config.vdf`).
- Optional "Block Steam client updates" (`BootStrapperInhibitUpdateOnLaunch` in `steam.cfg`) also blocks
  Steam's security fixes.
- Game calls to Steam's `steamclient` are redirected in memory to Proton's lsteamclient (`ntdll-patch/`).
- D3DMetal games see an NVIDIA GeForce RTX 4090 by default (`NVAPI=1`) so DLSS shows up; `NVAPI=0` turns it off.
- For Apple's MetalFX DLSS only, patched `crypt32` and `wintrust` pass NVIDIA's signature check on Apple's
  `nvngx.dll` (`ngx-signer-patch/`).
- Some gamefixes turn off a game's Wine check to unlock DLSS (`/WineDetectionEnabled:False`,
  `HIDE_WINE_EXPORTS`).
- Updates are verified with an EdDSA signature (`SUPublicEDKey`) before they are installed.
