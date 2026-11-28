#!/usr/bin/env python3
"""Regression watch: one GitHub issue per game that ran well on older Bridgeplay builds and does
not run on a newer one. Python standard library only.

It reads the compat export's store (reports/*.ndjson on the compat-data branch) and decides with
the export's own verdict rule: a game regressed when its verdict is `broken_since`
(scripts/compat-export.md). The issue shows the counted Macs per build and the top log
signatures, the same signatures board.md groups by. When the game runs well again on a build at
or after the one it broke on, the issue gets a comment and is closed.

Usage:
  compat-regressions.py DIR [--now ISO] [--issues ISSUES.json] [--apply] [--max-open N]

Without --apply it prints what it would do and changes nothing. --apply needs GITHUB_TOKEN (or
GH_TOKEN) with issues: write. --issues reads the existing issues from a file instead of GitHub.
The issue format and the states are in scripts/compat-regressions.md.
"""
import argparse
import datetime
import importlib.util
import json
import os
import re
import sys
import urllib.error
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ in scripts/
_spec = importlib.util.spec_from_file_location("bridgeplay_compat_export", Path(__file__).with_name("compat-export.py"))
ce = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ce)

LABEL = "regression-watch"
MAX_OPEN = 5  # new issues per run; the rest wait for the next run
LINKS = 6
SIGS = 3
MARKER = re.compile(r"<!-- bridgeplay-regression-watch appid=(\d+) key=(build|steam) since=(\d+) state=(\w+) -->")
STATES = ("regressed", "quiet", "recovered")
API = "https://api.github.com"


# ---- Finding regressions ---------------------------------------------------------------------------
def regressions(store, now):
    """AppID -> the evidence for each game whose verdict is broken_since."""
    by_game = defaultdict(list)
    for r in store.values():
        by_game[r["appid"]].append(r)
    found = {}
    for appid, reports in by_game.items():
        v = ce.verdict(reports, now)
        if v["label"] != "broken_since":
            continue
        # verdict() tries the Bridgeplay build first, then the Steam client build.
        key = "steam" if v["since"].startswith("Steam build") else "build"
        counted = ce.votes(reports, now)
        first, failed = ce.broken_since(counted, key)
        since = first[key]
        per = defaultdict(Counter)
        for r in counted:
            if r.get(key):
                per[r[key]][ce.BUCKET[r["status"]]] += 1
        cutoff = now - datetime.timedelta(days=ce.WINDOW_DAYS)
        failing = sorted((r for r in reports if ce.BUCKET[r["status"]] == "broken" and (r.get(key) or 0) >= since
                          and ce.parse_date(r["date"]) >= cutoff), key=lambda r: -r["n"])
        name = next((r["name"] for r in sorted(reports, key=lambda r: r["date"], reverse=True) if r["name"]), None)
        labels = {r[key]: short(r, key) for r in counted if r.get(key)}
        found[appid] = {
            "appid": appid, "name": name, "key": key, "since": since, "since_label": v["since"],
            "failed": failed, "verdict": v, "per": {b: dict(c) for b, c in sorted(per.items())}, "labels": labels,
            "sigs": Counter(r["sig"] for r in failing if r["sig"]).most_common(SIGS),
            "stacks": Counter(f"{r['engine'] or '?'} · {r['backend'] or 'default'}" for r in failing).most_common(1),
            "links": [r["n"] for r in failing[:LINKS]],
        }
    return found


def short(r, key):
    return f"Steam build {r['steam']}" if key == "steam" else f"{ce.short_version(r['version']) or '?'} ({r['build']})"


def recovery(store, appid, key, since):
    """The newest report that ran well on the build the game broke on or a newer one, sent after
    the first failure there, or None."""
    game = [r for r in store.values() if r["appid"] == appid and (r.get(key) or 0) >= since]
    broke = min((r["date"] for r in game if ce.BUCKET[r["status"]] == "broken"), default="")
    rows = [r for r in game if ce.BUCKET[r["status"]] == "playable" and r["date"] > broke]
    return max(rows, key=lambda r: (r["date"], r["n"])) if rows else None


# ---- Issue text --------------------------------------------------------------------------------------
def marker(appid, key, since, state):
    return f"<!-- bridgeplay-regression-watch appid={appid} key={key} since={since} state={state} -->"


def title_of(g):
    return f"Regression: {g['name'] or 'App ' + str(g['appid'])} did not run since {g['since_label']}"


