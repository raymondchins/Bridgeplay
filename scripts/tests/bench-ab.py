#!/usr/bin/env python3
"""Offline tests for scripts/bench-ab.py with captures and run logs made in a temp folder.

Nothing here opens Steam: the run test passes a stub opener and a fake Steam root.
"""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("bridgeplay_bench_ab", HERE.parent / "bench-ab.py")
ab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ab)


def capture(folder, minute, frame_ms, slow_ms, pid=100, frames=3000, appid="4242", limit="none"):
    """frames of frame_ms with every 100th at slow_ms, started at 10:<minute>:00Z."""
    body = [f"{slow_ms if i % 100 == 99 else frame_ms:.3f}" for i in range(frames)]
    path = folder / f"20261127T10{minute:02d}00Z-{pid}.csv"
    path.write_text("\n".join([
        "# bridgeplay-bench 1", f"# appid={appid}", "# exe=Game.exe", f"# pid={pid}",
        f"# started=2026-11-27T10:{minute:02d}:00Z", "# chip=Apple M5 Max", "# macos=27.2",
        "# framegen=forced-off", f"# fps_limit={limit}", "# frame_ms", *body, "# end", ""]))
    return path


def run_log(path, starts):
    """One helper section and one game section per (game start, first frame after) pair."""
    lines = []
    for start, frame in starts:
        lines += ["=== bridgeplay run Thu Nov 27 10:00:00 UTC 2026 ===", "verb=getcompatpath",
                  "time: startup at 0.010s"]
        lines += ["=== bridgeplay run Thu Nov 27 10:00:05 UTC 2026 ===", "verb=waitforexitandrun",
                  "time: startup at 0.010s", f"time: game start at {start:.3f}s",
                  "time: game exited at 90.000s", "time: first window 1.000s after the game started",
                  f"time: first frame {frame:.3f}s after the game started"]
    path.write_text("\n".join(lines) + "\n")


def quiet(fn, *args):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = fn(*args)
    return code, out.getvalue(), err.getvalue()


class CompareTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.a, self.b = root / "A", root / "B"
        self.a.mkdir()
        self.b.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def fill(self, folder, base_ms, jitter, slow_ms, first_minute):
        # the warm-up run is much slower: it must be left out
        capture(folder, first_minute, base_ms * 2, slow_ms * 2)
        for i, j in enumerate(jitter, 1):
            capture(folder, first_minute + i * 5, base_ms + j, slow_ms)

    def test_b_faster(self):
        self.fill(self.a, 12.0, (0.0, 0.1, -0.1, 0.05), 40.0, 0)
        self.fill(self.b, 10.0, (0.0, 0.1, -0.1, 0.05), 30.0, 30)
        # a second Wine process of one B launch, overlapping it with few frames: not a run
        capture(self.b, 35, 99.0, 99.0, pid=101, frames=50)
        r = ab.compare([self.a], [self.b])
        self.assertTrue(r["enough"])
        self.assertEqual((r["runs"]["A"]["used_captures"], r["runs"]["B"]["used_captures"]), (4, 4))
        rows = {row["metric"]: row for row in r["rows"]}
        self.assertEqual(rows["frame_ms_p50"]["verdict"], "B better")
        self.assertLess(rows["frame_ms_p50"]["ci_high"], 0)
        self.assertEqual(rows["low_1_fps"]["verdict"], "B better")
        self.assertEqual(r["verdict"], "B is faster")
        self.assertEqual(r["warnings"], [])

    def test_same_settings_are_same(self):
        self.fill(self.a, 10.0, (0.0, 0.3, -0.3, 0.1), 30.0, 0)
        self.fill(self.b, 10.0, (0.1, -0.3, 0.3, 0.0), 30.0, 30)
        r = ab.compare([self.a], [self.b])
        self.assertEqual({row["verdict"] for row in r["rows"]}, {"same"})
        self.assertEqual(r["verdict"], "no measurable difference in frame time or 1% lows")

    def test_min_effect_hides_tiny_changes(self):
        self.fill(self.a, 10.0, (0.0, 0.0, 0.0, 0.0), 30.0, 0)
        self.fill(self.b, 10.05, (0.0, 0.0, 0.0, 0.0), 30.0, 30)
        rows = {row["metric"]: row for row in ab.compare([self.a], [self.b])["rows"]}
        self.assertEqual(rows["frame_ms_p50"]["verdict"], "same")  # 0.5% < 1%

    def test_not_enough_runs(self):
        self.fill(self.a, 10.0, (0.0, 0.1), 30.0, 0)
        self.fill(self.b, 10.0, (0.0, 0.1, 0.2), 30.0, 30)
        code, out, _ = quiet(ab.main, ["compare", str(self.a), "--vs", str(self.b)])
        self.assertEqual(code, 2)
        self.assertIn("not enough runs: need 3 per side after 1 warm-up run(s); A has 2, B has 3", out)

    def test_warns_on_different_limit(self):
        self.fill(self.a, 10.0, (0.0, 0.1, -0.1), 30.0, 0)
        for i in range(4):
            capture(self.b, 30 + i * 5, 10.0, 30.0, limit="60")
        r = ab.compare([self.a], [self.b])
        self.assertIn("frame rate limit differs: A none, B 60", r["warnings"])

    def test_launch_times_from_logs(self):
        run_log(self.a / "a.log", [(9.0, 5.0), (6.0, 2.0), (6.1, 2.1), (5.9, 1.9)])
        run_log(self.b / "b.log", [(9.0, 5.0), (4.0, 2.0), (4.1, 2.0), (3.9, 2.1)])
        self.fill(self.a, 10.0, (0.0, 0.1, -0.1), 30.0, 0)
        self.fill(self.b, 10.0, (0.0, 0.1, -0.1), 30.0, 30)
        r = ab.compare([self.a], [self.b])
        rows = {row["metric"]: row for row in r["rows"]}
        self.assertEqual((rows["game_start_s"]["a_median"], rows["game_start_s"]["b_median"]), (6.0, 4.0))
        self.assertEqual(rows["game_start_s"]["verdict"], "B better")
        self.assertEqual(rows["first_frame_s"]["a_median"], 8.0)
        self.assertEqual(r["runs"]["A"]["logs"], 4)  # helper sections are not runs

    def test_first_frame_needs_min_runs_of_its_own(self):
        # Every launch counts for the game start, but only one per side logged a first frame.
        for folder, start in ((self.a, 6.0), (self.b, 4.0)):
            lines = []
            for n in range(4):
                lines += ["=== bridgeplay run Thu Nov 27 10:00:05 UTC 2026 ===", "verb=waitforexitandrun",
                          f"time: game start at {start + n * 0.1:.3f}s", "time: game exited at 90.000s"]
                if n == 1:
                    lines.append("time: first frame 2.000s after the game started")
            (folder / "runs.log").write_text("\n".join(lines) + "\n")
        r = ab.compare([self.a], [self.b])
        rows = {row["metric"]: row for row in r["rows"]}
        self.assertEqual(rows["game_start_s"]["verdict"], "B better")
        self.assertEqual(rows["first_frame_s"]["verdict"], "too few runs")
        self.assertEqual((rows["first_frame_s"]["a_runs"], rows["first_frame_s"]["b_runs"]), (1, 1))
        code, out, _ = quiet(ab.main, ["compare", str(self.a), "--vs", str(self.b)])
        self.assertEqual(code, 0)
        self.assertIn("to first frame     too few runs (A 1, B 1)", out)

    def test_text_and_json(self):
        self.fill(self.a, 12.0, (0.0, 0.1, -0.1), 40.0, 0)
        self.fill(self.b, 10.0, (0.0, 0.1, -0.1), 30.0, 30)
        code, out, _ = quiet(ab.main, ["compare", str(self.a), "--vs", str(self.b)])
        self.assertEqual(code, 0)
        self.assertIn("median frame time  A 12.00 ms  B 10.00 ms  -16.7%", out)
        self.assertIn("verdict: B is faster", out)
        code, out, _ = quiet(ab.main, ["compare", str(self.a), "--vs", str(self.b), "--json"])
        self.assertEqual(json.loads(out)["verdict"], "B is faster")

    def test_rejects_bad_input(self):
        (self.a / "x.csv").write_text("10\n")
        code, _, err = quiet(ab.main, ["compare", str(self.a), "--vs", str(self.b)])
        self.assertEqual(code, 1)
        self.assertIn("not a bridgeplay-bench 1 capture", err)


