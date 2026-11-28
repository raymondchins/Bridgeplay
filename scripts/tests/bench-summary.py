#!/usr/bin/env python3
"""Offline test for scripts/bench-summary.py against a fixed capture.

fixtures/bench-sample.csv: 989 frames of 10 ms, 10 of 40 ms and one of 60 ms, with a
1.5 s pause and a window change in the middle and 2 frames reported lost.
"""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / "fixtures" / "bench-sample.csv"
spec = importlib.util.spec_from_file_location("bridgeplay_bench_summary", HERE.parent / "bench-summary.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BenchSummaryTests(unittest.TestCase):
    def test_fixture_numbers(self):
        s = module.summarise(FIXTURE)
        self.assertEqual(s["frames"], 1000)
        self.assertEqual(s["seconds"], 10.35)
        self.assertEqual(s["avg_fps"], 96.62)  # 1000 frames / 10.35 s
        self.assertEqual(s["low_1_fps"], 23.81)  # slowest 10: 60 + 9 x 40 ms, mean 42 ms
        self.assertEqual(s["low_01_fps"], 16.67)  # slowest 1: 60 ms
        self.assertEqual(s["frame_ms"], {"p50": 10.0, "p90": 10.0, "p95": 10.0, "p99": 40.0, "p99.9": 40.0})
        self.assertEqual(s["max_ms"], 60.0)
        self.assertEqual((s["stutters"], s["pauses"], s["window_changes"], s["lost"]), (1, 1, 1, 2))
        self.assertTrue(s["complete"])
        self.assertEqual((s["appid"], s["framegen"], s["chip"]), ("4242", "forced-off", "Apple M5 Max"))

    def test_skip_leaves_out_the_start(self):
        s = module.summarise(FIXTURE, skip_s=1.0)
        self.assertEqual(s["frames"], 900)  # the first 100 frames of 10 ms are the first second

    def test_folder_reads_newest_and_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "20260101T000000Z-1.csv").write_text("# bridgeplay-bench 1\n# appid=1\n5.000\n")
            (folder / "20261127T100000Z-2.csv").write_text(FIXTURE.read_text())
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(module.main([str(folder), "--json"]), 0)
            self.assertEqual(json.loads(out.getvalue())["appid"], "4242")

    def test_text_output(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(module.main([str(FIXTURE)]), 0)
        text = out.getvalue()
        self.assertIn("average     96.6 fps", text)
        self.assertIn("1% low      23.8 fps", text)
        self.assertIn("p99 40.00 ms", text)

    def test_rejects_other_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            other = Path(tmp) / "x.csv"
            other.write_text("10\n20\n")
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(module.main([str(other)]), 1)
            empty = Path(tmp) / "empty.csv"
            empty.write_text("# bridgeplay-bench 1\n# end\n")
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(module.main([str(empty)]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=1)
