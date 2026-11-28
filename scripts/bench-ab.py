#!/usr/bin/env python3
"""Compare two settings or backends (A and B) for one game from repeated runs.

  scripts/bench-ab.py compare A_PATH... --vs B_PATH... [--warmup 1] [--min-runs 3]
                      [--skip 10] [--min-effect 1] [--json]
  scripts/bench-ab.py run --appid ID --label A --out DIR --runs 3 --launch-steam

compare reads BRIDGEPLAY_BENCH captures (.csv, see scripts/bench-summary.py) and run logs
(bridgeplay-run.log or the .log pieces `run` saves, for the D2 `time:` lines). A folder means
every .csv and .log in it. Captures that overlap in time are one launch (the shim writes one
file per Wine process); the one with most frames counts. Per side the first --warmup runs are
left out (shader compiles), and --skip seconds of each capture.

The check is a bootstrap over runs, not frames: each side's runs are resampled, the change in
the median is taken 5000 times, and a change counts only when its 95% interval leaves out
zero and the median moved by at least --min-effect percent.

run never starts Steam without --launch-steam. With it, each run opens
steam://rungameid/ID and waits until the run log says the game exited (quit it, or let its
benchmark end), then copies the new captures and the run's log into DIR/LABEL. Set the
game's launch options for this side by hand first, with BRIDGEPLAY_BENCH=1; run only reads
Steam's files. For ABAB order, call it with --runs 1 and alternate the labels.
"""
import argparse
import datetime
import importlib.util
import json
import random
import re
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("bridgeplay_bench_summary", HERE / "bench-summary.py")
bench = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bench)

RESAMPLES = 5000
SEED = 20261127
OVERLAP_SLACK_S = 5.0

# key, label, unit, higher is better
FRAME_METRICS = (
    ("frame_ms_p50", "median frame time", "ms", False),
    ("low_1_fps", "1% low", "fps", True),
    ("avg_fps", "average", "fps", True),
)
LAUNCH_METRICS = (
    ("game_start_s", "to game start", "s", False),
    ("first_frame_s", "to first frame", "s", False),
)


# --- inputs ---------------------------------------------------------------

def expand(paths):
    captures, logs = [], []
    for p in paths:
        p = Path(p)
        if p.is_dir():
            captures += sorted(x for x in p.glob("*.csv") if x.is_file())
            logs += sorted(x for x in p.glob("*.log") if x.is_file())
        elif p.suffix == ".log":
            logs.append(p)
        elif p.is_file():
            captures.append(p)
        else:
            raise ValueError(f"{p}: not found")
    return captures, logs


def capture_span(path):
    meta, frames, _, _, _ = bench.read_capture(path)
    try:
        start = datetime.datetime.strptime(meta.get("started", ""), "%Y-%m-%dT%H:%M:%SZ")
        start = start.replace(tzinfo=datetime.timezone.utc).timestamp()
    except ValueError:
        raise ValueError(f"{path}: no started= time in the header")
    return start, start + sum(frames) / 1000.0, len(frames), meta


def capture_runs(paths, skip_s):
    """One summary per launch, oldest first."""
    spans = sorted((capture_span(p) + (p,) for p in paths), key=lambda s: s[0])
    groups = []
    for start, end, count, meta, path in spans:
        if groups and start <= groups[-1]["end"] + OVERLAP_SLACK_S:
            g = groups[-1]
            g["end"] = max(g["end"], end)
            if count > g["count"]:
                g.update(count=count, path=path)
        else:
            groups.append({"end": end, "count": count, "path": path})
    runs = []
    for g in groups:
        s = bench.summarise(g["path"], skip_s)
        s["frame_ms_p50"] = s["frame_ms"]["p50"]
        runs.append(s)
    return runs


TIME_AT = re.compile(r"^time: (.+?) at ([0-9]+(?:\.[0-9]+)?)s$")
TIME_AFTER = re.compile(r"^time: first (window|frame) ([0-9]+(?:\.[0-9]+)?)s after the game started$")


def log_runs(paths):
    """Launch timings from run logs: one per section that reached the game start."""
    runs = []
    for path in paths:
        section = None
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines() + ["=== end"]
        for line in lines:
            if line.startswith("=== bridgeplay run ") or line == "=== end":
                if section and "game_start_s" in section:
                    runs.append(section)
                section = {"file": str(path)}
                continue
            if section is None:
                continue
            m = TIME_AT.match(line)
            if m and m.group(1) == "game start":
                section["game_start_s"] = float(m.group(2))
                continue
            m = TIME_AFTER.match(line)
            if m and "game_start_s" in section:
                section[f"first_{m.group(1)}_s"] = round(section["game_start_s"] + float(m.group(2)), 3)
    return runs


