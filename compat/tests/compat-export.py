#!/usr/bin/env python3
"""Offline tests for scripts/compat-export.py, on Discussion nodes in fixtures/discussions.json.

The fixture bodies were made with bridgeplay-web's own discussionBody() (api/report.mjs), so
they are the format the report bot posts; fixtures/discussions-schema2.json with its validate(),
voterOf() and discussionBody() from schema 2 app payloads. Every test works in its own temporary folder.
"""
import contextlib
import datetime
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parents[1] / "scripts" / "compat-export.py"
FIXTURE = HERE / "fixtures" / "discussions.json"
SCHEMA2 = HERE / "fixtures" / "discussions-schema2.json"
NOW = "2026-11-27T12:00:00Z"

sys.dont_write_bytecode = True  # no __pycache__ in scripts/
spec = importlib.util.spec_from_file_location("bridgeplay_compat_export", SCRIPT)
ce = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ce)


def run(*args):
    with contextlib.redirect_stdout(io.StringIO()):
        ce.main([str(a) for a in args])


def nodes_file(folder, keep):
    nodes = json.loads(FIXTURE.read_text())["nodes"]
    path = Path(folder) / "nodes.json"
    path.write_text(json.dumps({"nodes": [n for n in nodes if keep(n)]}))
    return path


