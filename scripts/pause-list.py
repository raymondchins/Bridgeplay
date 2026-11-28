#!/usr/bin/env python3
"""The signed pause list (pause-list/README.md): checks the source list, signs it with the
Ed25519 key, and verifies a signed copy the way the dylib does. .github/workflows/pause-list.yml
calls it; it runs the same way on a Mac with OpenSSL 3 or later (LibreSSL lacks Ed25519).

  pause-list.py check  [SOURCE]
  pause-list.py sign   SOURCE OUT_DIR [--previous FILE] [--key-file PEM] [--expect-key B64] [--now T]
  pause-list.py verify JSON SIG [--public-key B64] [--now T]
  pause-list.py public-key --key-file PEM

sign reads the private key (PEM) from --key-file or the BRIDGEPLAY_PAUSE_LIST_KEY variable,
refuses a key whose public half is not the one built into the dylib
(dylib/feats/pauselist_key.h, or --expect-key), and writes OUT_DIR/pause-list.json and
pause-list.json.sig ("<base64 signature> <length>"). The serial is the signing time, or one
above --previous (the list published now), whichever is higher, so it never goes back.
"""

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "pause-list", "pause-list.json")
KEY_HEADER = os.path.join(ROOT, "dylib", "feats", "pauselist_key.h")

# The dylib's limits (dylib/feats/pauselist.h).
MAX_ENTRIES = 32
MAX_BYTES = 65536
MAX_DAYS = 31
MAX_NUMBER = 2**53 - 1
INT_MAX = 2**31 - 1
ENTRY_KEYS = {"steam_build", "steam_build_min", "steam_build_max", "channel",
              "patch_build_max", "note", "fixed_in", "url"}
CHANNEL = re.compile(r"[A-Za-z0-9_.-]{1,63}")
FIXED_IN = re.compile(r"[A-Za-z0-9.+-]{1,31}")
URL_BAD = set("\"'<>\\`")
ED25519_DER_PREFIX = bytes.fromhex("302a300506032b6570032100")


class ListError(Exception):
    pass


def whole(value, limit, what):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0 or value > limit:
        raise ListError(f"{what} must be a whole number from 0 to {limit}")
    return value


def check_entry(i, entry):
    where = f"entry {i + 1}"
    if not isinstance(entry, dict):
        raise ListError(f"{where} is not an object")
    unknown = set(entry) - ENTRY_KEYS
    if unknown:
        raise ListError(f"{where}: unknown keys {sorted(unknown)} (the dylib would skip it)")
    for key in ("steam_build", "steam_build_min", "steam_build_max"):
        if key in entry and whole(entry[key], MAX_NUMBER, f"{where}: {key}") == 0:
            raise ListError(f"{where}: {key} must be above 0")
    if "steam_build" in entry and ("steam_build_min" in entry or "steam_build_max" in entry):
        raise ListError(f"{where}: give steam_build or a range, not both")
    if "steam_build_min" in entry and "steam_build_max" in entry \
            and entry["steam_build_min"] > entry["steam_build_max"]:
        raise ListError(f"{where}: steam_build_min is above steam_build_max")
    if not ({"steam_build", "steam_build_min", "steam_build_max", "channel"} & set(entry)):
        raise ListError(f"{where}: needs a Steam build, a range or a channel")
    if "channel" in entry and not (isinstance(entry["channel"], str)
                                   and CHANNEL.fullmatch(entry["channel"])):
        raise ListError(f"{where}: channel must be letters, digits, '_', '-' or '.'")
    if "patch_build_max" in entry:
        whole(entry["patch_build_max"], INT_MAX, f"{where}: patch_build_max")
    if "note" in entry:
        note = entry["note"]
        if not isinstance(note, str) or len(note.encode()) > 255 \
                or any(ord(c) < 0x20 or ord(c) == 0x7f for c in note):
            raise ListError(f"{where}: note must be one line of at most 255 bytes")
    if "fixed_in" in entry and not (isinstance(entry["fixed_in"], str)
                                    and FIXED_IN.fullmatch(entry["fixed_in"])):
        raise ListError(f"{where}: fixed_in must be a version such as 0.7.70")
    if "url" in entry:
        url = entry["url"]
        if not isinstance(url, str) or not url.startswith("https://") or len(url) > 255 \
                or any(ord(c) <= 0x20 or ord(c) >= 0x7f or c in URL_BAD for c in url):
            raise ListError(f"{where}: url must be an https address of at most 255 characters")


