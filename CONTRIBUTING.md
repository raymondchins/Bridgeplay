# Contributing to Bridgeplay

Thanks for helping. Bridgeplay is a small, free project, so a short, focused pull request
is the easiest to review. An imperfect PR is still welcome: say what is unfinished and I can
help. These guidelines are adapted from
[NotProton's contribution guide](https://github.com/NotProtonNot/NotProton/blob/main/CONTRIBUTING.md)
by NotProtonNot.

1. **Open an issue first** for anything large, and check closed issues and PRs so work is not
   duplicated. Bugs use the "Bug report" template. To say how a game runs, answer the app's
   "How did it run?" after you play (or Prefix › Report Your Games… for all of them); without
   the app, use the "Game report" template.
2. **Read [docs/DEVELOPING.md](docs/DEVELOPING.md)** for what machine you need, how to build,
   how to try a change in Steam, and the checks. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
   says where new code goes.
3. **Think through the hard parts.** Code that runs inside Steam, the run script, lsteamclient,
   Wine patches and game saves interact in subtle ways. Consider several Steam accounts,
   Steam libraries (external drives too), macOS users sharing one Steam.app, and
   case-sensitive or non-APFS volumes. Never risk a game's saves or prefix.
4. **Run the checks** your change touches (`make ci-checks` runs the `app` workflow's;
   `make scriptcheck runcheck` also works on Linux).
5. **Fill in the PR template:** what and why, the checks you ran, macOS, Steam build and
   engine, and what you didn't test.
6. **Keep comments short and useful.** Comment where the code is hard to follow, not where it
   is obvious.

## Process

- Pull requests go into `main`. Commits follow Conventional Commits (`feat(scope):`,
  `fix(scope):`, `docs:`).
- CI (the `app` and `lint` workflows) runs on every PR. The maintainer reviews every PR.
- Releases are made by the maintainer only (they need the signing keys); see
  [docs/RELEASING.md](docs/RELEASING.md).
- Changes that belong upstream are better sent to [NotProton](https://github.com/NotProtonNot/NotProton).
- Security problems are reported privately; see [SECURITY.md](SECURITY.md).

## Licensing

A contribution is licensed under the license of the files it changes, as listed in
[NOTICE](NOTICE). For most of Bridgeplay that is the GPL-3.0 ([LICENSE](LICENSE)). The
exceptions:

| Path | License |
|---|---|
| `lsteamclient/` | Steamworks SDK License (Valve), see `LICENSE.lsteamclient` |
| `lsteamclient/steamworks_sdk_*/` | Valve's Steamworks SDK headers, redistributed under the Steamworks SDK License |
| `steam-shim/` | BSD-3-Clause (port of Proton's steam_helper), see `LICENSE.steam-shim` |
| `*-patch/` Wine patches and the Wine files built from them | LGPL-2.1-or-later, like Wine |
| `fonts/` | Each font's own license; the build files under `LICENSE.fonts` |
| `app/Sources/BridgeplayUI/Resources/Fonts/` | OFL-1.1 (`OFL-*.txt` there) |
| `app/Sources/BridgeplayApp/Resources/libSDL2-2.0.0.dylib` | zlib (SDL) |
| `vendor/cJSON.*`, `steam-shim/jsoncpp.cpp`, `steam-shim/json/` | MIT (cJSON), public domain / MIT (JsonCpp) |
| `installer/licenses/` | The license texts of DXMT and DXVK, shipped beside them |
| `compat/reported.json` | CC BY-NC-SA 3.0 (adapted from AppleGamingWiki), see [NOTICE](NOTICE) |

## Credit

Code you take from someone else keeps their name on it:

- Take a commit with `git cherry-pick -x <commit>`, so its author stays the commit's author
  and the message names where it came from. Don't amend it under your own name.
- If you rewrite someone's change, keep them as the author or add a
  `Co-authored-by: Name <email>` line, and name the commit or pull request in the message.
- New third-party code goes in [NOTICE](NOTICE) with its author and license.

This project follows a [Code of Conduct](CODE_OF_CONDUCT.md). Report problems at
https://github.com/raymondchins/Bridgeplay/issues.