class Export(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.tmp.name) / "out"
        run("fetch", cls.out, "--from", FIXTURE)
        run("build", cls.out, "--now", NOW)
        cls.compat = json.loads((cls.out / "compat.json").read_text())
        cls.games = {g["appid"]: g for g in cls.compat["games"]}
        cls.index = json.loads((cls.out / "compat-index.json").read_text())["games"]
        cls.records = {}
        for path in (cls.out / "reports").glob("*.ndjson"):
            for line in path.read_text().splitlines():
                r = json.loads(line)
                cls.records[r["n"]] = r
        cls.board = (cls.out / "board.md").read_text()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def published(self):
        files = [p for p in self.out.rglob("*") if p.is_file() and p.name not in ("README.md", "LICENSE")]
        self.assertTrue(files)
        return "\n".join(p.read_text() for p in files)

    def record(self, appid):
        return next(r for r in self.records.values() if r["appid"] == appid)

    def test_verdict_per_outcome(self):
        expect = {
            101: ("playable", "Ran well on 3 of 4 Macs.", 4, 3, 1, 0, None),
            102: ("doesnt_run", "Did not run on 3 of 3 Macs.", 3, 0, 0, 3, None),
            103: ("mixed", "Mixed: 2 ran well, 0 had issues, 2 did not run.", 4, 2, 0, 2, None),
            104: ("one_report", "One report so far: it ran with issues.", 1, 0, 1, 0, None),
            105: ("broken_since", "Ran well before 0.7.66, but did not run on 2 Macs since.", 5, 3, 0, 2, "0.7.66"),
            111: ("broken_since", "Ran well before Steam build 1794536281, but did not run on 2 Macs since.",
                  4, 2, 0, 2, "Steam build 1794536281"),
            113: ("doesnt_run", "Did not run on 6 of 8 Macs.", 8, 2, 0, 6, None),
        }
        for appid, (label, answer, n, p, i, b, since) in expect.items():
            self.assertEqual(self.games[appid]["verdict"],
                             {"label": label, "answer": answer, "n": n, "p": p, "i": i, "b": b, "since": since}, appid)

    def test_one_vote_per_mac(self):
        # 101: the M1 / 8 GB / macOS 26.1 failure on 0.7.64 is that Mac's older report.
        self.assertEqual(self.games[101]["total"], 5)
        self.assertEqual(self.games[101]["verdict"]["n"], 4)

    def test_window(self):
        # 108: the failure 200 days ago is outside the window; 107 has only old reports and keeps them.
        self.assertEqual(self.games[108]["verdict"]["label"], "one_report")
        self.assertEqual(self.games[108]["verdict"]["p"], 1)
        self.assertEqual(self.games[107]["verdict"]["label"], "playable")

    def test_old_status_stays(self):
        # status is still compat-merge.js statusOf, so the site can switch when it is ready.
        self.assertEqual(self.games[113]["status"], "playable")
        self.assertEqual(self.games[105]["status"], "playable")
        self.assertEqual(self.games[102]["status"], "broken")

    def test_api_compat_shape(self):
        self.assertEqual(list(self.compat)[:3], ["category", "updated", "rule"])
        self.assertEqual(self.compat["category"], "compatibility-reports")
        self.assertEqual(self.compat["updated"], "2026-11-27T12:00:00.000Z")
        for g in self.compat["games"]:
            self.assertEqual(list(g), ["appid", "name", "total", "counts", "latest", "status", "verdict"])
            self.assertEqual(list(g["verdict"]), ["label", "answer", "n", "p", "i", "b", "since"])
            for r in g["latest"]:
                keys = ["status", "chip", "memory", "macos", "version", "date", "url", "note", "issue", "lowPower"]
                self.assertEqual(list(r), keys + (["hardware"] if r["issue"] == "performance" else []))
        slow = self.games[101]["latest"][0]
        self.assertEqual((slow["issue"], slow["hardware"]), ("performance", True))  # base M3: likely the Mac
        self.assertTrue(slow["url"].startswith("https://github.com/raymondchins/Bridgeplay/discussions/"))
        self.assertEqual([g["appid"] for g in self.compat["games"]], sorted(self.games))

    def test_index(self):
        self.assertEqual(self.index["105"], {"v": "broken_since", "n": 5, "p": 3, "i": 0, "b": 2, "since": "0.7.66",
                                             "build": 83, "date": "2026-11-26"})
        self.assertNotIn("since", self.index["101"])
        self.assertEqual(set(self.index), {str(a) for a in self.games})

    def test_not_counted(self):
        # 43 nodes: another user's post, a non-report, an unknown status and a user named like the bot.
        self.assertEqual(len(self.records), 39)
        self.assertEqual(self.games[101]["counts"], {"playable": 3, "issues": 1, "broken": 1})
        self.assertNotIn("M5", {r["chip"] for r in self.records.values() if r["appid"] == 101})

    def test_privacy(self):
        text = self.published()
        for needle in ["john", "example.com", "76561198000000001", "12345]", "192.168", "415 555", "x.com",
                       "Mac17,5", "LG HDR", "3456x2234", "gpuCores", "displays", "0f8e7d6c", "install", "SteamUser",
                       "nobattleye", "\u200b"]:
            self.assertNotIn(needle, text, needle)
        self.assertEqual(self.record(109)["note"], "email me at <email>, steam <steamid> [U:1:<redacted>], see <link> "
                         "or <name>, call <number>, ip <ip>, files in ~/Games")
        self.assertEqual(self.record(109)["macos"], "macOS 26.1")
        self.assertEqual(set(self.record(101)), {
            "n", "date", "appid", "name", "status", "chip", "memory", "macos", "version", "build", "steam", "engine",
            "backend", "source", "issue", "note", "low_power", "thermal", "health", "minutes", "exit_status",
            "gamefix", "sig", "schema", "voter", "steam_channel", "engine_id", "launch", "bulk", "channel"})

    def test_fields_from_logs(self):
        tuned = self.record(110)
        self.assertEqual(tuned["gamefix"], {"BACKEND": "dxvk", "VSYNC": "1", "STEAMDECK": "1", "DXVK_ASYNC": "1"})
        self.assertEqual((tuned["health"], tuned["exit_status"], tuned["sig"]), ("healthy", 0, None))
        self.assertEqual(self.record(109)["engine"], "CrossOver 25.1")
        self.assertEqual(self.record(102)["health"], "failed")
        self.assertEqual(self.record(106)["sig"], "anti-cheat")

    def test_board(self):
        self.assertIn("| 8 | Broken Game ×3, Steam Broke It ×2, Regressed Game ×2, Good Game | "
                      "`Unhandled page fault on read access to # at address # (thread #), starting debugger...` "
                      "**Look first**", self.board)
        self.assertIn("| 2 | `anti-cheat` |", self.board)
        self.assertIn("| Hard Game | 113 | 8 | 6 | 0 | `wine: Call from # to unimplemented function "
                      "concrt#.dll._TaskCollection, aborting` | doesnt_run |", self.board)
        self.assertNotIn("Look first", next(l for l in self.board.splitlines() if "no-crash-line" in l))

    def test_months(self):
        self.assertEqual(sorted(p.name for p in (self.out / "reports").iterdir()), ["2026-05.ndjson", "2026-11.ndjson"])
        for path in (self.out / "reports").iterdir():
            numbers = [json.loads(l)["n"] for l in path.read_text().splitlines()]
            self.assertEqual(numbers, sorted(numbers))
        self.assertEqual((self.out / "LICENSE").read_text(), (HERE.parent / "data" / "LICENSE").read_text())
        self.assertTrue((self.out / "README.md").is_file())