def load_source(path):
    try:
        with open(path, encoding="utf-8") as f:
            source = json.load(f)
    except (OSError, ValueError) as e:
        raise ListError(f"{path}: {e}") from e
    if not isinstance(source, dict) or set(source) - {"days", "entries", "comment"}:
        raise ListError(f"{path}: expected an object with days, entries and an optional comment")
    days = source.get("days", 14)
    if isinstance(days, bool) or not isinstance(days, int) or not 1 <= days <= MAX_DAYS:
        raise ListError(f"{path}: days must be 1 to {MAX_DAYS}")
    entries = source.get("entries")
    if not isinstance(entries, list) or len(entries) > MAX_ENTRIES:
        raise ListError(f"{path}: entries must be a list of at most {MAX_ENTRIES}")
    for i, entry in enumerate(entries):
        check_entry(i, entry)
    return days, entries


def payload(days, entries, now, previous_serial):
    serial = max(now, previous_serial + 1)
    doc = {"version": 1, "serial": serial, "issued": now, "expires": now + days * 86400,
           "entries": entries}
    data = (json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
    if len(data) > MAX_BYTES:
        raise ListError(f"the signed list would be {len(data)} bytes, over {MAX_BYTES}")
    return serial, data


def find_openssl():
    candidates = [os.environ.get("OPENSSL"), shutil.which("openssl"),
                  "/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl"]
    for path in candidates:
        if not path or not os.path.isfile(path):
            continue
        try:
            out = subprocess.run([path, "version"], capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        m = re.match(r"OpenSSL (\d+)\.", out)
        if m and int(m.group(1)) >= 3:
            return path
    return None


def openssl(*args, data=None):
    tool = find_openssl()
    if not tool:
        raise ListError("needs OpenSSL 3 or later (brew install openssl@3, or set OPENSSL)")
    run = subprocess.run([tool, *args], input=data, capture_output=True, timeout=30)
    if run.returncode != 0:
        raise ListError(f"openssl {args[0]} failed: {run.stderr.decode(errors='replace').strip()}")
    return run.stdout


def public_key_of(key_file):
    der = openssl("pkey", "-in", key_file, "-pubout", "-outform", "DER")
    if len(der) != 44 or not der.startswith(ED25519_DER_PREFIX):
        raise ListError("the key is not an Ed25519 key")
    return base64.b64encode(der[-32:]).decode()


def built_in_key():
    with open(KEY_HEADER, encoding="utf-8") as f:
        m = re.search(r'#define NP_PAUSE_LIST_PUBLIC_KEY "([^"]*)"', f.read())
    if not m or not m.group(1):
        raise ListError(f"no public key in {os.path.relpath(KEY_HEADER, ROOT)} yet "
                        "(pause-list/README.md, Making the key)")
    return m.group(1)


def raw_key(b64):
    try:
        key = base64.b64decode(b64, validate=True)
    except ValueError as e:
        raise ListError(f"public key: {e}") from e
    if len(key) != 32:
        raise ListError("public key: not 32 bytes")
    return key


def parse_sig(text):
    parts = text.split()
    if len(parts) != 2 or not parts[1].isdigit():
        raise ListError("signature file: expected '<base64 signature> <length>'")
    sig = base64.b64decode(parts[0], validate=True)
    if len(sig) != 64:
        raise ListError("signature file: not a 64-byte signature")
    return sig, int(parts[1])


def verify(data, sig_text, key_b64, now):
    sig, length = parse_sig(sig_text)
    if length != len(data):
        raise ListError(f"signature file says {length} bytes, the list has {len(data)}")
    with tempfile.TemporaryDirectory() as tmp:
        pub = os.path.join(tmp, "pub.der")
        msg = os.path.join(tmp, "list")
        sig_file = os.path.join(tmp, "sig")
        for path, content in ((pub, ED25519_DER_PREFIX + raw_key(key_b64)), (msg, data), (sig_file, sig)):
            with open(path, "wb") as f:
                f.write(content)
        openssl("pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", pub, "-rawin",
                "-in", msg, "-sigfile", sig_file)
    try:
        doc = json.loads(data)
        if doc.get("version") != 1:
            raise ListError("not a version 1 list")
        if not 0 <= doc["expires"] - doc["issued"] <= MAX_DAYS * 86400:
            raise ListError("lifetime out of range")
        for i, entry in enumerate(doc["entries"]):
            check_entry(i, entry)
        return doc, now > doc["expires"]
    except (KeyError, TypeError, ValueError, AttributeError) as e:
        raise ListError(f"not a pause list: {e}") from e


def cmd_check(args):
    days, entries = load_source(args.source)
    print(f"{os.path.relpath(args.source)}: {len(entries)} entries, signed copies last {days} days")


def cmd_sign(args):
    days, entries = load_source(args.source)
    previous = 0
    if args.previous:
        try:
            with open(args.previous, encoding="utf-8") as f:
                previous = whole(json.load(f).get("serial", 0), MAX_NUMBER, "previous serial")
        except (OSError, ValueError, AttributeError, ListError) as e:
            raise ListError(f"--previous {args.previous}: {e}") from e
    expected = args.expect_key or built_in_key()
    now = args.now if args.now is not None else int(time.time())
    serial, data = payload(days, entries, now, previous)

    with tempfile.TemporaryDirectory() as tmp:
        key_file = args.key_file
        if not key_file:
            pem = os.environ.get("BRIDGEPLAY_PAUSE_LIST_KEY", "")
            if not pem.strip():
                raise ListError("no key: pass --key-file or set BRIDGEPLAY_PAUSE_LIST_KEY")
            key_file = os.path.join(tmp, "key.pem")
            fd = os.open(key_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(pem if pem.endswith("\n") else pem + "\n")
        if public_key_of(key_file) != expected:
            raise ListError("this key is not the one built into the dylib; nothing signed")
        msg = os.path.join(tmp, "list")
        with open(msg, "wb") as f:
            f.write(data)
        sig = openssl("pkeyutl", "-sign", "-inkey", key_file, "-rawin", "-in", msg)
    if len(sig) != 64:
        raise ListError("openssl gave no Ed25519 signature")

    os.makedirs(args.out_dir, exist_ok=True)
    sig_text = f"{base64.b64encode(sig).decode()} {len(data)}\n"
    verify(data, sig_text, expected, now)
    with open(os.path.join(args.out_dir, "pause-list.json"), "wb") as f:
        f.write(data)
    with open(os.path.join(args.out_dir, "pause-list.json.sig"), "w", encoding="utf-8") as f:
        f.write(sig_text)
    print(f"signed serial {serial}: {len(entries)} entries, expires in {days} days")


def cmd_verify(args):
    with open(args.json, "rb") as f:
        data = f.read()
    with open(args.sig, encoding="utf-8") as f:
        sig_text = f.read()
    now = args.now if args.now is not None else int(time.time())
    doc, expired = verify(data, sig_text, args.public_key or built_in_key(), now)
    print(f"{'expired' if expired else 'ok'}: serial {doc['serial']}, {len(doc['entries'])} entries")


def cmd_public_key(args):
    print(public_key_of(args.key_file))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("check")
    p.add_argument("source", nargs="?", default=SOURCE)
    p.set_defaults(run=cmd_check)
    p = sub.add_parser("sign")
    p.add_argument("source")
    p.add_argument("out_dir")
    p.add_argument("--previous")
    p.add_argument("--key-file")
    p.add_argument("--expect-key")
    p.add_argument("--now", type=int)
    p.set_defaults(run=cmd_sign)
    p = sub.add_parser("verify")
    p.add_argument("json")
    p.add_argument("sig")
    p.add_argument("--public-key")
    p.add_argument("--now", type=int)
    p.set_defaults(run=cmd_verify)
    p = sub.add_parser("public-key")
    p.add_argument("--key-file", required=True)
    p.set_defaults(run=cmd_public_key)
    args = parser.parse_args()
    try:
        args.run(args)
    except ListError as e:
        print(f"pause-list: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
