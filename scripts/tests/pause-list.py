#!/usr/bin/env python3
"""scripts/pause-list.py: the source checks, then a list signed with a throwaway key made
here by OpenSSL and verified by the dylib's own code (pauselistcheck --verify, argv[1]).
No real key is read or made. Without OpenSSL 3 the signing part prints skipped."""

import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(ROOT, "scripts", "pause-list.py")
sys.path.insert(0, os.path.join(ROOT, "scripts"))
pause_list = __import__("pause-list")

fails = 0


def check(what, cond):
    global fails
    print(f"  {'ok  ' if cond else 'FAIL'}  {what}")
    fails += not cond


def run(*args, env=None):
    full = {k: v for k, v in os.environ.items() if k != "BRIDGEPLAY_PAUSE_LIST_KEY"}
    full.update(env or {})
    return subprocess.run([sys.executable, "-I", SCRIPT, *args], capture_output=True, text=True,
                          env=full, timeout=60)


def write(path, doc):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f)


def main():
    verifier = sys.argv[1] if len(sys.argv) > 1 else None
    with tempfile.TemporaryDirectory() as work:
        print("source")
        check("the repository's list passes", run("check").returncode == 0)
        bad = {
            "an unknown key": {"steam_build": 1, "surprise": 1},
            "no selector": {"note": "x"},
            "a build and a range": {"steam_build": 1, "steam_build_min": 1},
            "an empty range": {"steam_build_min": 9, "steam_build_max": 8},
            "a plain-http url": {"steam_build": 1, "url": "http://example.invalid/"},
            "a two-line note": {"steam_build": 1, "note": "a\nb"},
            "a true build": {"steam_build": True},
        }
        for what, entry in bad.items():
            path = os.path.join(work, "bad.json")
            write(path, {"days": 14, "entries": [entry]})
            check(f"{what} is refused", run("check", path).returncode == 1)
        path = os.path.join(work, "long.json")
        write(path, {"days": 40, "entries": []})
        check("a lifetime over 31 days is refused", run("check", path).returncode == 1)

        tool = pause_list.find_openssl()
        if not tool:
            print("==> pause-list: signing skipped (no OpenSSL 3 or later)")
            return 1 if fails else 0

        print("signing")
        key = os.path.join(work, "throwaway.pem")
        other = os.path.join(work, "other.pem")
        for path in (key, other):
            subprocess.run([tool, "genpkey", "-algorithm", "ed25519", "-out", path], check=True,
                           capture_output=True)
        pub = run("public-key", "--key-file", key).stdout.strip()
        check("public-key prints 32 bytes of base64", len(pub) == 44 and pub.endswith("="))

        source = os.path.join(work, "source.json")
        write(source, {"days": 14, "entries": [
            {"steam_build": 1795567705, "channel": "publicbeta", "patch_build_max": 90,
             "note": "Steam beta 1795567705 closes at start.", "fixed_in": "0.7.70",
             "url": "https://github.com/raymondchins/Bridgeplay/issues/1"}]})
        out = os.path.join(work, "out")
        now = 1800000000
        r = run("sign", source, out, "--key-file", key, "--expect-key", pub, "--now", str(now))
        check("sign writes the pair", r.returncode == 0 and os.path.isfile(os.path.join(out, "pause-list.json.sig")))
        data_path = os.path.join(out, "pause-list.json")
        sig_path = os.path.join(out, "pause-list.json.sig")
        with open(data_path, "rb") as f:
            doc = json.loads(f.read())
        check("the serial is the signing time and the list lasts 14 days",
              doc["serial"] == now and doc["expires"] == now + 14 * 86400 and doc["version"] == 1)
        check("verify accepts it", run("verify", data_path, sig_path, "--public-key", pub,
                                       "--now", str(now)).returncode == 0)

        if verifier:
            def dylib(json_path=data_path, sig=sig_path, key_b64=pub, at=now):
                return subprocess.run([verifier, "--verify", key_b64, json_path, sig, str(at)],
                                      capture_output=True, text=True, timeout=30).stdout.split()
            check("the dylib's code accepts what the script signed", dylib() == ["ok", str(now), "1"])
            check("and calls it expired after 14 days", dylib(at=now + 15 * 86400)[0] == "expired")
            other_pub = run("public-key", "--key-file", other).stdout.strip()
            check("and refuses it under another key", dylib(key_b64=other_pub)[0] == "invalid")
            with open(data_path, "rb") as f:
                raw = bytearray(f.read())
            raw[raw.index(b"0.7.70")] = ord("9")
            tampered = os.path.join(work, "tampered.json")
            with open(tampered, "wb") as f:
                f.write(raw)
            check("and refuses a changed byte", dylib(json_path=tampered)[0] == "invalid")
        else:
            print("  skipped  the dylib cross-check (no pauselistcheck binary given)")

        previous = os.path.join(work, "previous.json")
        write(previous, {"serial": now + 500})
        r = run("sign", source, out, "--key-file", key, "--expect-key", pub, "--now", str(now),
                "--previous", previous)
        with open(data_path, "rb") as f:
            check("the serial never goes below the published one",
                  r.returncode == 0 and json.loads(f.read())["serial"] == now + 501)

        with open(key, encoding="utf-8") as f:
            pem = f.read()
        r = run("sign", source, os.path.join(work, "env"), "--expect-key", pub,
                env={"BRIDGEPLAY_PAUSE_LIST_KEY": pem})
        check("the key can come from BRIDGEPLAY_PAUSE_LIST_KEY", r.returncode == 0)
        r = run("sign", source, os.path.join(work, "wrong"), "--key-file", other, "--expect-key", pub)
        check("a key that isn't the dylib's signs nothing",
              r.returncode == 1 and not os.path.exists(os.path.join(work, "wrong", "pause-list.json")))
        r = run("sign", source, os.path.join(work, "nokey"), "--expect-key", pub)
        check("no key signs nothing", r.returncode == 1)

    if fails:
        print(f"==> pause-list: {fails} failed")
        return 1
    print("==> pause-list: the script checks, signs and the dylib accepts its output")
    return 0


if __name__ == "__main__":
    sys.exit(main())