class RunTests(unittest.TestCase):
    def test_refuses_without_flag(self):
        with mock.patch.object(ab.subprocess, "run") as opened:  # would be /usr/bin/open
            code, _, err = quiet(ab.main, ["run", "--appid", "4242", "--label", "A", "--out", "/nonexistent"])
        self.assertEqual(code, 2)
        self.assertIn("add --launch-steam", err)
        opened.assert_not_called()

    def test_drive_with_stub_steam(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            steam, ext = root / "Steam", root / "External"
            (steam / "steamapps").mkdir(parents=True)
            (ext / "steamapps/compatdata/4242").mkdir(parents=True)
            (ext / "steamapps/appmanifest_4242.acf").write_text('"AppState"\n{\n\t"appid"\t\t"4242"\n}\n')
            (steam / "steamapps/libraryfolders.vdf").write_text(
                f'"libraryfolders"\n{{\n\t"1"\n\t{{\n\t\t"path"\t\t"{ext}"\n\t}}\n}}\n')
            support = root / "support"
            bench_dir = support / "launchers/4242/bench"
            bench_dir.mkdir(parents=True)
            capture(bench_dir, 0, 10.0, 30.0)  # an older capture: not copied
            log = ext / "steamapps/compatdata/4242/bridgeplay-run.log"
            log.write_text("old\n")
            opened, slept = [], []

            def opener(url):
                opened.append(url)
                n = len(opened)
                capture(bench_dir, 10 + n, 10.0, 30.0)
                run_log(root / "piece.log", [(5.0, 2.0)])
                with open(log, "a") as f:
                    f.write((root / "piece.log").read_text())

            out = root / "out"
            with contextlib.redirect_stdout(io.StringIO()):
                dest = ab.drive("4242", "B", out, 2, 30, 60, steam, [support],
                                opener=opener, sleep=slept.append, clock=lambda: 0.0)
            self.assertEqual(opened, ["steam://rungameid/4242"] * 2)
            self.assertEqual(sorted(p.name for p in dest.glob("*.csv")),
                             ["20261127T101100Z-100.csv", "20261127T101200Z-100.csv"])
            logs = sorted(dest.glob("*.log"))
            self.assertEqual(len(logs), 2)
            self.assertNotIn("old", logs[0].read_text())
            self.assertIn(30, slept)  # cooldown between runs
            self.assertEqual(len(ab.log_runs(logs)), 2)

    def test_drive_times_out(self):
        with tempfile.TemporaryDirectory() as tmp:
            steam = Path(tmp) / "Steam"
            (steam / "steamapps/compatdata/7").mkdir(parents=True)
            (steam / "steamapps/appmanifest_7.acf").write_text("")
            ticks = iter(range(0, 1000, 50))
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(TimeoutError):
                ab.drive("7", "A", Path(tmp) / "out", 1, 0, 100, steam, [Path(tmp) / "support"],
                         opener=lambda url: None, sleep=lambda s: None, clock=lambda: next(ticks))


if __name__ == "__main__":
    unittest.main(verbosity=1)
