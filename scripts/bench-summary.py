#!/usr/bin/env python3
"""Summarise a BRIDGEPLAY_BENCH frame-time capture.

Reads the files overlay-shim writes to
~/Library/Application Support/bridgeplay/launchers/<appid>/bench/ and prints the
average frame rate, the 1% and 0.1% lows and frame-time percentiles.

  scripts/bench-summary.py FILE_OR_FOLDER... [--skip SECONDS] [--json]

A folder means its newest capture. Average fps is frames divided by the time they
took. A 1% low is the frame rate over the slowest 1% of frames (their mean frame
time). Percentiles use the nearest rank. Gaps of a second or more (loading, the game
in the background) are left out and counted as pauses, as the overlay does.
"""
import argparse
import json
import math
import sys
from pathlib import Path

PAUSE_MS = 1000.0
STUTTER_MS = 50.0
PERCENTILES = (50, 90, 95, 99, 99.9)


def newest_capture(folder):
    files = sorted(p for p in folder.glob("*.csv") if p.is_file())
    if not files:
        raise ValueError(f"{folder}: no captures")
    return files[-1]


def read_capture(path):
    meta, frames, layers, lost, ended = {}, [], 0, 0, False
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            if line.startswith("#"):
                body = line[1:].strip()
                if body == "layer":
                    layers += 1
                elif body == "end":
                    ended = True
                elif body.startswith("lost="):
                    lost += int(body[5:] or 0)
                elif "=" in body:
                    key, _, value = body.partition("=")
                    meta[key] = value
                elif body.startswith("bridgeplay-bench "):
                    meta["format"] = body.split()[1]
                continue
            try:
                ms = float(line)
            except ValueError:
                continue
            if ms > 0 and math.isfinite(ms):
                frames.append(ms)
    if meta.get("format") != "1":
        raise ValueError(f"{path}: not a bridgeplay-bench 1 capture")
    return meta, frames, layers, lost, ended


def nearest_rank(ordered, p):
    # round first: 99.9 / 100 * 1000 is 999.0000000000001 in floating point
    return ordered[max(0, math.ceil(round(p / 100.0 * len(ordered), 9)) - 1)]


def low_fps(ordered, fraction):
    count = max(1, math.ceil(round(len(ordered) * fraction, 9)))
    worst = ordered[-count:]
    return 1000.0 / (sum(worst) / len(worst))


def summarise(path, skip_s=0.0):
    meta, frames, layers, lost, ended = read_capture(path)
    elapsed, kept, pauses = 0.0, [], 0
    for ms in frames:
        elapsed += ms
        if elapsed <= skip_s * 1000.0:
            continue
        if ms >= PAUSE_MS:
            pauses += 1
        else:
            kept.append(ms)
    if not kept:
        raise ValueError(f"{path}: no frames to summarise")
    ordered = sorted(kept)
    total = sum(kept)
    return {
        "file": str(path),
        "appid": meta.get("appid"),
        "chip": meta.get("chip"),
        "macos": meta.get("macos"),
        "framegen": meta.get("framegen"),
        "fps_limit": meta.get("fps_limit"),
        "frames": len(kept),
        "seconds": round(total / 1000.0, 3),
        "avg_fps": round(len(kept) * 1000.0 / total, 2),
        "low_1_fps": round(low_fps(ordered, 0.01), 2),
        "low_01_fps": round(low_fps(ordered, 0.001), 2),
        "frame_ms": {f"p{p:g}": round(nearest_rank(ordered, p), 3) for p in PERCENTILES},
        "max_ms": round(ordered[-1], 3),
        "stutters": sum(1 for ms in kept if ms > STUTTER_MS),
        "pauses": pauses,
        "window_changes": layers,
        "lost": lost,
        "complete": ended,
    }


def print_text(s):
    print(s["file"])
    head = [f"game {s['appid']}"]
    if s["chip"]:
        head.append(s["chip"])
    if s["macos"]:
        head.append(f"macOS {s['macos']}")
    head.append(f"frame generation {s['framegen'] or 'unknown'}")
    head.append(f"limit {s['fps_limit'] or 'unknown'}")
    print("  " + ", ".join(head))
    notes = []
    if s["pauses"]:
        notes.append(f"{s['pauses']} pause(s) of 1 s or more left out")
    if s["window_changes"]:
        notes.append(f"{s['window_changes']} window change(s)")
    if s["lost"]:
        notes.append(f"{s['lost']} frame(s) not recorded")
    if not s["complete"]:
        notes.append("capture did not close cleanly")
    print(f"  {s['frames']} frames over {s['seconds']:.1f} s" + (f" ({'; '.join(notes)})" if notes else ""))
    print(f"  average     {s['avg_fps']:.1f} fps")
    print(f"  1% low      {s['low_1_fps']:.1f} fps")
    print(f"  0.1% low    {s['low_01_fps']:.1f} fps")
    print("  frame time  " + "  ".join(f"{k} {v:.2f} ms" for k, v in s["frame_ms"].items())
          + f"  max {s['max_ms']:.2f} ms")
    print(f"  stutters    {s['stutters']} frame(s) over {STUTTER_MS:.0f} ms")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Summarise BRIDGEPLAY_BENCH captures.")
    parser.add_argument("paths", nargs="+", type=Path, help="capture file, or a bench folder for its newest")
    parser.add_argument("--skip", type=float, default=0.0, metavar="SECONDS",
                        help="leave out the first SECONDS of frames (loading, a menu)")
    parser.add_argument("--json", action="store_true", help="print JSON")
    args = parser.parse_args(argv)
    results = []
    try:
        for path in args.paths:
            results.append(summarise(newest_capture(path) if path.is_dir() else path, args.skip))
    except (OSError, ValueError) as error:
        print(f"bench-summary: {error}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(results if len(results) > 1 else results[0], indent=2))
    else:
        for i, s in enumerate(results):
            if i:
                print()
            print_text(s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
