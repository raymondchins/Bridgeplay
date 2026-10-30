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
3. **Write the PR description yourself.** Translation is fine; plain human text is easier to
   review than generated text. Fill in the template: checks run, macOS, Steam build, engine.
4. **Keep comments short and useful.** Comment where the code is hard to follow, not where it
   is obvious.
5. **Think through the hard parts.** Code that runs inside Steam, the run script, lsteamclient,
   Wine patches and game saves interact in subtle ways. Consider multiple Steam accounts,
   libraries, macOS users and file systems.
6. **Run the checks** your change touches before opening the PR (`make ci-checks` runs them
   all; `make scriptcheck runcheck` also works on Linux).

## Process

- Pull requests go into `main`. Commits follow Conventional Commits (`feat(scope):`,
  `fix(scope):`, `docs:`).
- The maintainer reviews every PR. CI runs on PRs while the workflows are enabled; until then,
  say in the PR which checks you ran.
- Releases are made by the maintainer only (they need the Sparkle signing key); see
  [docs/RELEASING.md](docs/RELEASING.md).
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
| `vendor/cJSON.*`, `steam-shim/jsoncpp.cpp`, `steam-shim/json/` | MIT (cJSON), public domain / MIT (JsonCpp) |
| `compat/reported.json` | CC BY-NC-SA 3.0 (adapted from AppleGamingWiki), see [NOTICE](NOTICE) |

Changes that belong upstream are better sent to [NotProton](https://github.com/NotProtonNot/NotProton).

## Credit

Code you take from someone else keeps their name on it:

- Take a commit with `git cherry-pick -x <commit>`, so its author stays the commit's author
  and the message names where it came from. Don't amend it under your own name.
- If you rewrite someone's change, keep them as the author or add a
  `Co-authored-by: Name <email>` line, and name the commit or pull request in the message.
- New third-party code goes in [NOTICE](NOTICE) with its author and license.

This project follows a [Code of Conduct](CODE_OF_CONDUCT.md). Report problems at
https://github.com/raymondchins/Bridgeplay/issues.
