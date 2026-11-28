# Pause list

`pause-list.json` names Steam builds and channels on which Bridgeplay must stay out of Steam.
Every Mac checks a signed copy when Steam starts, so a Steam update that breaks Bridgeplay can
be paused for everyone without an app release. The list can only turn Bridgeplay off, each
signed copy expires (at most 31 days), and nothing in it is ever run.

The list is off until the key exists: with `NP_PAUSE_LIST_PUBLIC_KEY` empty in
[`dylib/feats/pauselist_key.h`](../dylib/feats/pauselist_key.h), the dylib reads and fetches
nothing. See [Making the key](#making-the-key).

## Pause a Steam build

1. Add an entry to `pause-list.json`:

   ```json
   {
     "days": 14,
     "entries": [
       { "steam_build": 1795567705, "channel": "publicbeta",
         "note": "Steam beta 1795567705 closes at start with Bridgeplay." }
     ]
   }
   ```

2. Open a pull request. The `pause-list` workflow checks the file
   (`python3 scripts/pause-list.py check` does the same locally).
3. Merge it. On `main` the workflow signs the list and uploads `pause-list.json` and
   `pause-list.json.sig` to the `pause-list` release once a reviewer of the `pause-list`
   environment approves.

When the fix ships, set `patch_build_max` to the last Bridgeplay build that breaks and
`fixed_in` to the fixed version, and publish again: older builds stay paused and say where the
fix is, the fixed build runs. Remove the entry once most Macs have updated. A signed copy
lasts `days`; to keep a pause longer, run the workflow again by hand.

| Key | Meaning |
|---|---|
| `steam_build` | One Steam client build: `"version"` in its manifest, the `steam_build` in `health.json` or the canary's issue |
| `steam_build_min`, `steam_build_max` | A range of builds, either end open. Not together with `steam_build` |
| `channel` | The Steam channel: `stable`, or the beta branch in `package/beta` (`publicbeta`) |
| `patch_build_max` | Only Bridgeplay builds up to this one are paused |
| `fixed_in` | The Bridgeplay version with the fix, shown in the notification and on Status |
| `note` | One line for the notification, at most 255 bytes |
| `url` | An `https` link with more, kept in `health.json` |

Each entry needs a Steam build, a range or a channel; every key it gives has to match. At most
32 entries. A dylib skips an entry with a key it doesn't know, so a new key never pauses more
on an older build than it meant to. `days` is 1 to 31 (default 14).

## What a Mac does

At each Steam start, before anything installs (`dylib/feats/pauselist.c`):

1. A pair an earlier start fetched replaces the cached copy if its Ed25519 signature checks out
   over the exact bytes, its length matches the `.sig` line and its serial is higher. A lower or
   equal serial is a rollback and is dropped.
2. The cached copy is checked again. An expired one pauses nothing but still blocks older
   serials. If an entry matches this Steam build, channel and Bridgeplay build, Steam starts
   passive, as after two bad starts: no hooks, no insert. `health.json` says `"mode":"passive"`,
   `"mode_reason":"pause_list"`, and one notification per Steam build, Bridgeplay build and
   `fixed_in` says so. Status shows "Paused for this Steam build". Try Again doesn't lift it.
3. Unless Bridgeplay is paused in the app, `/usr/bin/curl` starts detached to fetch the list for
   the next start, at most every 10 minutes: HTTPS only, no `~/.curlrc`, 3 s to connect, 8 s and
   64 KiB per file, user agent `Bridgeplay pause list` and nothing else about the Mac.

Steam never waits on the network. `make pauselistcheck` measured 0 to 1 ms for a start with
no fetch due and 12 to 51 ms for one that starts the fetch (starting `/bin/sh`), also with the
fetch hanging.

A fetch applies from the next Steam start. When a Steam update is the problem, that is the
start right after it: the old build's start fetches the list, then Steam restarts itself on the
new build. A Mac that already has the bad build fetches at its first bad start, so its second
start is paused instead of its third.

Files in the support folder: `pause-list.cache` (the signature line, then the list as
published), `pause-list.json.new` and `pause-list.json.sig.new` while a fetch waits to be
checked, and `pause-list-state.json` (last fetch, last notification).

To try a fix on a paused build, start Steam with `BRIDGEPLAY_PAUSE_LIST=0` in its
environment, for example after `launchctl setenv BRIDGEPLAY_PAUSE_LIST 0`
(`launchctl unsetenv BRIDGEPLAY_PAUSE_LIST` afterwards).

## Making the key

Once, on the maintainer's Mac. The private key never goes in the repository.

1. In a folder outside the repository, with OpenSSL 3 (`brew install openssl@3`):

   ```sh
   /opt/homebrew/opt/openssl@3/bin/openssl genpkey -algorithm ed25519 -out pause-list-key.pem
   python3 scripts/pause-list.py public-key --key-file pause-list-key.pem
   ```

2. Put the printed line in `NP_PAUSE_LIST_PUBLIC_KEY` in `dylib/feats/pauselist_key.h`.
3. Create the `pause-list` environment with required reviewers at
   https://github.com/raymondchins/Bridgeplay/settings/environments/new, then add the key as its
   secret:

   ```sh
   gh secret set BRIDGEPLAY_PAUSE_LIST_KEY --env pause-list -R raymondchins/Bridgeplay < pause-list-key.pem
   ```

4. Keep a copy in the password manager, then delete `pause-list-key.pem`.
5. Release a Bridgeplay build with the key in it, then run the workflow once at
   https://github.com/raymondchins/Bridgeplay/actions/workflows/pause-list.yml. It creates the
   `pause-list` prerelease, never Latest, because Latest is the update feed.

`scripts/pause-list.py sign` refuses a key that isn't the one in `pauselist_key.h`. A new key
needs a Bridgeplay release; builds with the old key keep reading lists signed with it until
they update. Publishing needs both the key and write access to the repository's releases.

## Checks

`make pauselistcheck`: signatures (good, changed byte, other key, wrong length), expiry, the
31-day limit, rollback, an offline or hanging fetch, the cache changed on disk, the switches,
then a list signed by `scripts/pause-list.py` with OpenSSL and checked by the dylib's code. The
signing part prints `skipped` without OpenSSL 3.