def body_of(g, now):
    url = f"https://github.com/{ce.REPO}/discussions/"
    what = "Steam client build" if g["key"] == "steam" else "Bridgeplay build"
    lines = [
        marker(g["appid"], g["key"], g["since"], "regressed"),
        f"**{ce.cell(g['name'] or 'Unknown game')}** (AppID [{g['appid']}](https://store.steampowered.com/app/{g['appid']}/))",
        "",
        f"{g['verdict']['answer']} Verdict rule {ce.RULE} (`scripts/compat-export.md`), counted Macs only, "
        f"one vote per Mac.",
        "",
        f"| {what} | Ran well | Had issues | Did not run |",
        "|---|---:|---:|---:|",
    ]
    for b, c in g["per"].items():
        label = ce.cell(g["labels"].get(b, b))
        mark = " ← since" if b == g["since"] else ""
        lines.append(f"| {label}{mark} | {c.get('playable', 0)} | {c.get('issues', 0)} | {c.get('broken', 0)} |")
    lines += ["", f"Top log signatures of the reports that did not run on {ce.cell(g['since_label'])} or newer:", ""]
    for sig, count in g["sigs"]:
        known = ce.KNOWN_STATUS.get(sig)
        lines.append(f"- {count} × `{ce.cell(sig)}`" + (f": {ce.cell(known)}" if known else ""))
    if not g["sigs"]:
        lines.append("- none in the window")
    if g["stacks"]:
        lines.append(f"- Engine · backend: {ce.cell(g['stacks'][0][0])}")
    lines += ["", "Reports: " + (" ".join(f"[#{n}]({url}{n})" for n in g["links"]) or "none in the window"), "",
              f"Kept current by `.github/workflows/compat-regressions.yml` from the compat-data branch "
              f"({now.strftime('%Y-%m-%d')}). It rewrites this text on each run; comment below instead. "
              f"It closes the issue when the game runs well again on {ce.cell(g['since_label'])} or newer."]
    return "\n".join(lines) + "\n"


def set_state(body, state):
    return MARKER.sub(lambda m: marker(m.group(1), m.group(2), m.group(3), state), body, count=1)


# ---- Planning ------------------------------------------------------------------------------------------
def tracked(issues):
    """AppID -> the issue that tracks it: the open one if any, else the newest."""
    out = {}
    for i in issues:
        if "pull_request" in i:
            continue
        m = MARKER.search(i.get("body") or "")
        if not m or m.group(4) not in STATES:
            continue
        i = dict(i, appid=int(m.group(1)), key=m.group(2), since=int(m.group(3)), mark=m.group(4))
        cur = out.get(i["appid"])
        if cur is None or (i["state"] == "open", i["number"]) > (cur["state"] == "open", cur["number"]):
            out[i["appid"]] = i
    return out


def plan(store, issues, now, max_open=MAX_OPEN):
    """The changes to make, in order, and the regressions left for a later run."""
    found = regressions(store, now)
    have = tracked(issues)
    actions, waiting = [], []
    new = sorted((g for a, g in found.items() if a not in have), key=lambda g: (-g["failed"], g["appid"]))
    for g in new:
        if len(actions) < max_open:
            actions.append({"do": "open", "appid": g["appid"], "title": title_of(g), "body": body_of(g, now)})
        else:
            waiting.append(g["appid"])
    for appid, i in sorted(have.items()):
        g = found.get(appid)
        n = i["number"]
        if g:
            title, body = title_of(g), body_of(g, now)
            moved = (i["key"], i["since"]) != (g["key"], g["since"])
            if i["state"] != "open":
                # Closed by hand or after a recovery: only a new break reopens it.
                if moved:
                    actions += [{"do": "reopen", "appid": appid, "number": n, "title": title, "body": body},
                                {"do": "comment", "appid": appid, "number": n,
                                 "body": f"It broke again: {g['verdict']['answer']}"}]
                continue
            if i["mark"] != "regressed" or title != i.get("title") or \
                    body_without_date(body) != body_without_date(i.get("body") or ""):
                actions.append({"do": "edit", "appid": appid, "number": n, "title": title, "body": body})
            if moved:
                actions.append({"do": "comment", "appid": appid, "number": n,
                                "body": f"The break moved: {g['verdict']['answer']}"})
            elif i["mark"] == "quiet":
                actions.append({"do": "comment", "appid": appid, "number": n,
                                "body": f"It meets the rule again: {g['verdict']['answer']}"})
            continue
        if i["state"] != "open":
            continue
        ok = recovery(store, appid, i["key"], i["since"])
        if ok:
            where = short(ok, i["key"])
            actions += [{"do": "comment", "appid": appid, "number": n,
                         "body": f"Ran well again on {where}: [#{ok['n']}](https://github.com/{ce.REPO}/discussions/{ok['n']}). "
                                 "Closing; a new break reopens this issue."},
                        {"do": "close", "appid": appid, "number": n, "body": set_state(i.get("body") or "", "recovered")}]
        elif i["mark"] == "regressed":
            reports = [r for r in store.values() if r["appid"] == appid]
            if not reports:
                continue  # the reports were deleted; leave the issue as it is
            answer = ce.verdict(reports, now)["answer"]
            actions += [{"do": "comment", "appid": appid, "number": n,
                         "body": f"No longer meets the regression rule, but no Mac has reported it running well on "
                                 f"this build or a newer one yet. Verdict now: {answer}"},
                        {"do": "edit", "appid": appid, "number": n, "title": i.get("title"),
                         "body": set_state(i.get("body") or "", "quiet")}]
    for a in actions:
        if "title" in a and a["title"]:
            ce.check_private(f"issue for {a['appid']}", a["title"])
        ce.check_private(f"issue for {a['appid']}", a["body"])
    return actions, waiting