# --- statistics -----------------------------------------------------------

def bootstrap_change(a, b, rng):
    """Change of the median from a to b in percent, with a 95% bootstrap interval."""
    base = statistics.median(a)
    if base == 0:
        return None
    point = (statistics.median(b) - base) / base * 100.0
    diffs = []
    for _ in range(RESAMPLES):
        ra = statistics.median(rng.choices(a, k=len(a)))
        rb = statistics.median(rng.choices(b, k=len(b)))
        if ra:
            diffs.append((rb - ra) / ra * 100.0)
    diffs.sort()
    lo = diffs[int(0.025 * (len(diffs) - 1))]
    hi = diffs[int(0.975 * (len(diffs) - 1))]
    return point, lo, hi


def compare_metric(key, label, unit, higher_better, a_runs, b_runs, min_effect, rng, min_runs=1):
    a = [r[key] for r in a_runs if r.get(key) is not None]
    b = [r[key] for r in b_runs if r.get(key) is not None]
    row = {"metric": key, "label": label, "unit": unit, "a_runs": len(a), "b_runs": len(b)}
    if not a or not b:
        row["verdict"] = "no data"
        return row
    # Optional values (first frame) can leave fewer runs than the records counted.
    if len(a) < min_runs or len(b) < min_runs:
        row["verdict"] = "too few runs"
        return row
    row["a_median"], row["b_median"] = statistics.median(a), statistics.median(b)
    change = bootstrap_change(a, b, rng)
    if change is None:
        row["verdict"] = "no data"
        return row
    point, lo, hi = change
    row.update(change_pct=round(point, 2), ci_low=round(lo, 2), ci_high=round(hi, 2))
    clear = (lo > 0 or hi < 0) and abs(point) >= min_effect
    if not clear:
        row["verdict"] = "same"
    else:
        row["verdict"] = "B better" if (point > 0) == higher_better else "A better"
    return row


def overall(rows):
    frame = {r["metric"]: r["verdict"] for r in rows}
    core = [frame.get("frame_ms_p50"), frame.get("low_1_fps")]
    wins = {v for v in core if v in ("A better", "B better")}
    if not wins:
        return "no measurable difference in frame time or 1% lows"
    if len(wins) == 2:
        return "mixed: one side has the faster median, the other the better 1% lows"
    side = wins.pop()[0]
    return f"{side} is faster"


def warnings_for(a_frames, b_frames):
    out = []
    for key, what in (("appid", "game"), ("chip", "chip"), ("macos", "macOS"), ("fps_limit", "frame rate limit")):
        va = {r.get(key) for r in a_frames}
        vb = {r.get(key) for r in b_frames}
        if va and vb and va != vb:
            out.append(f"{what} differs: A {', '.join(map(str, sorted(va, key=str)))}, "
                       f"B {', '.join(map(str, sorted(vb, key=str)))}")
    for side, runs in (("A", a_frames), ("B", b_frames)):
        if any(r.get("framegen") not in ("forced-off", "off", None) for r in runs):
            out.append(f"{side}: frame generation was not off in every run")
        if any(r.get("lost") for r in runs):
            out.append(f"{side}: some frames were not recorded")
        if any(not r.get("complete") for r in runs):
            out.append(f"{side}: a capture did not close cleanly")
    return out


def compare(a_paths, b_paths, warmup=1, min_runs=3, skip_s=10.0, min_effect=1.0, seed=SEED):
    sides = {}
    for name, paths in (("A", a_paths), ("B", b_paths)):
        captures, logs = expand(paths)
        frames, launches = capture_runs(captures, skip_s), log_runs(logs)
        sides[name] = {"frames_all": len(frames), "launches_all": len(launches),
                       "frames": frames[warmup:], "launches": launches[warmup:]}
    a, b = sides["A"], sides["B"]
    result = {"warmup": warmup, "min_runs": min_runs, "skip_s": skip_s, "min_effect_pct": min_effect,
              "runs": {s: {"captures": sides[s]["frames_all"], "logs": sides[s]["launches_all"],
                           "used_captures": len(sides[s]["frames"]),
                           "used_logs": len(sides[s]["launches"])} for s in sides},
              "rows": [], "warnings": warnings_for(a["frames"], b["frames"])}
    short = [s for s in sides if len(sides[s]["frames"]) < min_runs]
    if not a["frames_all"] and not b["frames_all"]:
        short = []  # launch timings only
        if len(a["launches"]) < min_runs or len(b["launches"]) < min_runs:
            short = ["A", "B"]
    if short:
        result["verdict"] = (f"not enough runs: need {min_runs} per side after {warmup} warm-up run(s); "
                             + ", ".join(f"{s} has {len(sides[s]['frames']) or len(sides[s]['launches'])}"
                                         for s in sides))
        result["enough"] = False
        return result
    rng = random.Random(seed)
    for metrics, key in ((FRAME_METRICS, "frames"), (LAUNCH_METRICS, "launches")):
        if len(a[key]) >= min_runs and len(b[key]) >= min_runs:
            for m in metrics:
                result["rows"].append(compare_metric(*m, a[key], b[key], min_effect, rng, min_runs))
    result["verdict"] = overall(result["rows"]) if a["frames"] else "launch times only"
    result["enough"] = True
    return result


