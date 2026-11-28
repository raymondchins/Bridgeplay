#!/usr/bin/env python3
"""Offline tests for scripts/compat-regressions.py on the compat-export fixture.

The store is built with compat-export.py from fixtures/discussions.json, in a temporary folder.
GitHub is never called: issues come from lists and `rest` is replaced by a recorder.
"""
import contextlib
import copy
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parents[1] / "scripts"
FIXTURE = HERE / "fixtures" / "discussions.json"
NOW = "2026-11-27T12:00:00Z"

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("bridgeplay_compat_regressions", SCRIPTS / "compat-regressions.py")
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)
ce = cr.ce


def quiet(fn, *args, **kw):
    with contextlib.redirect_stdout(io.StringIO()) as out:
        result = fn(*args, **kw)
    return result, out.getvalue()


def issue(number, action, state="open"):
    return {"number": number, "state": state, "title": action["title"], "body": action["body"]}


class Watch(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.tmp.name) / "out"
        quiet(ce.main, ["fetch", str(cls.out), "--from", str(FIXTURE)])
        cls.store = ce.load_store(cls.out)
        cls.now = ce.parse_date(NOW)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def plan(self, issues, store=None, **kw):
        return cr.plan(store or self.store, issues, self.now, **kw)

    def first(self):
        actions, _ = self.plan([])
        return {a["appid"]: a for a in actions}

    def with_report(self, **fields):
        """The store plus one report copied from game 105's newest failure, changed by fields."""
        store = copy.deepcopy(self.store)
        base = max((r for r in store.values() if r["appid"] == 105 and r["status"] == "borked"), key=lambda r: r["n"])
        r = dict(base, n=9000 + len(store), sig=None, **fields)
        store[r["n"]] = r
        return store

    def test_same_rule_as_the_export(self):
        # Exactly the games the export labels broken_since.
        games, _ = ce.aggregate(self.store, self.now)
        broken = {g["appid"] for g in games if g["verdict"]["label"] == "broken_since"}
        self.assertEqual(set(cr.regressions(self.store, self.now)), broken)
        self.assertEqual(broken, {105, 111})

    def test_open_with_evidence(self):
        opened = self.first()
        self.assertEqual(set(opened), {105, 111})
        a = opened[105]
        self.assertEqual(a["do"], "open")
        self.assertTrue(a["title"].startswith("Regression: ") and a["title"].endswith("did not run since 0.7.66"), a["title"])
        body = a["body"]
        self.assertIn("<!-- bridgeplay-regression-watch appid=105 key=build since=83 state=regressed -->", body)
        self.assertIn("Ran well before 0.7.66, but did not run on 2 Macs since.", body)
        self.assertIn("| 0.7.64 (81) | 3 | 0 | 0 |", body)
        self.assertRegex(body, r"\| 0\.7\.66 \(83\) ← since \| \d+ \| \d+ \| [2-9] \|")
        self.assertRegex(body, r"- \d+ × `[^`]+`")
        self.assertIn("/discussions/", body)
        steam = opened[111]
        self.assertIn("key=steam since=1794536281", steam["body"])
        self.assertIn("did not run since Steam build 1794536281", steam["title"])
        self.assertIn("| Steam client build |", steam["body"])

    def test_signature_from_the_board(self):
        # The issue quotes the sig field the export computed, the one board.md groups by.
        g = cr.regressions(self.store, self.now)[105]
        sigs = {r["sig"] for r in self.store.values() if r["appid"] == 105 and r["sig"]}
        self.assertTrue(g["sigs"])
        self.assertTrue({s for s, _ in g["sigs"]} <= sigs)

    def test_unchanged_is_quiet(self):
        opened = self.first()
        issues = [issue(1, opened[105]), issue(2, opened[111])]
        self.assertEqual(self.plan(issues), ([], []))
        # A new date alone does not rewrite the body.
        later = cr.plan(self.store, issues, ce.parse_date("2026-11-28T12:00:00Z"))
        self.assertEqual(later, ([], []))

    def test_update_when_evidence_changes(self):
        opened = self.first()
        store = self.with_report(chip="M4 Max", memory="64 GB", macos="macOS 26.2")
        actions, _ = self.plan([issue(1, opened[105]), issue(2, opened[111])], store)
        self.assertEqual([(a["do"], a["number"]) for a in actions], [("edit", 1)])
        self.assertIn("3 Macs since", actions[0]["body"])

    def test_recovery_closes(self):
        opened = self.first()
        store = self.with_report(status="gold", chip="M4 Max", memory="64 GB", macos="macOS 26.2",
                                 date="2026-11-27T09:00:00Z")
        actions, _ = self.plan([issue(1, opened[105]), issue(2, opened[111])], store)
        self.assertEqual([(a["do"], a["number"]) for a in actions], [("comment", 1), ("close", 1)])
        self.assertIn("Ran well again on 0.7.66 (83)", actions[0]["body"])
        self.assertIn("state=recovered", actions[1]["body"])
        # The closed issue stays closed on the next run.
        closed = dict(issue(1, opened[105], "closed"), body=actions[1]["body"])
        self.assertEqual(self.plan([closed, issue(2, opened[111])], store), ([], []))

    def test_older_success_is_not_recovery(self):
        # A Mac that ran it on the new build before the failures came in lapses the rule, but
        # does not close the issue.
        opened = self.first()
        store = self.with_report(status="gold", chip="M4 Max", memory="64 GB", macos="macOS 26.2",
                                 date="2026-11-20T09:00:00Z")
        self.assertNotIn(105, cr.regressions(store, self.now))
        actions, _ = self.plan([issue(1, opened[105]), issue(2, opened[111])], store)
        self.assertEqual([(a["do"], a["number"]) for a in actions], [("comment", 1), ("edit", 1)])
        self.assertIn("state=quiet", actions[1]["body"])

    def test_replaced_success_is_not_recovery(self):
        # One Mac ran it well on the new build, then ran it with issues: its newest report counts,
        # so the rule lapses (with a second Mac with issues) but the issue is not closed.
        opened = self.first()
        store = self.with_report(status="gold", voter="mac-a", chip="M4 Max", memory="64 GB",
                                 macos="macOS 26.2", date="2026-11-27T09:00:00Z")
        success = max(store)
        for n, fields in ((success + 1, dict(status="bronze", date="2026-11-27T10:00:00Z")),
                          (success + 2, dict(status="bronze", voter="mac-b", chip="M2", memory="16 GB"))):
            store[n] = dict(store[success], n=n, **fields)
        issues = [issue(1, opened[105]), issue(2, opened[111])]
        actions, _ = self.plan(issues, store)
        self.assertEqual([(a["do"], a["number"]) for a in actions], [("comment", 1), ("edit", 1)])
        self.assertIn("state=quiet", actions[1]["body"])
        # Without the later report, its success closes the issue.
        del store[success + 1]
        actions, _ = self.plan(issues, store)
        self.assertIn(("close", 1), [(a["do"], a["number"]) for a in actions])

    def test_rule_lapse_comments_once(self):
        opened = self.first()
        # Two Macs that ran with issues on the new build: the failures are no longer most of it.
        store = self.with_report(status="bronze", chip="M4 Max", memory="64 GB", macos="macOS 26.2")
        store = {**store, **{9999: dict(store[max(store)], n=9999, chip="M2", memory="16 GB")}}
        actions, _ = self.plan([issue(1, opened[105]), issue(2, opened[111])], store)
        self.assertEqual([(a["do"], a["number"]) for a in actions], [("comment", 1), ("edit", 1)])
        self.assertIn("state=quiet", actions[1]["body"])
        again = dict(issue(1, opened[105]), body=actions[1]["body"])
        self.assertEqual(self.plan([again, issue(2, opened[111])], store), ([], []))
        # And it says so when the rule matches again.
        actions, _ = self.plan([again, issue(2, opened[111])])
        self.assertEqual([a["do"] for a in actions], ["edit", "comment"])
        self.assertIn("state=regressed", actions[0]["body"])

    def test_closed_by_hand_stays_closed(self):
        opened = self.first()
        issues = [issue(1, opened[105], "closed"), issue(2, opened[111])]
        self.assertEqual(self.plan(issues), ([], []))

    def test_new_break_reopens(self):
        opened = self.first()
        old = dict(issue(1, opened[105], "closed"), body=opened[105]["body"].replace("since=83", "since=79"))
        actions, _ = self.plan([old, issue(2, opened[111])])
        self.assertEqual([(a["do"], a["number"]) for a in actions], [("reopen", 1), ("comment", 1)])
        self.assertIn("since=83 state=regressed", actions[0]["body"])

    def test_cap(self):
        actions, waiting = self.plan([], max_open=1)
        self.assertEqual([a["appid"] for a in actions], [105])
        self.assertEqual(waiting, [111])

    def test_other_issues_ignored(self):
        stray = [{"number": 7, "state": "open", "title": "x", "body": "no marker"},
                 {"number": 8, "state": "open", "title": "pr", "body": self.first()[105]["body"], "pull_request": {}}]
        self.assertEqual({a["do"] for a in self.plan(stray)[0]}, {"open"})

    def test_private_text_stops(self):
        store = copy.deepcopy(self.store)
        for r in store.values():
            if r["appid"] == 105:
                r["name"] = "Game of john@example.com"
        with self.assertRaises(SystemExit):
            self.plan([], store)

    def test_cli_dry_run_and_apply(self):
        folder = Path(self.tmp.name)
        (folder / "issues.json").write_text("[]")
        calls = []

        def fake(token, method, path, data=None):
            calls.append((method, path, data))
            return {"number": 40 + len(calls)} if method == "POST" and path.endswith("/issues") else {}

        with patch.object(cr, "rest", fake), patch.dict("os.environ", {"GITHUB_TOKEN": ""}, clear=False):
            (actions, _), text = quiet(cr.main, [str(self.out), "--now", NOW, "--issues", str(folder / "issues.json")])
            self.assertEqual(calls, [])
            self.assertIn("dry run", text)
            with self.assertRaises(SystemExit):
                quiet(cr.main, [str(self.out), "--now", NOW, "--issues", str(folder / "issues.json"), "--apply"])
        with patch.object(cr, "rest", fake), patch.dict("os.environ", {"GITHUB_TOKEN": "t"}):
            quiet(cr.main, [str(self.out), "--now", NOW, "--issues", str(folder / "issues.json"), "--apply"])
        self.assertEqual(calls[0][:2], ("POST", "/repos/raymondchins/Bridgeplay/labels"))
        posts = [c for c in calls if c[1].endswith("/issues")]
        self.assertEqual(len(posts), 2)
        self.assertEqual(posts[0][2]["labels"], ["regression-watch"])

    def test_apply_verbs(self):
        calls = []
        with patch.object(cr, "rest", lambda t, m, p, d=None: calls.append((m, p, d)) or {}):
            cr.apply("t", [{"do": "close", "appid": 1, "number": 5, "body": "b"},
                           {"do": "reopen", "appid": 1, "number": 5, "title": "t", "body": "b"},
                           {"do": "comment", "appid": 1, "number": 5, "body": "c"}])
        base = "/repos/raymondchins/Bridgeplay/issues/5"
        self.assertEqual(calls, [("PATCH", base, {"state": "closed", "state_reason": "completed", "body": "b"}),
                                 ("PATCH", base, {"state": "open", "title": "t", "body": "b"}),
                                 ("POST", base + "/comments", {"body": "c"})])


if __name__ == "__main__":
    unittest.main(verbosity=1)