class Schema2(unittest.TestCase):
    """Schema 1 and 2 reports in one store; schema 2 ones carry the bot's per-game voter code."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.tmp.name) / "out"
        both = Path(cls.tmp.name) / "both.json"
        both.write_text(json.dumps({"nodes": json.loads(FIXTURE.read_text())["nodes"]
                                    + json.loads(SCHEMA2.read_text())["nodes"]}))
        run("fetch", cls.out, "--from", both)
        run("build", cls.out, "--now", NOW)
        cls.games = {g["appid"]: g for g in json.loads((cls.out / "compat.json").read_text())["games"]}
        cls.index = json.loads((cls.out / "compat-index.json").read_text())["games"]
        cls.records = [json.loads(l) for p in (cls.out / "reports").glob("*.ndjson") for l in p.read_text().splitlines()]

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def of(self, appid):
        return sorted((r for r in self.records if r["appid"] == appid), key=lambda r: r["n"])

    def test_fields(self):
        first, second = self.of(201)
        self.assertEqual((second["schema"], second["steam"], second["steam_channel"], second["engine_id"]),
                         (2, 1795000000, "stable", "winecx-11.17"))
        self.assertEqual(second["launch"], {"code": "ok", "seconds": 3590, "window": 14})
        self.assertEqual(first["launch"], {"code": "crashed", "seconds": 4, "window": None})
        self.assertRegex(second["voter"], r"^[0-9a-f]{16}$")
        self.assertEqual(first["voter"], second["voter"], "one install, one game: one code")
        self.assertNotEqual(self.of(202)[1]["voter"], second["voter"], "another game: another code")
        old, _, bulk = self.of(202)
        self.assertEqual((old["schema"], old["voter"], old["launch"], old["steam"]), (1, None, None, None))
        self.assertEqual((bulk["bulk"], bulk["status"]), (True, "gold"))
        self.assertFalse(self.of(201)[0]["bulk"])

    def test_one_vote_per_voter(self):
        # 201: macOS changed between the two reports, which the setup proxy would count as two Macs.
        v = self.games[201]["verdict"]
        self.assertEqual((v["label"], v["n"], v["p"]), ("one_report", 1, 1))
        self.assertEqual(self.games[201]["total"], 2)

    def test_schema1_report_of_a_voters_setup_drops_out(self):
        # 202: the schema 1 failure has the setup a voter reported on a newer build.
        v = self.games[202]["verdict"]
        self.assertEqual((v["label"], v["answer"]), ("playable", "Ran well on 2 of 2 Macs."))

    def test_steam_build_regression(self):
        v = self.games[203]["verdict"]
        self.assertEqual((v["label"], v["since"]), ("broken_since", "Steam build 1795567705"))
        self.assertEqual(self.index["203"]["since"], "Steam build 1795567705")

    def test_schema1_verdicts_unchanged(self):
        # The schema 1 fixture games read the same with schema 2 reports in the store.
        self.assertEqual(self.games[101]["verdict"]["answer"], "Ran well on 3 of 4 Macs.")
        self.assertEqual(self.games[111]["verdict"]["since"], "Steam build 1794536281")

    def test_install_ids_stay_out(self):
        text = "\n".join(p.read_text() for p in self.out.rglob("*") if p.is_file() and p.name not in ("README.md", "LICENSE"))
        self.assertNotIn("00000000-0000-4000", text)
        self.assertNotIn("install", text)


class Store(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.out = self.dir / "out"

    def tearDown(self):
        self.tmp.cleanup()

    def count(self):
        return sum(len(p.read_text().splitlines()) for p in (self.out / "reports").glob("*.ndjson"))

    def test_incremental_prune_and_full_guard(self):
        run("fetch", self.out, "--from", nodes_file(self.dir, lambda n: n["number"] < 1020))
        first = self.count()
        run("fetch", self.out, "--from", FIXTURE)
        self.assertEqual(self.count(), 39)
        self.assertLess(first, 39)
        # A report deleted from the Discussions leaves on the next prune.
        run("fetch", self.out, "--prune", "--from", nodes_file(self.dir, lambda n: n["number"] != 1000))
        self.assertEqual(self.count(), 38)
        # A full read that finds far fewer reports keeps the store.
        with self.assertRaises(SystemExit), contextlib.redirect_stdout(io.StringIO()):
            ce.main(["fetch", str(self.out), "--full", "--from", str(nodes_file(self.dir, lambda n: n["number"] < 1005))])
        self.assertEqual(self.count(), 38)
        # So does a prune listing that misses most of them.
        with self.assertRaises(SystemExit), contextlib.redirect_stdout(io.StringIO()):
            ce.main(["fetch", str(self.out), "--prune", "--from", str(nodes_file(self.dir, lambda n: n["number"] < 1005))])
        self.assertEqual(self.count(), 38)

    def test_build_refuses_personal_data(self):
        run("fetch", self.out, "--from", FIXTURE)
        path = self.out / "reports" / "2026-11.ndjson"
        lines = path.read_text().splitlines()
        r = json.loads(lines[0])
        r["note"] = "write to someone@example.org"
        path.write_text("\n".join([json.dumps(r)] + lines[1:]) + "\n")
        with self.assertRaises(SystemExit), contextlib.redirect_stdout(io.StringIO()):
            ce.main(["build", str(self.out), "--now", NOW])
        self.assertFalse((self.out / "compat.json").exists())

    def test_build_refuses_empty_store(self):
        self.out.mkdir()
        with self.assertRaises(SystemExit):
            ce.main(["build", str(self.out), "--now", NOW])

    def test_fetch_needs_a_token(self):
        env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
        with patch.dict(os.environ, env, clear=True), self.assertRaises(SystemExit):
            ce.main(["fetch", str(self.out)])


class Pieces(unittest.TestCase):
    def test_chip_and_macos(self):
        self.assertEqual(ce.chip_family("M4 Max"), "M4 Max")
        self.assertEqual(ce.chip_family("Apple M9 Turbo"), "Other")
        # Same pattern as the app (GameReport.swift), A-series chips too.
        self.assertEqual(ce.chip_family("A18 Pro"), "A18 Pro")
        self.assertEqual(ce.chip_family("M0"), "Other")
        self.assertEqual(ce.macos_minor("macOS 26.1.2"), "macOS 26.1")
        self.assertEqual(ce.memory_size("Other"), "Other")
        self.assertEqual(ce.version_of("0.7.66 (83)"), ("0.7.66 (83)", 83))
        self.assertEqual(ce.version_of("0.7.66; rm"), (None, 0))

    def test_schema_fields(self):
        self.assertEqual([ce.schema_of(f) for f in ({}, {"schema": 1}, {"schema": 2}, {"schema": 5}, {"schema": "2"},
                                                     {"schema": True}, {"schema": 0})], [1, 1, 2, 2, 1, 1, 1])
        self.assertEqual(ce.launch_of({"code": "ok", "seconds": 9}), {"code": "ok", "seconds": 9})
        self.assertEqual(ce.launch_of({"code": "ok", "seconds": -1, "window": None}), {"code": "ok", "seconds": None, "window": None})
        self.assertEqual(ce.launch_of({"code": "ok", "window": "12"}), {"code": "ok", "seconds": None})
        self.assertIsNone(ce.launch_of({"code": "Crashed!"}))
        self.assertIsNone(ce.launch_of("ok"))
        node = {"number": 1, "createdAt": "2026-11-26T10:00:00Z", "author": {"__typename": "Bot", "login": "bot"},
                "body": '```json\n{"schema":1,"appid":"1","status":"platinum","voter":"0123456789abcdef","launch":{"code":"ok"}}\n```'}
        r = ce.parse_report(node, ["bot[bot]"])
        self.assertEqual((r["schema"], r["voter"], r["launch"]), (1, None, None), "schema 1 carries no schema 2 fields")
        node["body"] = node["body"].replace('"schema":1', '"schema":2').replace('"code":"ok"', '"code":"ok","seconds":600')
        r = ce.parse_report(node, ["bot[bot]"])
        # Without a run log or "Session N min", the session length comes from the launch record.
        self.assertEqual((r["voter"], r["minutes"]), ("0123456789abcdef", 10))
        node["body"] = node["body"].replace("0123456789abcdef", "0F8FAD5B-D9CB")
        self.assertIsNone(ce.parse_report(node, ["bot[bot]"])["voter"])

    def test_crash_key(self):
        a = ce.crash_key('0124:err:module:import_dll Library X.dll (which is needed by L"C:\\\\Games\\\\a.exe") not found (3 times)')
        b = ce.crash_key('0a10:err:module:import_dll Library X.dll (which is needed by L"Z:\\\\Users\\\\bob\\\\b.exe") not found')
        self.assertEqual(a, b)
        self.assertNotIn("bob", b)

    def test_broken_since_needs_most_of_the_newer_reports(self):
        now = datetime.datetime(2026, 11, 27, tzinfo=datetime.timezone.utc)
        rows = []
        for k, (status, build, chip) in enumerate([("platinum", 81, "M1"), ("platinum", 81, "M2"), ("borked", 83, "M3"),
                                                   ("borked", 83, "M4"), ("platinum", 80, "M5"), ("bronze", 83, "M5 Pro"),
                                                   ("bronze", 83, "M5 Max")]):
            rows.append({"n": k, "date": "2026-11-20T00:00:00Z", "status": status, "build": build, "steam": None,
                         "version": f"0.7.{build - 17} ({build})", "chip": chip, "memory": "16 GB", "macos": "macOS 26.1"})
        # Two failures against two "ran with issues" on the newer build is not a majority.
        self.assertEqual(ce.verdict(rows, now)["label"], "mixed")
        self.assertEqual(ce.verdict(rows[:5], now)["label"], "broken_since")
        # A game that mostly failed before is not "broken since": it never ran well.
        before = [dict(rows[0], n=20 + k, chip=f"M{k} Max", status="borked") for k in range(1, 5)]
        self.assertEqual(ce.verdict(rows[:5] + before, now)["label"], "doesnt_run")

    def test_unknown_steam_builds_hide_no_regression(self):
        # Schema 1 reports carry no Steam build. They are no reports from build zero, so failures
        # without one don't outweigh the successes on the older Steam build.
        now = datetime.datetime(2026, 11, 27, tzinfo=datetime.timezone.utc)
        rows = []
        for k, (status, steam) in enumerate([("platinum", 1795500000), ("gold", 1795500000), ("borked", 1795567705),
                                             ("borked", 1795567705), ("borked", None), ("borked", None), ("borked", None)]):
            rows.append({"n": k, "date": "2026-11-20T00:00:00Z", "status": status, "build": 83, "steam": steam,
                         "version": "0.7.66 (83)", "chip": f"M{k + 1}", "memory": "16 GB", "macos": "macOS 26.1"})
        v = ce.verdict(rows, now)
        self.assertEqual((v["label"], v["since"]), ("broken_since", "Steam build 1795567705"))
        first, failed = ce.broken_since(ce.votes(rows, now), "steam")
        self.assertEqual((first["steam"], failed), (1795567705, 2))
        # Without a build on either side there is nothing to compare.
        self.assertIsNone(ce.broken_since([dict(r, steam=None) for r in rows], "steam"))


if __name__ == "__main__":
    unittest.main()