def print_text(r):
    runs = r["runs"]
    print(f"A: {runs['A']['used_captures']} run(s), B: {runs['B']['used_captures']} run(s) "
          f"after {r['warmup']} warm-up run(s) each; first {r['skip_s']:g} s of each capture left out")
    if runs["A"]["used_logs"] or runs["B"]["used_logs"]:
        print(f"launch logs: A {runs['A']['used_logs']}, B {runs['B']['used_logs']}")
    for row in r["rows"]:
        if row["verdict"] == "no data":
            print(f"  {row['label']:<18} no data")
            continue
        if row["verdict"] == "too few runs":
            print(f"  {row['label']:<18} too few runs (A {row['a_runs']}, B {row['b_runs']})")
            continue
        print(f"  {row['label']:<18} A {row['a_median']:.2f} {row['unit']}  B {row['b_median']:.2f} {row['unit']}  "
              f"{row['change_pct']:+.1f}% [{row['ci_low']:+.1f}, {row['ci_high']:+.1f}]  {row['verdict']}")
    for w in r["warnings"]:
        print(f"  warning: {w}")
    print(f"verdict: {r['verdict']}")


# --- run: drive launches through Steam --------------------------------------

STEAM_ROOT = Path.home() / "Library/Application Support/Steam"
SUPPORT_DIRS = [Path.home() / "Library/Application Support/bridgeplay",
                Path.home() / "Library/Application Support/notproton"]


def libraries(steam_root):
    found = [steam_root / "steamapps"]
    for index in (steam_root / "steamapps/libraryfolders.vdf", steam_root / "config/libraryfolders.vdf"):
        if index.is_file():
            text = index.read_text(encoding="utf-8", errors="replace")
            for raw in re.findall(r'^\s*"path"\s+"((?:\\.|[^"\\])*)"', text, re.M):
                found.append(Path(re.sub(r'\\(["\\])', r"\1", raw)) / "steamapps")
    return list(dict.fromkeys(found))


def run_log_for(appid, steam_root):
    for steamapps in libraries(steam_root):
        if (steamapps / f"appmanifest_{appid}.acf").is_file():
            return steamapps / "compatdata" / appid / "bridgeplay-run.log"
    raise ValueError(f"game {appid} is not installed in any Steam library under {steam_root}")


def bench_dir_for(appid, support_dirs):
    for support in support_dirs:
        if (support / "launchers").is_dir():
            return support / "launchers" / appid / "bench"
    return support_dirs[0] / "launchers" / appid / "bench"


def read_from(path, offset, head=b""):
    """The log from offset on, and the offset for the next read. The run script empties a log
    over 256 KB: a log that got shorter, or no longer starts with head, is read from 0, and 0
    is kept so the new run's start stays in what is read."""
    try:
        size = path.stat().st_size
    except OSError:
        return "", offset
    with open(path, "rb") as f:
        if size < offset or (offset and head and f.read(len(head)) != head):
            offset = 0
        f.seek(offset)
        return f.read().decode("utf-8", errors="replace"), offset


