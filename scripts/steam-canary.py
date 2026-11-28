#!/usr/bin/env python3
"""Steam build canary: notices a new Mac Steam client build on the stable or beta channel,
downloads the packages that hold steamclient.dylib and steamui.dylib, verifies them against
the manifest and runs anchorcheck --client-dir on them. .github/workflows/steam-canary.yml
calls it; it runs the same way on a Mac.

  steam-canary.py poll   --state FILE --manifests DIR [--channel stable --channel beta]
  steam-canary.py check  --channel NAME --manifest FILE --cache DIR --work DIR --anchorcheck BIN
  steam-canary.py record --state FILE --results DIR
  steam-canary.py report --results DIR --out FILE [--state FILE] [--run-url URL]
  steam-canary.py parse  MANIFEST

poll prints the channels whose build, or whose signatures, changed since the last record.
check writes <work>/<channel>.json and <channel>.log; its exit code is 0 when the check ran
(read "verdict" for the outcome), 1 when it could not run (network, hash, unpack).
report writes the issue text for the results and prints "fail", "pass" or "none"; a channel
not checked in this run counts with its last recorded verdict from --state.
Downloads, the state file and Valve's files are untrusted: no field is ever run.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

BASE_URL = "https://client-update.akamai.steamstatic.com/"
# The plain manifest names. The "_signed-2" names Steam keeps in package/ return 404.
CHANNELS = {
    "stable": "steam_client_osx",
    "beta": "steam_client_publicbeta_osx",
}
# steamclient.dylib, steamui.dylib and every @loader_path library they pull in.
PACKAGES = ["bins_client_osx", "bins_osx", "bins_codecs_osx", "bins_misc_osx",
            "bins_hardware_osx", "sdl3_osx", "breakpad_osx"]
# What anchorcheck's verdict depends on. A change here re-checks builds already seen.
FINGERPRINT_PATHS = ["signatures/macos.arm64", "dylib/tests/anchorcheck.c",
                     "dylib/resolver", "dylib/core/macho.c", "dylib/core/macho.h"]
MAX_MANIFEST = 1 << 20
MAX_PACKAGE = 512 << 20
TIMEOUT = 120


class CanaryError(Exception):
    pass


# --- Valve KeyValues text --------------------------------------------------------------

_TOKEN = re.compile(r'\s+|//[^\n]*|"((?:[^"\\]|\\.)*)"|([{}])|([^\s{}"]+)', re.S)
_ESCAPES = {"n": "\n", "t": "\t", "\\": "\\", '"': '"'}


def _tokens(text):
    pos = 0
    while pos < len(text):
        m = _TOKEN.match(text, pos)
        if not m:
            raise CanaryError(f"manifest: unreadable text at offset {pos}")
        pos = m.end()
        if m.group(1) is not None:
            yield "str", re.sub(r"\\(.)", lambda e: _ESCAPES.get(e.group(1), e.group(0)),
                                m.group(1))
        elif m.group(2):
            yield m.group(2), None
        elif m.group(3):
            yield "str", m.group(3)


def parse_kv(text):
    """Nested dicts. A repeated key keeps its first value, as Steam's reader does."""
    root, stack, key = {}, [], None
    cur = root
    for kind, val in _tokens(text):
        if kind == "str":
            if key is None:
                key = val
            else:
                cur.setdefault(key, val)
                key = None
        elif kind == "{":
            if key is None:
                raise CanaryError("manifest: block without a name")
            child = {}
            if not isinstance(cur.setdefault(key, child), dict):
                raise CanaryError(f"manifest: '{key}' is both a value and a block")
            stack.append(cur)
            cur, key = cur[key], None
        else:
            if key is not None or not stack:
                raise CanaryError("manifest: unbalanced braces")
            cur = stack.pop()
    if stack or key is not None:
        raise CanaryError("manifest: truncated")
    return root


def parse_manifest(text):
    """{"version": int, "packages": {name: {"file", "size", "sha2"}}} for the osx client.
    A package's sub-blocks (steamchina, macos-signed-2) are variants; the plain one is used."""
    osx = parse_kv(text).get("osx")
    if not isinstance(osx, dict):
        raise CanaryError("manifest: no osx block")
    version = osx.get("version")
    if not isinstance(version, str) or not version.isdigit() or int(version) == 0:
        raise CanaryError(f"manifest: bad version {version!r}")
    packages = {}
    for name, block in osx.items():
        if not isinstance(block, dict):
            continue
        file, size, sha2 = block.get("file"), block.get("size"), block.get("sha2")
        if not all(isinstance(v, str) for v in (file, size, sha2)):
            continue
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", file) or file.startswith("."):
            raise CanaryError(f"manifest: unsafe file name for {name}: {file!r}")
        if not size.isdigit() or not re.fullmatch(r"[0-9a-f]{64}", sha2.lower()):
            raise CanaryError(f"manifest: bad size or sha2 for {name}")
        packages[name] = {"file": file, "size": int(size), "sha2": sha2.lower()}
    return {"version": int(version), "packages": packages}