def body_without_date(body):
    return re.sub(r"from the compat-data branch \(\d{4}-\d{2}-\d{2}\)", "", body)


# ---- GitHub ----------------------------------------------------------------------------------------------
def rest(token, method, path, data=None):
    req = urllib.request.Request(API + path, method=method, data=None if data is None else json.dumps(data).encode(),
                                 headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                                          "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "bridgeplay-compat-regressions",
                                          "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        text = r.read().decode("utf-8")
    return json.loads(text) if text else None


def github_issues(token):
    out, page = [], 1
    while True:
        rows = rest(token, "GET", f"/repos/{ce.REPO}/issues?labels={LABEL}&state=all&per_page=100&page={page}")
        out += rows
        if len(rows) < 100:
            return out
        page += 1


def ensure_label(token):
    try:
        rest(token, "POST", f"/repos/{ce.REPO}/labels",
             {"name": LABEL, "color": "b60205", "description": "A game stopped running on a newer build (compat-regressions.yml)"})
    except urllib.error.HTTPError as e:
        if e.code != 422:  # 422: it exists
            raise


def apply(token, actions):
    if any(a["do"] == "open" for a in actions):
        ensure_label(token)
    repo = f"/repos/{ce.REPO}/issues"
    for a in actions:
        if a["do"] == "open":
            made = rest(token, "POST", repo, {"title": a["title"], "body": a["body"], "labels": [LABEL]})
            a["number"] = made["number"]
        elif a["do"] == "edit":
            rest(token, "PATCH", f"{repo}/{a['number']}", {"title": a["title"], "body": a["body"]})
        elif a["do"] == "reopen":
            rest(token, "PATCH", f"{repo}/{a['number']}", {"state": "open", "title": a["title"], "body": a["body"]})
        elif a["do"] == "close":
            rest(token, "PATCH", f"{repo}/{a['number']}", {"state": "closed", "state_reason": "completed", "body": a["body"]})
        elif a["do"] == "comment":
            rest(token, "POST", f"{repo}/{a['number']}/comments", {"body": a["body"]})


def describe(a):
    where = f"#{a['number']}" if a.get("number") else "new issue"
    return f"{a['do']:<7} {where:<10} AppID {a['appid']}" + (f": {a['title']}" if a["do"] in ("open", "reopen") else "")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dir", type=Path, help="the compat export folder (reports/*.ndjson)")
    ap.add_argument("--now", help="ISO 8601 UTC (default: now)")
    ap.add_argument("--issues", help="the existing issues as JSON instead of GitHub")
    ap.add_argument("--apply", action="store_true", help="make the changes on GitHub")
    ap.add_argument("--max-open", type=int, default=MAX_OPEN, help="new issues per run")
    args = ap.parse_args(argv)
    now = ce.parse_date(args.now) if args.now else datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    store = ce.load_store(args.dir)
    if not store:
        raise SystemExit("compat-regressions: no reports in the store")
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if args.apply and not token:
        raise SystemExit("compat-regressions: --apply needs GITHUB_TOKEN")
    if args.issues:
        issues = json.loads(Path(args.issues).read_text(encoding="utf-8"))
    elif token:
        issues = github_issues(token)
    else:
        raise SystemExit("compat-regressions: set GITHUB_TOKEN, or pass --issues ISSUES.json")
    actions, waiting = plan(store, issues, now, args.max_open)
    for a in actions:
        print(describe(a))
    if waiting:
        print(f"waiting  {len(waiting)} more regressions over --max-open {args.max_open}: "
              + ", ".join(map(str, waiting)))
    if not actions:
        print("no changes")
    if args.apply:
        apply(token, actions)
        print(f"compat-regressions: {len(actions)} changes made")
    elif actions:
        print("compat-regressions: dry run, nothing changed (--apply to make these changes)")
    return actions, waiting


if __name__ == "__main__":
    main()
