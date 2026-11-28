#!/usr/bin/env python3
"""Offline tests for scripts/steam-canary.py: manifest parsing, the seen-build state,
download verification and unpacking. Packages are served from file:// URLs and anchorcheck
is a stub, so no network, no Steam and no real client are needed."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import stat
import tempfile
import unittest
import warnings
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURES = os.path.join(ROOT, "scripts", "tests", "fixtures", "steam-canary")

spec = importlib.util.spec_from_file_location("canary", os.path.join(ROOT, "scripts", "steam-canary.py"))
canary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(canary)


def fake_repo(top):
    for rel, body in [("signatures/macos.arm64/100.json", "{}"),
                      ("signatures/macos.arm64/99.json", "{}"),
                      ("dylib/tests/anchorcheck.c", "int main;"),
                      ("dylib/resolver/anchor.c", ""),
                      ("dylib/core/macho.c", ""),
                      ("dylib/core/macho.h", "")]:
        path = os.path.join(top, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
    return top


def make_zip(path, members):
    """members: name -> bytes, or ("link", target)."""
    with zipfile.ZipFile(path, "w") as zf:
        for name, body in members.items():
            info = zipfile.ZipInfo(name)
            if isinstance(body, tuple):
                info.external_attr = (stat.S_IFLNK | 0o755) << 16
                zf.writestr(info, body[1])
            else:
                info.external_attr = (stat.S_IFREG | 0o755) << 16
                zf.writestr(info, body)


def manifest_for(version, server, names):
    """A manifest whose packages are zips in `server`, one small dylib each."""
    lines = ['"osx"', "{", f'\t"version"\t\t"{version}"']
    for name in names:
        file = f"{name}.zip.{version}"
        make_zip(os.path.join(server, file), {f"{name}.dylib": name.encode()})
        with open(os.path.join(server, file), "rb") as fh:
            data = fh.read()
        lines += [f'\t"{name}"', "\t{", f'\t\t"file"\t\t"{file}"', f'\t\t"size"\t\t"{len(data)}"',
                  f'\t\t"sha2"\t\t"{hashlib.sha256(data).hexdigest()}"', "\t}"]
    return "\n".join(lines + ["}", ""])


def run(*argv):
    err = io.StringIO()
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = canary.main(list(argv))
    return rc, out.getvalue(), err.getvalue()


class Manifest(unittest.TestCase):
    def test_real_manifest(self):
        with open(os.path.join(FIXTURES, "beta.manifest"), encoding="utf-8") as fh:
            m = canary.parse_manifest(fh.read())
        self.assertEqual(m["version"], 1795567705)
        self.assertEqual(sorted(m["packages"]), ["bins_client_osx", "bins_osx", "steam_osx"])
        self.assertEqual(m["packages"]["bins_client_osx"]["size"], 19091390)
        # The plain package, not its steamchina or macos-signed-2 variant.
        self.assertTrue(m["packages"]["steam_osx"]["file"].startswith("steam_osx.zip."))

    def test_syntax(self):
        text = '// c\n"osx" { "version" "7" // tail\n "p" { "file" "a.zip" "size" "1" ' \
               '"sha2" "' + "A" * 64 + '" } "version" "8" "q\\"x" "y" }'
        m = canary.parse_manifest(text)
        self.assertEqual(m["version"], 7, "a repeated key keeps its first value")
        self.assertEqual(m["packages"]["p"]["sha2"], "a" * 64)

    def test_rejected(self):
        good = '"sha2" "' + "a" * 64 + '"'
        for text in ['"osx" { "version" "1"',                       # truncated
                     '"osx" { "version" "1" } }',                    # unbalanced
                     '"other" { "version" "1" }',                    # no osx block
                     '"osx" { "version" "x1" }',                     # bad version
                     '"osx" { "version" "0" }',
                     '"osx" { "version" "1" "p" { "file" "../a" "size" "1" ' + good + ' } }',
                     '"osx" { "version" "1" "p" { "file" ".a" "size" "1" ' + good + ' } }',
                     '"osx" { "version" "1" "p" { "file" "a" "size" "-1" ' + good + ' } }',
                     '"osx" { "version" "1" "p" { "file" "a" "size" "1" "sha2" "ab" } }',
                     '"osx" { "version" "1" "v" "x" "v" { } }']:
            with self.assertRaises(canary.CanaryError, msg=text):
                canary.parse_manifest(text)


class State(unittest.TestCase):
    def test_load(self):
        with tempfile.TemporaryDirectory() as t:
            path = os.path.join(t, "state.json")
            self.assertEqual(canary.load_state(path), {}, "missing")
            for bad in ["", "[1]", "{", '"x"']:
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(bad)
                self.assertEqual(canary.load_state(path), {}, bad)
            with open(path, "w", encoding="utf-8") as fh:
                json.dump({"beta": {"version": 5}, "alpha": {"version": 1}, "stable": 3}, fh)
            self.assertEqual(canary.load_state(path), {"beta": {"version": 5}})

    def test_needs_check(self):
        st = {"beta": {"version": 5, "fingerprint": "f"}}
        self.assertFalse(canary.needs_check(st, "beta", 5, "f"))
        self.assertTrue(canary.needs_check(st, "beta", 6, "f"), "new build")
        self.assertTrue(canary.needs_check(st, "beta", 4, "f"), "rolled back")
        self.assertTrue(canary.needs_check(st, "beta", 5, "g"), "new signatures")
        self.assertTrue(canary.needs_check(st, "stable", 5, "f"), "never seen")

    def test_fingerprint(self):
        with tempfile.TemporaryDirectory() as t:
            repo = fake_repo(t)
            a = canary.fingerprint(repo)
            self.assertEqual(a, canary.fingerprint(repo))
            with open(os.path.join(repo, "signatures/macos.arm64/101.json"), "w", encoding="utf-8") as fh:
                fh.write("{}")
            self.assertNotEqual(a, canary.fingerprint(repo))
            os.remove(os.path.join(repo, "dylib/core/macho.h"))
            with self.assertRaises(canary.CanaryError):
                canary.fingerprint(repo)

    def test_newest_sigdb(self):
        with tempfile.TemporaryDirectory() as t:
            repo = fake_repo(t)
            open(os.path.join(repo, "signatures/macos.arm64/1000.bak.json"), "w").close()
            self.assertEqual(os.path.basename(canary.newest_sigdb(repo)), "100.json")


class Downloads(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory()
        self.t = self._t.name
        self.server = os.path.join(self.t, "server")
        os.makedirs(self.server)
        self.base = "file://" + self.server + "/"

    def tearDown(self):
        self._t.cleanup()

    def pkg(self, members):
        path = os.path.join(self.server, "p.zip.1")
        make_zip(path, members)
        with open(path, "rb") as fh:
            data = fh.read()
        return {"file": "p.zip.1", "size": len(data), "sha2": hashlib.sha256(data).hexdigest()}

    def test_verified_and_cached(self):
        pkg = self.pkg({"a.dylib": b"x"})
        cache = os.path.join(self.t, "cache")
        got = canary.fetch_package(self.base, pkg, cache)
        os.remove(os.path.join(self.server, "p.zip.1"))
        self.assertEqual(canary.fetch_package(self.base, pkg, cache), got, "served from the cache")
        self.assertEqual(os.listdir(cache), ["p.zip.1"])

    def test_bad_hash_leaves_nothing(self):
        pkg = dict(self.pkg({"a.dylib": b"x"}), sha2="0" * 64)
        cache = os.path.join(self.t, "cache")
        with self.assertRaises(canary.CanaryError):
            canary.fetch_package(self.base, pkg, cache)
        self.assertEqual(os.listdir(cache), [])
        bigger = dict(self.pkg({"a.dylib": b"x"}))
        bigger["size"] -= 1
        with self.assertRaises(canary.CanaryError):
            canary.fetch_package(self.base, bigger, cache)
        self.assertEqual(os.listdir(cache), [])

    def test_corrupt_cache_is_replaced(self):
        pkg = self.pkg({"a.dylib": b"x"})
        cache = os.path.join(self.t, "cache")
        os.makedirs(cache)
        with open(os.path.join(cache, "p.zip.1"), "wb") as fh:
            fh.write(b"garbage")
        path = canary.fetch_package(self.base, pkg, cache)
        self.assertEqual(canary.sha256_file(path), pkg["sha2"])

    def test_missing_on_server(self):
        with self.assertRaises(canary.CanaryError):
            canary.fetch_package(self.base, {"file": "nope", "size": 1, "sha2": "0" * 64},
                                 os.path.join(self.t, "cache"))

    def test_unpack(self):
        z = os.path.join(self.t, "ok.zip")
        make_zip(z, {"steamclient.dylib": b"x",
                     "Frameworks/B.framework/Versions/A/B": b"y",
                     "Frameworks/B.framework/Versions/Current": ("link", "A"),
                     "Frameworks/B.framework/B": ("link", "Versions/Current/B")})
        dest = os.path.join(self.t, "client")
        os.makedirs(dest)
        canary.unpack(z, dest)
        with open(os.path.join(dest, "Frameworks/B.framework/B"), "rb") as fh:
            self.assertEqual(fh.read(), b"y")
        self.assertTrue(os.stat(os.path.join(dest, "steamclient.dylib")).st_mode & 0o100)

    def test_unpack_refuses_escapes(self):
        dest = os.path.join(self.t, "client")
        os.makedirs(dest)
        for members in [{"../evil": b"x"}, {"/abs": b"x"}, {"a/../../evil": b"x"},
                        {"l": ("link", "/etc")}, {"l": ("link", "../..")},
                        {"l": ("link", "../outside"), "l/x": b"x"}]:
            z = os.path.join(self.t, "bad.zip")
            make_zip(z, members)
            with self.assertRaises(canary.CanaryError, msg=str(members)):
                canary.unpack(z, dest)
        self.assertFalse(os.path.exists(os.path.join(self.t, "evil")))
        self.assertFalse(os.path.exists(os.path.join(self.t, "outside")))

    def test_unpack_refuses_links_made_through_a_moved_link(self):
        # a is pointed elsewhere after b was checked through it, so b now leads to the sibling
        # folder and b/link would be made there.
        dest = os.path.join(self.t, "client-beta")
        sibling = os.path.join(self.t, "client-stable")
        os.makedirs(dest)
        os.makedirs(sibling)
        z = os.path.join(self.t, "ordered.zip")
        members = [("d/e/f", b"x"), ("a", "d/e"), ("b", "a/../../client-stable"), ("a", "d"),
                   ("b/link", "../client-beta/safe")]
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")  # the second "a" is a duplicate name on purpose
            with zipfile.ZipFile(z, "w") as zf:
                for name, body in members:
                    info = zipfile.ZipInfo(name)
                    kind = stat.S_IFREG if isinstance(body, bytes) else stat.S_IFLNK
                    info.external_attr = (kind | 0o755) << 16
                    zf.writestr(info, body)
        with self.assertRaises(canary.CanaryError):
            canary.unpack(z, dest)
        self.assertEqual(os.listdir(sibling), [])


class Commands(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory()
        self.t = self._t.name
        self.repo = fake_repo(os.path.join(self.t, "repo"))
        self.server = os.path.join(self.t, "server")
        self.manifests = os.path.join(self.t, "manifests")
        os.makedirs(self.server)
        os.makedirs(self.manifests)
        self.base = "file://" + self.server + "/"
        self.state = os.path.join(self.t, "state.json")
        self.work = os.path.join(self.t, "work")

    def tearDown(self):
        self._t.cleanup()

    def write_manifest(self, channel, version, names=None):
        text = manifest_for(version, self.server, canary.PACKAGES if names is None else names)
        with open(os.path.join(self.manifests, f"{channel}.manifest"), "w", encoding="utf-8") as fh:
            fh.write(text)

    def stub(self, rc, text):
        path = os.path.join(self.t, "anchorcheck")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(f"#!/bin/sh\nprintf '%s\\n' \"$*\" > \"{self.t}/args\"\n"
                     f"printf '%s\\n' '{text}'\nexit {rc}\n")
        os.chmod(path, 0o755)
        return path

    def common(self):
        return ["--repo", self.repo, "--base-url", self.base]

    def poll(self):
        rc, out, _ = run(*self.common(), "poll", "--state", self.state,
                         "--manifests", self.manifests, "--offline")
        self.assertEqual(rc, 0)
        return out.split()

    def check(self, channel, stub):
        rc, _, err = run(*self.common(), "check", "--channel", channel,
                         "--manifest", os.path.join(self.manifests, f"{channel}.manifest"),
                         "--cache", os.path.join(self.t, "cache"), "--work", self.work,
                         "--anchorcheck", stub)
        self.assertEqual(rc, 0, err)
        with open(os.path.join(self.work, f"{channel}.json"), encoding="utf-8") as fh:
            return json.load(fh)

    def record(self):
        self.assertEqual(run("record", "--state", self.state, "--results", self.work)[0], 0)

    def test_cycle(self):
        self.write_manifest("stable", 10)
        self.write_manifest("beta", 20)
        self.assertEqual(self.poll(), ["stable", "beta"], "first run checks both")

        res = self.check("beta", self.stub(0, "24 anchors resolved, 0 unresolved"))
        self.assertEqual((res["verdict"], res["build"], res["sigdb"]), ("pass", 20, "100.json"))
        with open(os.path.join(self.t, "args"), encoding="utf-8") as fh:
            args = fh.read().split()
        self.assertEqual(args[:2], ["--client-dir", os.path.join(os.path.abspath(self.work), "client-beta")])
        self.assertEqual(args[2:4], ["--build", "20"])
        self.assertTrue(os.path.isfile(os.path.join(self.work, "client-beta", "bins_client_osx.dylib")))
        self.record()
        self.assertEqual(self.poll(), ["stable"], "beta was recorded")

        self.write_manifest("beta", 21)
        self.assertEqual(self.poll(), ["stable", "beta"], "new beta build")
        res = self.check("beta", self.stub(1, "  X::Y  string anchor=0x0  ANCHOR FAILED"))
        self.assertEqual(res["verdict"], "anchors")
        self.assertEqual(res["failing"], ["X::Y  string anchor=0x0  ANCHOR FAILED"])
        self.record()
        self.assertEqual(self.poll(), ["stable"], "a failure is recorded too: one issue, not one an hour")
        with open(self.state, encoding="utf-8") as fh:
            self.assertEqual(json.load(fh)["beta"]["verdict"], "anchors")

        with open(os.path.join(self.repo, "signatures/macos.arm64/101.json"), "w", encoding="utf-8") as fh:
            fh.write("{}")
        self.assertEqual(self.poll(), ["stable", "beta"], "new signatures re-check every channel")

    def test_load_failure_and_layout(self):
        self.write_manifest("stable", 10)
        self.assertEqual(self.check("stable", self.stub(3, "dlopen failed"))["verdict"], "load")
        self.assertEqual(self.check("stable", self.stub(139, ""))["verdict"], "crash")
        self.write_manifest("stable", 11, [p for p in canary.PACKAGES if p != "sdl3_osx"])
        res = self.check("stable", self.stub(0, ""))
        self.assertEqual(res["verdict"], "layout")
        self.assertIn("sdl3_osx", res["detail"])

    def test_check_fails_on_bad_download(self):
        self.write_manifest("stable", 10)
        os.remove(os.path.join(self.server, "bins_osx.zip.10"))
        rc, _, err = run(*self.common(), "check", "--channel", "stable",
                         "--manifest", os.path.join(self.manifests, "stable.manifest"),
                         "--cache", os.path.join(self.t, "cache"), "--work", self.work,
                         "--anchorcheck", self.stub(0, ""))
        self.assertEqual(rc, 1)
        self.assertIn("download failed", err)
        self.assertFalse(os.path.exists(os.path.join(self.work, "stable.json")),
                         "no result, so record leaves the channel due")

    def test_record_rejects_mismatch(self):
        os.makedirs(self.work)
        with open(os.path.join(self.work, "beta.json"), "w", encoding="utf-8") as fh:
            json.dump({"channel": "stable", "build": 1}, fh)
        self.assertEqual(run("record", "--state", self.state, "--results", self.work)[0], 1)
        self.assertFalse(os.path.exists(self.state))

    def test_report(self):
        out = os.path.join(self.t, "report.md")
        argv = ["report", "--results", self.work, "--out", out, "--run-url", "https://x/run/1"]
        os.makedirs(self.work)
        self.assertEqual(run(*argv)[1].strip(), "none")
        self.write_manifest("stable", 10)
        self.write_manifest("beta", 20)
        self.check("stable", self.stub(0, ""))
        self.assertEqual(run(*argv)[1].strip(), "pass")
        self.check("beta", self.stub(1, "  A::B  ANCHOR FAILED"))
        self.assertEqual(run(*argv)[1].strip(), "fail")
        with open(out, encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn("| stable | 10 | 100.json | every anchor resolves |", text)
        self.assertIn("| beta | 20 | 100.json | anchors do not resolve |", text)
        self.assertIn("### beta 20\n\n```\nA::B  ANCHOR FAILED\n```", text)
        self.assertIn("https://x/run/1", text)

        # stable passes now, beta failed in an earlier run: not "passes" yet.
        self.record()
        os.remove(os.path.join(self.work, "beta.json"))
        argv += ["--state", self.state]
        self.assertEqual(run(*argv)[1].strip(), "none")
        with open(out, encoding="utf-8") as fh:
            self.assertIn("| beta | 20 |  | anchors do not resolve (earlier run) |", fh.read())
        self.check("beta", self.stub(0, ""))
        self.record()
        os.remove(os.path.join(self.work, "beta.json"))
        self.assertEqual(run(*argv)[1].strip(), "pass")

    def test_poll_downloads_manifests(self):
        self.write_manifest("stable", 10)
        os.rename(os.path.join(self.manifests, "stable.manifest"),
                  os.path.join(self.server, "steam_client_osx"))
        rc, out, _ = run(*self.common(), "poll", "--state", self.state,
                         "--manifests", self.manifests, "--channel", "stable")
        self.assertEqual((rc, out.split()), (0, ["stable"]))
        self.assertTrue(os.path.isfile(os.path.join(self.manifests, "stable.manifest")))


if __name__ == "__main__":
    unittest.main(verbosity=1)