# --- state -----------------------------------------------------------------------------

def fingerprint(repo):
    h = hashlib.sha256()
    for rel in FINGERPRINT_PATHS:
        top = os.path.join(repo, rel)
        if os.path.isfile(top):
            files = [top]
        elif os.path.isdir(top):
            files = sorted(os.path.join(d, f) for d, _, fs in os.walk(top) for f in fs)
        else:
            raise CanaryError(f"fingerprint: {rel} missing")
        for path in files:
            h.update(os.path.relpath(path, repo).encode() + b"\0")
            with open(path, "rb") as fh:
                h.update(hashlib.sha256(fh.read()).digest())
    return h.hexdigest()[:16]


def load_state(path):
    """A missing or unreadable state file means nothing was seen: every channel is checked."""
    try:
        with open(path, encoding="utf-8") as fh:
            state = json.load(fh)
    except (OSError, ValueError):
        return {}
    if not isinstance(state, dict):
        return {}
    return {k: v for k, v in state.items() if k in CHANNELS and isinstance(v, dict)}


def needs_check(state, channel, version, fp):
    seen = state.get(channel) or {}
    return seen.get("version") != version or seen.get("fingerprint") != fp


def write_json(path, obj):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)


# --- downloads -------------------------------------------------------------------------

def fetch_bytes(url, limit):
    req = urllib.request.Request(url, headers={"User-Agent": "bridgeplay-steam-canary"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            data = resp.read(limit + 1)
    except OSError as e:
        raise CanaryError(f"download failed: {url}: {e}") from e
    if len(data) > limit:
        raise CanaryError(f"download too large: {url}")
    return data


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch_package(base_url, pkg, cache):
    """The verified zip in `cache`, downloaded only when no verified copy is there."""
    os.makedirs(cache, exist_ok=True)
    dest = os.path.join(cache, pkg["file"])
    if os.path.isfile(dest) and os.path.getsize(dest) == pkg["size"] \
            and sha256_file(dest) == pkg["sha2"]:
        return dest
    if pkg["size"] > MAX_PACKAGE:
        raise CanaryError(f"{pkg['file']}: {pkg['size']} bytes is more than the limit")
    url = base_url + pkg["file"]
    fd, tmp = tempfile.mkstemp(dir=cache, prefix=".part-")
    try:
        h, n = hashlib.sha256(), 0
        req = urllib.request.Request(url, headers={"User-Agent": "bridgeplay-steam-canary"})
        with os.fdopen(fd, "wb") as out, urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            for chunk in iter(lambda: resp.read(1 << 20), b""):
                n += len(chunk)
                if n > pkg["size"]:
                    raise CanaryError(f"{pkg['file']}: larger than the manifest says")
                h.update(chunk)
                out.write(chunk)
        if n != pkg["size"] or h.hexdigest() != pkg["sha2"]:
            raise CanaryError(f"{pkg['file']}: size or sha2 differs from the manifest")
        os.replace(tmp, dest)
        return dest
    except OSError as e:
        raise CanaryError(f"download failed: {url}: {e}") from e
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def unpack(zip_path, dest):
    """Extracts into dest, refusing absolute paths, '..' and links. Keeps the exec bit."""
    root = os.path.realpath(dest)
    with zipfile.ZipFile(zip_path) as zf:
        for info in zf.infolist():
            name = info.filename
            parts = name.replace("\\", "/").split("/")
            if name.startswith("/") or ".." in parts or ":" in parts[0]:
                raise CanaryError(f"{os.path.basename(zip_path)}: unsafe member {name!r}")
            mode = info.external_attr >> 16
            if (mode & 0o170000) == 0o120000:
                # Frameworks use Versions/Current links; recreate them only inside dest.
                target = zf.read(info).decode()
                link = os.path.join(root, *parts)
                resolved = os.path.realpath(os.path.join(os.path.dirname(link), target))
                if os.path.isabs(target) or not resolved.startswith(root + os.sep):
                    raise CanaryError(f"{os.path.basename(zip_path)}: link leaves the folder: {name!r}")
                os.makedirs(os.path.dirname(link), exist_ok=True)
                if os.path.lexists(link):
                    os.unlink(link)
                os.symlink(target, link)
                continue
            out = os.path.join(root, *parts)
            if not os.path.realpath(out).startswith(root + os.sep):
                raise CanaryError(f"{os.path.basename(zip_path)}: member leaves the folder: {name!r}")
            if info.is_dir():
                os.makedirs(out, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with zf.open(info) as src, open(out, "wb") as dst:
                shutil.copyfileobj(src, dst)
            os.chmod(out, 0o755 if mode & 0o111 else 0o644)


def newest_sigdb(repo):
    """The file the dylib loads: the highest numeric name (dylib/core/loader.c)."""
    d = os.path.join(repo, "signatures", "macos.arm64")
    builds = [int(f[:-5]) for f in os.listdir(d) if re.fullmatch(r"[0-9]+\.json", f)]
    if not builds:
        raise CanaryError("no signature databases")
    return os.path.join(d, f"{max(builds)}.json")


# --- commands --------------------------------------------------------------------------

def cmd_parse(args):
    with open(args.manifest, encoding="utf-8") as fh:
        print(json.dumps(parse_manifest(fh.read()), indent=2, sort_keys=True))
    return 0


def cmd_poll(args):
    state = load_state(args.state)
    fp = fingerprint(args.repo)
    os.makedirs(args.manifests, exist_ok=True)
    due = []
    for channel in args.channel or list(CHANNELS):
        if args.offline:
            with open(os.path.join(args.manifests, f"{channel}.manifest"), "rb") as fh:
                raw = fh.read()
        else:
            raw = fetch_bytes(args.base_url + CHANNELS[channel], MAX_MANIFEST)
            with open(os.path.join(args.manifests, f"{channel}.manifest"), "wb") as fh:
                fh.write(raw)
        version = parse_manifest(raw.decode("utf-8"))["version"]
        seen = (state.get(channel) or {}).get("version")
        if needs_check(state, channel, version, fp):
            due.append(channel)
        print(f"{channel}: build {version} (last checked {seen or 'none'})"
              f"{' -> check' if channel in due else ''}", file=sys.stderr)
    print(" ".join(due))
    return 0


def cmd_check(args):
    with open(args.manifest, encoding="utf-8") as fh:
        man = parse_manifest(fh.read())
    missing = [p for p in PACKAGES if p not in man["packages"]]
    args.work = os.path.abspath(args.work)
    os.makedirs(args.work, exist_ok=True)
    client = os.path.join(args.work, f"client-{args.channel}")
    result = {"channel": args.channel, "build": man["version"],
              "fingerprint": fingerprint(args.repo)}
    log_path = os.path.join(args.work, f"{args.channel}.log")
    if missing:
        # A package Valve dropped or renamed is a layout change worth reading about.
        result.update(verdict="layout", detail="missing packages: " + ", ".join(missing))
        with open(log_path, "w", encoding="utf-8") as fh:
            fh.write(result["detail"] + "\n")
        write_json(os.path.join(args.work, f"{args.channel}.json"), result)
        return 0
    shutil.rmtree(client, ignore_errors=True)
    os.makedirs(client)
    for name in PACKAGES:
        unpack(fetch_package(args.base_url, man["packages"][name], args.cache), client)

    sigdb = args.sigdb or newest_sigdb(args.repo)
    env = dict(os.environ)
    # steamclient's initialisers run in anchorcheck; keep them out of a real Steam folder.
    home = tempfile.mkdtemp(prefix="steam-canary-home-")
    env["HOME"] = home
    try:
        proc = subprocess.run([os.path.abspath(args.anchorcheck), "--client-dir", client,
                               "--build", str(man["version"]), os.path.abspath(sigdb)],
                              cwd=args.repo, env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=600, check=False)
    finally:
        shutil.rmtree(home, ignore_errors=True)
    out = proc.stdout.decode("utf-8", "replace")
    with open(log_path, "w", encoding="utf-8") as fh:
        fh.write(out)
    # anchorcheck: 0 pass, 1 anchors fail, 2 database unreadable, 3 client would not load.
    verdict = {0: "pass", 1: "anchors", 2: "sigdb", 3: "load"}.get(proc.returncode, "crash")
    failing = [ln.strip() for ln in out.splitlines()
               if re.search(r"ANCHOR FAILED|NO ANCHOR|WRONG|UNRESOLVED|DISAGREES|DID NOT RESOLVE", ln)]
    result.update(verdict=verdict, rc=proc.returncode, sigdb=os.path.basename(sigdb),
                  failing=failing[:40],
                  detail=out.strip().splitlines()[-1] if out.strip() else "")
    write_json(os.path.join(args.work, f"{args.channel}.json"), result)
    print(f"{args.channel}: build {man['version']}: {verdict}", file=sys.stderr)
    return 0


def cmd_record(args):
    """Stores every result that ran, pass or fail, so a failure opens one issue, not one an hour."""
    state = load_state(args.state)
    for channel in CHANNELS:
        path = os.path.join(args.results, f"{channel}.json")
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as fh:
            res = json.load(fh)
        if res.get("channel") != channel or not isinstance(res.get("build"), int):
            raise CanaryError(f"{path}: not a result for {channel}")
        state[channel] = {"version": res["build"], "fingerprint": res.get("fingerprint"),
                          "verdict": res.get("verdict")}
    write_json(args.state, state)
    return 0


VERDICTS = {
    "pass": "every anchor resolves",
    "anchors": "anchors do not resolve",
    "sigdb": "the signature file was rejected",
    "load": "anchorcheck could not load the client",
    "crash": "anchorcheck crashed",
    "layout": "a package the check needs is gone",
}


def cmd_report(args):
    results = []
    for channel in CHANNELS:
        path = os.path.join(args.results, f"{channel}.json")
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as fh:
                results.append(json.load(fh))
    if not results:
        print("none")
        return 0
    checked = {r["channel"] for r in results}
    earlier = [{"channel": c, "build": v.get("version"), "verdict": v.get("verdict"), "earlier": True}
               for c, v in load_state(args.state).items() if c not in checked] if args.state else []
    failed = [r for r in results if r.get("verdict") != "pass"]
    lines = ["| Channel | Steam build | Signatures | Result |", "|---|---|---|---|"]
    for r in results + earlier:
        when = " (earlier run)" if r.get("earlier") else ""
        lines.append(f"| {r['channel']} | {r['build']} | {r.get('sigdb', '')} | "
                     f"{VERDICTS.get(r.get('verdict'), r.get('verdict'))}{when} |")
    for r in failed:
        lines += ["", f"### {r['channel']} {r['build']}", "", "```"]
        lines += (r.get("failing") or [r.get("detail", "")])[:40]
        lines += ["```"]
    if failed:
        lines += ["", "The canary checks only what anchorcheck can see in Valve's packages: it "
                  "does not start Steam, so it cannot see sign-in order or appinfo changes."]
    if args.run_url:
        lines += ["", f"Run and full logs: {args.run_url}"]
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    still = any(r.get("verdict") != "pass" for r in earlier)
    print("fail" if failed else "pass" if not still else "none")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--base-url", default=BASE_URL)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("parse")
    p.add_argument("manifest")
    p.set_defaults(fn=cmd_parse)

    p = sub.add_parser("poll")
    p.add_argument("--state", required=True)
    p.add_argument("--manifests", required=True)
    p.add_argument("--channel", action="append", choices=list(CHANNELS))
    p.add_argument("--offline", action="store_true", help="read the manifests already in --manifests")
    p.set_defaults(fn=cmd_poll)

    p = sub.add_parser("check")
    p.add_argument("--channel", required=True, choices=list(CHANNELS))
    p.add_argument("--manifest", required=True)
    p.add_argument("--cache", required=True)
    p.add_argument("--work", required=True)
    p.add_argument("--anchorcheck", required=True)
    p.add_argument("--sigdb", help="default: the newest, as the dylib picks it")
    p.set_defaults(fn=cmd_check)

    p = sub.add_parser("record")
    p.add_argument("--state", required=True)
    p.add_argument("--results", required=True)
    p.set_defaults(fn=cmd_record)

    p = sub.add_parser("report")
    p.add_argument("--results", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--state")
    p.add_argument("--run-url")
    p.set_defaults(fn=cmd_report)

    args = ap.parse_args(argv)
    if not args.base_url.endswith("/"):
        args.base_url += "/"
    try:
        return args.fn(args)
    except (CanaryError, zipfile.BadZipFile, OSError) as e:
        print(f"steam-canary: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