def drive(appid, label, out, runs, cooldown, timeout, steam_root, support_dirs,
          opener=None, sleep=time.sleep, clock=time.monotonic, say=print):
    if opener is None:
        def opener(url):
            subprocess.run(["/usr/bin/open", url], check=True)
    log = run_log_for(appid, steam_root)
    bench_dir = bench_dir_for(appid, support_dirs)
    dest = out / label
    dest.mkdir(parents=True, exist_ok=True)
    say(f"game {appid}, side {label}: {runs} run(s) into {dest}")
    say("its launch options must already hold this side's settings and BRIDGEPLAY_BENCH=1")
    for n in range(1, runs + 1):
        offset = log.stat().st_size if log.exists() else 0
        head = b""
        if offset:
            with open(log, "rb") as f:
                head = f.read(min(offset, 512))
        before = set(bench_dir.glob("*.csv")) if bench_dir.is_dir() else set()
        say(f"run {n}/{runs}: opening steam://rungameid/{appid}; quit the game when the test is done")
        opener(f"steam://rungameid/{appid}")
        deadline = clock() + timeout
        text = ""
        while True:
            text, offset = read_from(log, offset, head)
            if "\ntime: game exited at " in "\n" + text:
                break
            if clock() > deadline:
                raise TimeoutError(f"run {n}: no 'game exited' line in {log} after {timeout:g} s")
            sleep(2)
        sleep(2)  # the shim flushes once a second
        # The first window and frame times are written after "game exited": read them too.
        text, offset = read_from(log, offset, head)
        new = sorted(set(bench_dir.glob("*.csv")) - before) if bench_dir.is_dir() else []
        if not new:
            raise ValueError(f"run {n}: no new capture in {bench_dir}; is BRIDGEPLAY_BENCH=1 in the launch options?")
        for c in new:
            shutil.copy2(c, dest / c.name)
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        (dest / f"{stamp}-run{n}.log").write_text(text, encoding="utf-8")
        say(f"run {n}/{runs}: {len(new)} capture(s) saved")
        if n < runs and cooldown > 0:
            say(f"cooling down {cooldown:g} s")
            sleep(cooldown)
    return dest


# --- command line -----------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(description="Compare two settings for one game from repeated runs.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("compare", help="compare A runs with B runs")
    c.add_argument("a", nargs="+", type=Path, help="side A: captures, run logs or folders")
    c.add_argument("--vs", nargs="+", type=Path, required=True, metavar="B", help="side B: the same")
    c.add_argument("--warmup", type=int, default=1, help="runs left out at the start of each side (1)")
    c.add_argument("--min-runs", type=int, default=3, help="runs needed per side after warm-up (3)")
    c.add_argument("--skip", type=float, default=10.0, metavar="SECONDS",
                   help="seconds left out at the start of each capture (10)")
    c.add_argument("--min-effect", type=float, default=1.0, metavar="PERCENT",
                   help="smallest change of the median that counts (1)")
    c.add_argument("--json", action="store_true", help="print JSON")
    r = sub.add_parser("run", help="launch the game through Steam N times and collect its files")
    r.add_argument("--appid", required=True)
    r.add_argument("--label", required=True, help="side name, e.g. A or B")
    r.add_argument("--out", required=True, type=Path, help="folder for the collected runs")
    r.add_argument("--runs", type=int, default=3)
    r.add_argument("--cooldown", type=float, default=30.0, metavar="SECONDS")
    r.add_argument("--timeout", type=float, default=1800.0, metavar="SECONDS", help="per run")
    r.add_argument("--steam-root", type=Path, default=STEAM_ROOT)
    r.add_argument("--launch-steam", action="store_true", help="really open Steam; nothing runs without it")
    args = parser.parse_args(argv)

    if args.cmd == "compare":
        if args.warmup < 0 or args.min_runs < 2:
            print("bench-ab: --warmup must be 0 or more and --min-runs 2 or more", file=sys.stderr)
            return 1
        try:
            result = compare(args.a, args.vs, args.warmup, args.min_runs, args.skip, args.min_effect)
        except (OSError, ValueError) as error:
            print(f"bench-ab: {error}", file=sys.stderr)
            return 1
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            print_text(result)
        return 0 if result["enough"] else 2

    if not re.fullmatch(r"[0-9]+", args.appid) or not re.fullmatch(r"[A-Za-z0-9._-]+", args.label) or args.runs < 1:
        print("bench-ab: --appid must be digits, --label letters, digits . _ - and --runs 1 or more", file=sys.stderr)
        return 1
    if not args.launch_steam:
        print(f"bench-ab: would open steam://rungameid/{args.appid} {args.runs} time(s) and save the runs "
              f"in {args.out / args.label}; add --launch-steam to do it", file=sys.stderr)
        return 2
    try:
        drive(args.appid, args.label, args.out, args.runs, args.cooldown, args.timeout,
              args.steam_root, SUPPORT_DIRS)
    except (OSError, ValueError, TimeoutError, subprocess.CalledProcessError) as error:
        print(f"bench-ab: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
