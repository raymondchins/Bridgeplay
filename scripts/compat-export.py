#!/usr/bin/env python3
"""Static export of the compatibility reports, with the verdict rule, the signature board and
the open-data files. Python standard library only.

Players' reports live as GitHub Discussions in the compatibility-reports category, posted by the
report bot (bridgeplay-web api/report.mjs). `fetch` keeps a field-only copy of each report;
`build` turns that copy into the published files:

  reports/YYYY-MM.ndjson  one line per report: fields only, no logs, nothing about the person
  compat.json             the shape bridgeplay.dev's /api/compat returns, plus a verdict per game
  compat-index.json       AppID -> verdict, counts, newest build and date, for the app; with
                          --anticheat, also AppID -> anti-cheat ids from AreWeAntiCheatYet
  board.md                failing reports grouped by log signature, for maintainers
  README.md, LICENSE      the open-data notes, copied from compat/data/

Usage:
  compat-export.py fetch DIR [--full] [--prune] [--force] [--from NODES.json]
  compat-export.py build DIR [--now 2026-11-27T12:00:00Z] [--anticheat AWACY-games.json]

fetch reads GitHub with GH_TOKEN (discussions: read) unless --from gives the Discussion nodes as
JSON. The verdict rule and the file formats are in scripts/compat-export.md.
"""
import argparse
import datetime
import ipaddress
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA_DOCS = ROOT / "compat" / "data"
REPO = os.environ.get("GITHUB_REPOSITORY") or "raymondchins/Bridgeplay"
CATEGORY = "compatibility-reports"
# The report bot, and the owner's login that posted the reports made before the GitHub App
# (api/_lib/github.mjs LEGACY_AUTHOR). Anything else in the category is not counted.
AUTHORS = os.environ.get("BRIDGEPLAY_REPORT_AUTHORS") or "bridgeplay-reports[bot],raymondchins"
API = "https://api.github.com/graphql"
PAGE = 100

# Must match BUCKET and ISSUES in bridgeplay-web api/_lib/github.mjs.
BUCKET = {"platinum": "playable", "gold": "playable", "silver": "playable", "bronze": "issues", "borked": "broken"}
ISSUES = ["performance", "crash", "graphics", "sound", "controls", "launcher"]
BACKENDS = ["dxmt", "dxvk", "wined3d", "d3dmetal"]
SOURCES = ["tap", "auto"]
THERMAL = ["nominal", "fair", "serious", "critical"]
LATEST = 20
NOTE_SHORT = 140
SHORTCUT = 2 ** 31

# ---- The verdict rule (scripts/compat-export.md) ------------------------------------------------
RULE = 1
WINDOW_DAYS = 120    # reports older than this don't count, unless a game has nothing newer
MIN_REPORTS = 2      # fewer counted Macs than this reads "1 report"
SHARE = (3, 5)       # Playable / Doesn't run need this share of the counted Macs (3/5 = 60%)
BROKEN_MIN = 2       # Macs that must fail on a newer build for "Broken since"
BOARD_DAYS = 30      # the signature board looks at this many days of failing reports
BOARD_GAMES_MIN = 8  # "fails most" lists games with at least this many reports...
BOARD_FAIL = (3, 5)  # ...that did not run or had issues at least this often (60%)

# Gamefix keys a report may carry (docs/GAMEFIXES.md). ARGS is left out: it can hold anything.
GAMEFIX_KEYS = {
    "BACKEND", "ROSETTA_ADVERTISE_AVX", "DLLOVERRIDES", "MSYNC", "RETINA", "FRAMEGEN", "FRAMEGEN_QUALITY",
    "FRAMEGEN_UI", "FRAMEGEN_FALLBACK", "FRAMEGEN_ENGINE", "FPS_LIMIT", "FPS_LIMIT_OFF", "SCALING_FILTER",
    "PERF_OVERLAY", "NVAPI", "DLSS_FG", "STDOUT_NULL", "VSYNC", "GAME_MODE", "HIDE_WINE_EXPORTS",
    "STEAMDECK", "ROCKSTAR_SHIM", "MTL_HUD_ENABLED", "WINEDEBUG", "WINE_LARGE_ADDRESS_AWARE",
    "WINE_CPU_TOPOLOGY", "CX_FWD_COMPAT_GL_CTX",
}
GAMEFIX_PREFIXES = ("DXMT_", "DXVK_", "MVK_", "VKD3D_", "D3DM_", "STAGING_")

# (regex over the report, signature, what is known). First match wins. Started from the
# maintainers' skim table; add a row when a cause is understood.
KNOWN = [
    (r"compatdata on exfat|compatdata on msdos|Cannot set the dir to C:\\\\windows", "exfat-prefix",
     "unfixable: the library is on exFAT or FAT; move it to APFS (0.7.36 refuses the broken prefix)"),
    (r"steam2ea://", "ea-app", "no fix: the EA app starts, the game never launches"),
    (r"EasyAntiCheat|BattlEye|anti-?cheat|xigncode|nProtect|GameGuard|vanguard|ACE-BASE|AntiCheatExpert",
     "anti-cheat", "unfixable: anti-cheat that Wine on macOS cannot run"),
    (r"InstallerMessage\.Form1.*CodecCheck|Windows\.Foundation\.UniversalApiContract", "capcom-codec-check",
     "known: Capcom's codec check needs WinRT contracts wine-mono lacks (Wine bug 53023); the game may still start"),
    (r"error=112|No space left on device", "disk-full-prefix",
     "known: the disk filled while Wine built the prefix; 0.7.66+ refuses and rebuilds"),
    (r"Could not load file or assembly 'CEF3", "assetto-cef3-launcher",
     "known: Assetto Corsa's .NET launcher needs CEF3 under wine-mono (Wine bug 58033)"),
    (r"start_protected_game\.exe", "eac-bootstrapper", "unfixable: Easy Anti-Cheat bootstrapper"),
    (r"d3d10\.D3D10CreateEffectFromMemory", "d3d10-effects-forward",
     "known: d3d10_1 forwards to D3D10 effects exports Apple's d3d10 lacks; try DXMT"),
    (r"ci\.dll|Randgrid\.sys", "cod-ricochet", "unfixable: Ricochet kernel anti-cheat"),
    (r"STEAM_COMPAT_APP_ID=0\b|SteamRIP", "non-steam-copy", "not supported"),
    (r"processpipe_any|OpenFileMapping returned NULL|Steam is not running", "32bit-steam-pipe",
     "fixed 0.7.38 on WineCX 11.17; an old 11.15 prefix needs the engine switch and a rebuild"),
    (r"tier0_s\.dll|vstdlib_s\.dll", "32bit-steamclient-dlls", "fixed 0.7.32"),
    (r"different Team IDs", "winehq-teamid", "fixed 0.7.37"),
    (r"could not load kernel32\.dll", "broken-prefix", "0.7.36+ alert: exFAT, a full disk, else rebuild"),
    (r"D3DX11CreateThreadPump", "d3dx11-threadpump", "open: Wine bug 56176"),
]
KNOWN_STATUS = {sig: status for _, sig, status in KNOWN}
NO_CRASH = "no-crash-line"
CRASH = re.compile(r"Unhandled|unimplemented function|Assertion|could not load|err:module|page fault|"
                   r"EXCEPTION_|fatal|status=(?!0\b|143\b)\d+", re.I)
NOISE = re.compile(
    r"err:ntoskrnl:ZwLoadDriver failed to create driver .*winebth|err:setupapi:SetupDiInstallDevice Failed to start service .*winebth|"
    r"err:ole:StdMarshalImpl_MarshalInterface Failed to create ifstub|err:ole:CoMarshalInterface Failed to marshal the interface|"
    r"err:ole:apartment_get_local_server_stream Failed|err:setupapi:SetupDefaultQueueCallbackW copy error 1812.*wineusb|"
    r"err:setupapi:do_file_copyW Unsupported style|err:kerberos:kerberos_LsaApInitializePackage no Kerberos support|"
    r"err:menubuilder:|err:richedit:|code object is not signed|err:kerberos|winebth|mvk-|VK_|regsvr32", re.I)
# "Has issues" about speed rather than a bug (api/compat.mjs SLOW).
SLOW = re.compile(r"\b(lag|laggy|fps|frame ?rate|stutter\w*|slow|jitter\w*|choppy|framedrops?)\b", re.I)

# ---- Privacy -------------------------------------------------------------------------------------
# Applied to every free-text field kept (game name, engine, note, signature). api/report.mjs
# already redacts logs; this repeats it and goes further for the note.
SCRUB = [
    (re.compile(r"/Volumes/(?!Preboot/|Macintosh HD/)[^/\n:]+"), "/Volumes/<drive>"),
    (re.compile(r"(?<![A-Za-z]:)/Users/(?!Shared(?=[/\s:'\"]|$))[^/\s:'\"]+"), "~"),
    (re.compile(r"\b([A-Za-z]:\\+Users\\+)(?!(?:crossover|public|steamuser)\b)[^\\\s:'\"]+", re.I), r"\1<user>"),
    (re.compile(r"https?://\S+|www\.\S+", re.I), "<link>"),
    (re.compile(r"[\w.+-]{1,64}@[\w-]{1,63}(\.[\w-]{1,63})+"), "<email>"),
    (re.compile(r"\b7656119\d{10}\b"), "<steamid>"),
    (re.compile(r"\[U:1:\d+\]"), "[U:1:<redacted>]"),
    (re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I), "<id>"),
    # Compressed IPv6 ("2001:db8::1", "::1", "fe80::1%en0"): first, so the rules below don't split it; any run with "::" that parses as one.
    (re.compile(r"(?<![\w:])[0-9a-f:]*::[0-9a-f:.]*(?:%\w+)?(?![\w:])", re.I),
     lambda m: "<ip>" if _is_ipv6(m.group(0)) else m.group(0)),
    (re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"), "<ip>"),
    (re.compile(r"\b(?:[0-9a-f]{1,4}:){4,7}[0-9a-f]{1,4}\b", re.I), "<ip>"),
    (re.compile(r"@[\w-]+"), "<name>"),
]
def _is_ipv6(token):
    try:
        ipaddress.IPv6Address(token.split("%", 1)[0])
        return True
    except ValueError:
        return False


# Nothing in a published file may match these; build stops instead of writing it.
PRIVATE = re.compile(
    r"[\w.+-]+@[\w-]+\.[\w.-]*[A-Za-z]|\b7656119\d{10}\b|\[U:1:\d+\]|/Users/(?!Shared\b)\w"
    r"|\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b|\b(?:\d{1,3}\.){3}\d{1,3}\b", re.I)


# Long digit runs in a player's note: phone numbers, account numbers.
NOTE_NUMBER = re.compile(r"\+?\d[\d ()-]{9,}\d")


def scrub(text, limit, note=False):
    if not isinstance(text, str):
        return None
    # api/report.mjs put a zero-width space after every @, which would hide an email address.
    text = re.sub(r"[\u0000-\u001f\u007f]", " ", text).replace("\u200b", "").replace("&lt;", "<").replace("&gt;", ">")
    for pattern, repl in SCRUB:
        text = pattern.sub(repl, text)
    if note:
        text = NOTE_NUMBER.sub("<number>", text)
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > limit:
        text = text[:limit - 1].rstrip() + "…"
    return text or None


def chip_family(chip):
    chip = (chip or "").strip()
    return chip if re.fullmatch(r"[AM][1-9]\d{0,2}(?: (?:Pro|Max|Ultra))?", chip) else ("Other" if chip else None)


def memory_size(memory):
    memory = (memory or "").strip()
    return memory if re.fullmatch(r"\d{1,4} GB", memory) else ("Other" if memory else None)


def macos_minor(macos):
    """'macOS 26.1.2' -> 'macOS 26.1'; the patch level narrows a Mac down for no gain."""
    m = re.match(r"(macOS )?(\d{2})\.(\d{1,2})", (macos or "").strip())
    if not m:
        m = re.match(r"(macOS )?(\d{2})\b", (macos or "").strip())
        return f"{m.group(1) or ''}{m.group(2)}" if m else None
    return f"{m.group(1) or ''}{m.group(2)}.{m.group(3)}"


VERSION = re.compile(r"(\d{1,3}\.\d{1,3}\.\d{1,4}(?:[-+][0-9A-Za-z.]{1,20})?)(?: \((\d{1,6})\))?")


def version_of(version):
    m = VERSION.fullmatch((version or "").strip())
    return (m.group(0), int(m.group(2)) if m.group(2) else 0) if m else (None, 0)


def short_version(version):
    return re.sub(r" \(\d+\)$", "", version or "") or None


def engine_name(engine):
    """The engine's name and version; a path after it ("… at /Users/…") is dropped."""
    if not isinstance(engine, str):
        return None
    text = scrub(re.split(r" at (?:[/~]|[A-Za-z]:\\)", engine)[0], 80) or ""
    text = re.split(r"[/\\~]", text)[0].strip()
    return text if re.fullmatch(r"[\w .,+()-]{1,60}", text) else None


# ---- Reading one report --------------------------------------------------------------------------
def report_fields(body):
    """The json block. Schema 1 and 2 share every schema 1 field; a later schema is read as 2,
    its unknown fields ignored, so a newer bot never drops reports from the export."""
    m = re.search(r"```json\n(.*?)\n```", body or "", re.S)
    if not m:
        return None
    try:
        fields = json.loads(m.group(1))
    except ValueError:
        return None
    if not isinstance(fields, dict) or not re.fullmatch(r"\d{1,10}", str(fields.get("appid"))):
        return None
    return fields if fields.get("status") in BUCKET else None


def schema_of(fields):
    schema = fields.get("schema")
    return min(schema, 2) if isinstance(schema, int) and not isinstance(schema, bool) and schema >= 1 else 1


def plain(value, pattern):
    return value if isinstance(value, str) and re.fullmatch(pattern, value) else None


def count(value, top):
    return value if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= top else None


def launch_of(launch):
    """Schema 2's last launch: {code, seconds, window}. window null: watched, no window seen."""
    if not isinstance(launch, dict) or not plain(launch.get("code"), r"[a-z0-9_]{1,32}"):
        return None
    out = {"code": launch["code"], "seconds": count(launch.get("seconds"), 10_000_000)}
    if "window" in launch and (launch["window"] is None or count(launch["window"], 1_000_000) is not None):
        out["window"] = launch["window"]
    return out


def player_note(body):
    m = re.search(r"### What the player says\n\n(.*?)(?:\n\n###|\n\n```|\Z)", body or "", re.S)
    if not m:
        return None
    return scrub(" ".join(re.sub(r"^>\s?", "", line) for line in m.group(1).split("\n")), NOTE_SHORT, note=True)


def setup_of(body):
    m = re.search(r"### Setup at report time\n\n((?:- [^\n]*(?:\n|\Z))+)", body or "")
    out = {}
    for line in (m.group(1) if m else "").split("\n"):
        kv = re.match(r"^- (\w+): (.*)$", line)
        if kv:
            out[kv.group(1)] = kv.group(2).strip()
    return out


def section(body, label):
    m = re.search(rf"### {re.escape(label)}\n\n(.*?)(?:\n\n###|\n\n```|\Z)", body or "", re.S)
    return m.group(1).strip() if m else ""


def log_blocks(body):
    """The <details> log blocks api/report.mjs writes, by summary text."""
    return {m.group(1): m.group(2) for m in
            re.finditer(r"<details><summary>([^<]*)</summary>\n\n`{3,4}text\n(.*?)\n`{3,4}\n", body or "", re.S)}


def run_facts(run_log):
    last = run_log.rfind("=== bridgeplay run ")
    segment = run_log[last:] if last >= 0 else run_log
    health = re.findall(r"=== session health: (healthy|failed|unknown) after (\d+)s ===", segment) \
        or re.findall(r"=== session health: (healthy|failed|unknown) after (\d+)s ===", run_log)
    status = re.findall(r"=== exit summary: exit status (\d{1,3}) after", segment)
    fixes = {}
    # "BACKEND=dxvk from the default conf", "applied NOTPROTON_VSYNC=1 from the user conf"
    for m in re.finditer(r"^gamefix: (?:applied )?([A-Za-z][A-Za-z0-9_]{1,40})=(\S{1,64}) from the [\w -]{1,24} conf",
                         segment, re.M):
        key = "STEAMDECK" if m.group(1) == "SteamDeck" else re.sub(r"^NOTPROTON_", "", m.group(1))
        value = m.group(2).rstrip(",")
        if (key in GAMEFIX_KEYS or key.startswith(GAMEFIX_PREFIXES)) and re.fullmatch(r"[A-Za-z0-9_.,=;:+-]{1,64}", value):
            fixes[key] = value
    return {
        "health": health[-1][0] if health else None,
        "seconds": int(health[-1][1]) if health else None,
        "exit_status": int(status[-1]) if status else None,
        "gamefix": fixes,
    }


def error_lines(blocks):
    text = next((v for k, v in blocks.items() if k.startswith("Error lines")), "")
    return [l for l in text.splitlines() if l.strip() and not NOISE.search(re.sub(r"^[0-9a-f]{4}:", "", l.strip()))]


def crash_key(line):
    """One crash line with paths, addresses, pids and counts taken out, so equal crashes group."""
    line = re.sub(r"\s*\(\d+ times\)$", "", line.strip())
    line = re.sub(r"^=== exit cause: (.*) ===$", r"\1", line)
    line = re.sub(r'L?"[^"]*"', '"…"', line)
    line = scrub(line, 400) or ""
    return re.sub(r"0x[0-9a-fA-F]+|\b[0-9a-fA-F]{4,}\b|\d+", "#", line)[:110]


def signature(body, blocks):
    # Neither the form's "Launcher, sign-in or anti-cheat" answer nor the player's own words
    # are evidence of a cause.
    text = body.replace("Launcher, sign-in or anti-cheat", "")
    text = re.sub(r"### What the player says\n\n.*?(?=\n\n###|\n\n```|\Z)", "", text, flags=re.S)
    for pattern, sig, _ in KNOWN:
        if re.search(pattern, text, re.I):
            return sig
    hits = [l for l in error_lines(blocks) if CRASH.search(l)]
    crash = next((l for l in hits if "exited status" not in l), "")
    if crash:
        return crash_key(crash)
    status = next((m.group(1) for l in hits if (m := re.search(r"game exited status=(\d+)", l))), "")
    return f"game exit status={status}, no crash line" if status else NO_CRASH


def is_author(author, login):
    """api/_lib/github.mjs isAuthor: a login ending in [bot] is a GitHub App's bot."""
    if not isinstance(author, dict) or not author.get("login") or not login:
        return False
    bot = login.endswith("[bot]")
    return (author.get("__typename") == "Bot") == bot and \
        re.sub(r"\[bot\]$", "", author["login"]) == re.sub(r"\[bot\]$", "", login)


def parse_report(node, authors):
    """One Discussion node -> the record kept, or None when it is not a counted report."""
    if not any(is_author(node.get("author"), a) for a in authors):
        return None
    body = node.get("body") or ""
    f = report_fields(body)
    number = node.get("number")
    created = node.get("createdAt") or ""
    if not f or not isinstance(number, int) or not re.match(r"\d{4}-\d{2}-\d{2}T", created):
        return None
    bucket = BUCKET[f["status"]]
    version, build = version_of(f.get("version"))
    setup = setup_of(body)
    blocks = log_blocks(body)
    run_log = next((v for k, v in blocks.items() if k.startswith("bridgeplay-run.log")), "")
    facts = run_facts(run_log)
    session = re.search(r"Session (\d{1,5}) min", section(body, "Notes"))
    schema = schema_of(f)
    launch = launch_of(f.get("launch")) if schema >= 2 else None
    seconds = facts["seconds"] if facts["seconds"] is not None else (launch or {}).get("seconds")
    minutes = int(session.group(1)) if session else (round(seconds / 60) if seconds is not None else None)
    # schema 2's steamBuild; "steam" is the name the export read before the bot sent one.
    steam = str(f.get("steamBuild") or f.get("steam") or "")
    return {
        "n": number,
        "date": created[:19] + "Z",
        "appid": int(f["appid"]),
        "name": scrub(f.get("name"), 120),
        "status": f["status"],
        "chip": chip_family(f.get("chip")),
        "memory": memory_size(f.get("memory")),
        "macos": macos_minor(f.get("macos")),
        "version": version,
        "build": build,
        # The Steam client build, once reports carry it (schema 2); null until then.
        "steam": int(steam) if re.fullmatch(r"\d{6,12}", steam) else None,
        "engine": engine_name(f.get("engine")),
        "backend": f.get("backend") if f.get("backend") in BACKENDS else None,
        "source": f.get("source") if f.get("source") in SOURCES else "tap",
        "issue": f.get("issue") if bucket == "issues" and f.get("issue") in ISSUES else None,
        "note": player_note(body),
        "low_power": setup.get("lowPower") == "on",
        "thermal": setup.get("thermal") if setup.get("thermal") in THERMAL else None,
        "health": facts["health"],
        "minutes": minutes,
        "exit_status": facts["exit_status"],
        "gamefix": facts["gamefix"],
        "sig": None if bucket == "playable" else signature(body, blocks),
        # Schema 2 (null for schema 1). voter is the bot's per-game code for one install.
        "schema": schema,
        "voter": plain(f.get("voter"), r"[0-9a-f]{16}") if schema >= 2 else None,
        "steam_channel": plain(f.get("steamChannel"), r"[A-Za-z0-9_.-]{1,40}") if schema >= 2 else None,
        "engine_id": plain(f.get("engineID"), r"[A-Za-z0-9.-]{1,60}") if schema >= 2 else None,
        "launch": launch,
        "bulk": f.get("bulk") is True,
        "channel": plain(f.get("buildChannel"), r"[a-z]{1,16}"),
    }


# ---- The store: reports/YYYY-MM.ndjson -----------------------------------------------------------
def load_store(out):
    store = {}
    for path in sorted((out / "reports").glob("*.ndjson")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                r = json.loads(line)
                store[r["n"]] = r
    return store


def write_atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


EMPTIED = "reports/.emptied"  # fetch wrote an empty store on purpose; build may publish it


def write_store(out, store):
    marker = out / EMPTIED
    if store:
        marker.unlink(missing_ok=True)
    months = defaultdict(list)
    for r in store.values():
        months[r["date"][:7]].append(r)
    folder = out / "reports"
    folder.mkdir(parents=True, exist_ok=True)
    for path in folder.glob("*.ndjson"):
        if path.stem not in months:
            path.unlink()
    for month, rows in months.items():
        rows.sort(key=lambda r: r["n"])
        write_atomic(folder / f"{month}.ndjson",
                     "".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n" for r in rows))
    if not store:
        write_atomic(marker, "every report was removed\n")


# ---- GitHub ----------------------------------------------------------------------------------------
def graphql(token, query, variables):
    data = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(API, data=data, method="POST", headers={
        "Authorization": f"Bearer {token}", "Content-Type": "application/json", "User-Agent": "bridgeplay-compat-export"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                answer = json.loads(r.read().decode("utf-8"))
            if answer.get("errors"):
                raise RuntimeError("GitHub GraphQL: " + "; ".join(e.get("message", "?") for e in answer["errors"]))
            return answer["data"]
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if attempt == 3:
                raise
            print(f"  retry after {e}", file=sys.stderr)
            time.sleep(10 * (attempt + 1))


def github_nodes(token, stop_at, bodies=True):
    """Discussion nodes of the category, newest first; stops after the page that reaches stop_at."""
    owner, name = REPO.split("/", 1)
    cats = graphql(token, """query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) { discussionCategories(first: 50) { nodes { id slug } } } }""",
                   {"owner": owner, "name": name})
    cat = next((c["id"] for c in cats["repository"]["discussionCategories"]["nodes"] if c["slug"] == CATEGORY), None)
    if not cat:
        raise RuntimeError(f"no discussion category {CATEGORY} in {REPO}")
    fields = "number createdAt body author { __typename login }" if bodies else "number"
    query = f"""query($owner: String!, $name: String!, $category: ID!, $after: String) {{
      repository(owner: $owner, name: $name) {{
        discussions(first: {PAGE}, after: $after, categoryId: $category, orderBy: {{ field: CREATED_AT, direction: DESC }}) {{
          pageInfo {{ hasNextPage endCursor }} nodes {{ {fields} }} }} }} }}"""
    after = None
    while True:
        page = graphql(token, query, {"owner": owner, "name": name, "category": cat, "after": after})
        found = page["repository"]["discussions"]
        nodes = [n for n in found["nodes"] if n]
        yield from nodes
        if not found["pageInfo"]["hasNextPage"] or any(n["number"] <= stop_at for n in nodes):
            return
        after = found["pageInfo"]["endCursor"]


def fetch(out, full=False, prune=False, force=False, source=None):
    authors = [a.strip() for a in AUTHORS.split(",") if a.strip()]
    store = load_store(out)
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if source is None and not token:
        raise SystemExit("compat-export: set GH_TOKEN, or pass --from NODES.json")
    if source is not None:
        loaded = json.loads(Path(source).read_text(encoding="utf-8"))
        nodes = loaded.get("nodes", []) if isinstance(loaded, dict) else loaded
    else:
        nodes = github_nodes(token, 0 if full else max(store, default=0))
    fresh = {}
    numbers = set()
    for node in nodes:
        numbers.add(node.get("number"))
        r = parse_report(node, authors)
        if r:
            fresh[r["n"]] = r
    before = len(store)
    if full:
        # A run that sees far fewer reports than the store holds is a GitHub hiccup or a wrong
        # bot login, not mass deletion: keep the store.
        if len(fresh) * 10 < before * 9 and not force:
            raise SystemExit(f"compat-export: full read found {len(fresh)} reports, the store has {before}; "
                             "not replacing it (--force to accept)")
        store = fresh
    else:
        store.update(fresh)
    pruned = 0
    if prune and not full:
        if source is None:
            numbers = {n["number"] for n in github_nodes(token, 0, bodies=False)}
        if len(numbers) * 2 < len(store) and not force:
            raise SystemExit(f"compat-export: the listing has {len(numbers)} discussions, the store {len(store)}; "
                             "not pruning (--force to accept)")
        for n in [n for n in store if n not in numbers]:
            del store[n]
            pruned += 1
    write_store(out, store)
    print(f"compat-export fetch: {len(fresh)} reports read, {pruned} pruned, {len(store)} kept (was {before})")
    return store


# ---- Verdicts --------------------------------------------------------------------------------------
def parse_date(text):
    return datetime.datetime.strptime(text[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)


def votes(reports, now):
    """The reports a verdict counts: one per Mac, its newest, within the window.

    A schema 2 report with a `voter` (the bot's per-game code for one install) is that Mac: its
    newest report counts. Older reports carry none, so there a Mac is its chip, memory and
    macOS. The app asks once per game per Bridgeplay version, so reports of one setup on one
    build are different Macs; the same setup on an older build is taken to be those Macs again
    and drops out, also when a voter's report of that setup is on the same or a newer build.
    CEILING: the setup stays a proxy for reports without a voter; it fades as they age out of the window.
    """
    cutoff = now - datetime.timedelta(days=WINDOW_DAYS)
    recent = [r for r in reports if parse_date(r["date"]) >= cutoff] or list(reports)
    groups = defaultdict(list)
    for r in recent:
        groups[r.get("voter") or (r["chip"], r["memory"], r["macos"])].append(r)
    counted = []
    voted = defaultdict(int)  # setup -> newest build a voter reported it on
    for key, rows in groups.items():
        if isinstance(key, str):
            newest = max(rows, key=lambda r: (r["date"], r["n"]))
            counted.append(newest)
            setup = (newest["chip"], newest["memory"], newest["macos"])
            voted[setup] = max(voted[setup], newest["build"])
    for key, rows in groups.items():
        if isinstance(key, str):
            continue
        top = max(r["build"] for r in rows)
        if key in voted and voted[key] >= top:
            continue
        counted.extend(r for r in rows if r["build"] == top)
    return counted


def broken_since(counted, key):
    """'Broken since': it ran well on at least half the Macs up to the newest build it ran well
    on, then at least BROKEN_MIN Macs did not run it on newer builds, and they are most of the
    reports on those builds. Returns the oldest failing report and how many failed, or None.
    Reports that don't name the build are on neither side: an older report without a Steam
    build is no report from build zero."""
    counted = [r for r in counted if r.get(key)]
    played = [r[key] for r in counted if BUCKET[r["status"]] == "playable"]
    if not played:
        return None
    older = [r for r in counted if r[key] <= max(played)]
    if sum(1 for r in older if BUCKET[r["status"]] == "playable") * 2 < len(older):
        return None
    newer = [r for r in counted if r[key] > max(played)]
    failed = [r for r in newer if BUCKET[r["status"]] == "broken"]
    if len(failed) < BROKEN_MIN or len(failed) * 2 <= len(newer):
        return None
    return min(failed, key=lambda r: (r[key], r["n"])), len(failed)


def verdict(reports, now):
    counted = votes(reports, now)
    n = len(counted)
    tally = Counter(BUCKET[r["status"]] for r in counted)
    p, i, b = tally["playable"], tally["issues"], tally["broken"]
    out = {"label": None, "answer": None, "n": n, "p": p, "i": i, "b": b, "since": None}
    if n < MIN_REPORTS:
        only = BUCKET[counted[0]["status"]] if counted else "issues"
        said = {"playable": "it ran well", "issues": "it ran with issues", "broken": "it did not run"}[only]
        out.update(label="one_report", answer=f"One report so far: {said}.")
        return out
    # A Bridgeplay build first; a Steam client build once reports carry one.
    since = None
    found = broken_since(counted, "build")
    if found:
        since = short_version(found[0]["version"])
    else:
        found = broken_since(counted, "steam")
        since = f"Steam build {found[0]['steam']}" if found else None
    if found:
        failed = found[1]
        out.update(label="broken_since", since=since,
                   answer=f"Ran well before {since}, but did not run on {failed} Macs since.")
    elif p >= MIN_REPORTS and p * SHARE[1] >= n * SHARE[0]:
        out.update(label="playable", answer=f"Ran well on {p} of {n} Macs.")
    elif b >= MIN_REPORTS and b * SHARE[1] >= n * SHARE[0]:
        out.update(label="doesnt_run", answer=f"Did not run on {b} of {n} Macs.")
    else:
        out.update(label="mixed", answer=f"Mixed: {p} ran well, {i} had issues, {b} did not run.")
    return out


# ---- compat.json: the /api/compat shape -------------------------------------------------------------
def low_end(chip, memory):
    m = re.match(r"\d+", memory or "")
    return bool(re.fullmatch(r"M[1-3]", chip or "")) or (int(m.group(0)) if m else 99) <= 8


def status_of(g):
    """compat-merge.js statusOf: one Mac playing it beats any number of "Has issues"; against
    "Doesn't run" only on the same or a newer build; otherwise most reports, ties to the newest."""
    def newest(bucket):
        return max([0] + [version_of(r["version"])[1] for r in g["latest"] if r["status"] == bucket])
    if g["counts"]["playable"] and newest("playable") >= newest("broken"):
        return "playable"
    top = max(g["counts"].values())
    tied = [k for k in ("playable", "issues", "broken") if g["counts"][k] == top]
    if len(tied) == 1:
        return tied[0]
    return next((r for r in g["latest"] if r["status"] in tied), g["latest"][0])["status"]


def aggregate(store, now):
    games = {}
    by_game = defaultdict(list)
    for r in sorted(store.values(), key=lambda r: (r["date"], r["n"]), reverse=True):
        bucket = BUCKET[r["status"]]
        issue = None
        if bucket == "issues":
            issue = r["issue"] if r["issue"] in ISSUES else ("performance" if SLOW.search(r["note"] or "") else None)
        g = games.setdefault(r["appid"], {"appid": r["appid"], "name": r["name"], "total": 0,
                                          "counts": {"playable": 0, "issues": 0, "broken": 0}, "latest": []})
        g["total"] += 1
        g["counts"][bucket] += 1
        g["latest"].append({"status": bucket, "chip": r["chip"], "memory": r["memory"], "macos": r["macos"],
                            "version": r["version"], "date": r["date"][:10],
                            "url": f"https://github.com/{REPO}/discussions/{r['n']}", "note": r["note"],
                            "issue": issue, "lowPower": bool(r["low_power"])})
        by_game[r["appid"]].append(r)
    out = []
    for appid in sorted(games):
        g = games[appid]
        g["status"] = status_of(g)
        playable = g["counts"]["playable"] > 0
        for e in g["latest"]:
            if e["issue"] == "performance":
                e["hardware"] = playable and low_end(e["chip"], e["memory"])
        g["latest"] = g["latest"][:LATEST]
        g["verdict"] = verdict(by_game[appid], now)
        out.append(g)
    return out, by_game


def index_of(games, by_game):
    index = {}
    for g in games:
        rows = by_game[g["appid"]]
        v = g["verdict"]
        entry = {"v": v["label"], "n": v["n"], "p": v["p"], "i": v["i"], "b": v["b"]}
        if v["since"]:
            entry["since"] = v["since"]
        entry["build"] = max(r["build"] for r in rows)
        entry["date"] = max(r["date"] for r in rows)[:10]
        index[str(g["appid"])] = entry
    return index


# ---- anti-cheat names from AreWeAntiCheatYet (MIT) --------------------------------------------------
# The ids the app and the panel know (dylib/feats/compatverdict.c); any other name is "other".
ANTICHEAT_IDS = {
    "easyanticheat": "eac", "battleye": "battleye", "ricochet": "ricochet", "vanguard": "vanguard",
    "anticheatexpert": "ace", "xigncode3": "xigncode3", "nprotectgameguard": "nprotect",
    "eaanticheat": "javelin", "eajavelin": "javelin", "denuvoanticheat": "denuvo", "vac": "vac",
    "valveanticheat": "vac",
}
ANTICHEAT_MAX = 4


def anticheat_index(awacy):
    """AppID -> sorted anti-cheat ids, from AreWeAntiCheatYet's games.json. Games it lists as
    Running (they start under Proton anyway) are left out."""
    out = {}
    for g in awacy if isinstance(awacy, list) else []:
        if not isinstance(g, dict) or g.get("status") == "Running":
            continue
        steam = (g.get("storeIds") or {}).get("steam") if isinstance(g.get("storeIds"), dict) else None
        if not isinstance(steam, (str, int)) or not re.fullmatch(r"[1-9]\d{0,9}", str(steam)) or int(steam) >= 2 ** 31:
            continue
        names = g.get("anticheats") if isinstance(g.get("anticheats"), list) else []
        ids = {ANTICHEAT_IDS.get(re.sub(r"[^a-z0-9]", "", n.lower()), "other") for n in names if isinstance(n, str) and n.strip()}
        if ids:
            out.setdefault(str(int(steam)), set()).update(ids)
    return {k: sorted(v)[:ANTICHEAT_MAX] for k, v in sorted(out.items(), key=lambda kv: int(kv[0]))}


# ---- board.md: failing reports by signature ---------------------------------------------------------
def cell(text):
    return str(text).replace("|", "\\|").replace("`", "'").replace("\n", " ")


def board(store, games, now):
    cutoff = now - datetime.timedelta(days=BOARD_DAYS)
    newest_build = max((r["build"] for r in store.values()), default=0)
    failing = [r for r in store.values() if r["sig"] and parse_date(r["date"]) >= cutoff]
    groups = defaultdict(list)
    for r in failing:
        groups[r["sig"]].append(r)
    url = f"https://github.com/{REPO}/discussions/"

    def links(rows):
        return " ".join(f"[#{r['n']}]({url}{r['n']})" for r in rows)

    lines = [
        "# Signature board",
        "",
        f"Failing reports (did not run, or ran with issues) from the last {BOARD_DAYS} days, grouped by the"
        f" first crash line of their logs. Generated {now.strftime('%Y-%m-%d %H:%M')} UTC from"
        f" {len(failing)} reports; the newest Bridgeplay build seen is {newest_build}."
        " A signature is the crash line with numbers, addresses and paths taken out.",
        "",
        "## Unknown signatures",
        "",
        "**Look first** marks a signature seen twice or more, or on the newest build.",
        "",
        "| Reports | Games | Signature | Builds | Engine · backend | Reports |",
        "|---:|---|---|---|---|---|",
    ]
    unknown = sorted(((s, rs) for s, rs in groups.items() if s not in KNOWN_STATUS),
                     key=lambda kv: (-len(kv[1]), kv[0]))
    for sig, rows in unknown:
        rows.sort(key=lambda r: -r["n"])
        names = Counter(r["name"] or f"App {r['appid']}" for r in rows)
        builds = sorted({r["build"] for r in rows if r["build"]})
        stacks = Counter(f"{r['engine'] or '?'} · {r['backend'] or 'default'}" for r in rows)
        mark = " **Look first**" if sig != NO_CRASH and (len(rows) >= 2 or newest_build in builds) else ""
        lines.append(
            f"| {len(rows)} | {cell(', '.join(f'{k} ×{v}' if v > 1 else k for k, v in names.most_common(4)))}"
            f"{' …' if len(names) > 4 else ''} | `{cell(sig)}`{mark} | {cell(', '.join(map(str, builds[-4:])) or '?')}"
            f" | {cell(stacks.most_common(1)[0][0])} | {links(rows[:6])} |")
    if not unknown:
        lines.append("| 0 | | | | | |")
    lines += ["", "## Known signatures", "", "| Reports | Signature | What is known | Games |", "|---:|---|---|---|"]
    known = sorted(((s, rs) for s, rs in groups.items() if s in KNOWN_STATUS), key=lambda kv: (-len(kv[1]), kv[0]))
    for sig, rows in known:
        names = Counter(r["name"] or f"App {r['appid']}" for r in rows)
        lines.append(f"| {len(rows)} | `{sig}` | {cell(KNOWN_STATUS[sig])} | "
                     f"{cell(', '.join(k for k, _ in names.most_common(5)))}{' …' if len(names) > 5 else ''} |")
    if not known:
        lines.append("| 0 | | | |")
    lines += ["", "## Games that fail most",
              "", f"Games with {BOARD_GAMES_MIN} or more reports, all time, that did not run or had issues in at least"
              f" {BOARD_FAIL[0] * 100 // BOARD_FAIL[1]}% of them.", "",
              "| Game | AppID | Reports | Did not run | Had issues | Top signature | Verdict |", "|---|---:|---:|---:|---:|---|---|"]
    worst = []
    for g in games:
        bad = g["counts"]["broken"] + g["counts"]["issues"]
        if g["total"] >= BOARD_GAMES_MIN and bad * BOARD_FAIL[1] >= g["total"] * BOARD_FAIL[0]:
            sigs = Counter(r["sig"] for r in store.values() if r["appid"] == g["appid"] and r["sig"])
            worst.append((bad / g["total"], g, sigs.most_common(1)[0][0] if sigs else ""))
    for _, g, sig in sorted(worst, key=lambda w: (-w[0], -w[1]["total"])):
        lines.append(f"| {cell(g['name'] or g['appid'])} | {g['appid']} | {g['total']} | {g['counts']['broken']} | "
                     f"{g['counts']['issues']} | `{cell(sig)}` | {g['verdict']['label']} |")
    if not worst:
        lines.append("| none | | | | | | |")
    return "\n".join(lines) + "\n"


# ---- build -------------------------------------------------------------------------------------------
def check_private(name, text):
    m = PRIVATE.search(text)
    if m:
        raise SystemExit(f"compat-export: {name} would publish personal data near "
                         f"{text[max(0, m.start() - 30):m.start()]!r}; nothing written")


def build(out, now, anticheat=None):
    store = load_store(out)
    if not store and not (out / EMPTIED).exists():
        # No store at all is a failed or missing first fetch; an emptied one is a real result.
        raise SystemExit("compat-export: no reports in the store, nothing to publish")
    games, by_game = aggregate(store, now)
    updated = now.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    index = {"schema": 1, "rule": RULE, "updated": updated, "games": index_of(games, by_game)}
    if anticheat:
        try:
            index["anticheat"] = anticheat_index(json.loads(Path(anticheat).read_text(encoding="utf-8")))
        except (OSError, ValueError) as e:
            # The verdicts still go out; the names come back with the next readable copy.
            print(f"compat-export: {anticheat} not read ({e}), no anti-cheat names this time", file=sys.stderr)
    files = {
        "compat.json": json.dumps({"category": CATEGORY, "updated": updated, "rule": RULE, "games": games, "art": {}},
                                  ensure_ascii=False, separators=(",", ":")),
        "compat-index.json": json.dumps(index, ensure_ascii=False, separators=(",", ":")),
        "board.md": board(store, games, now),
    }
    for path in sorted((out / "reports").glob("*.ndjson")):
        check_private(f"reports/{path.name}", path.read_text(encoding="utf-8"))
    for name, text in files.items():
        check_private(name, text)
    for name, text in files.items():
        write_atomic(out / name, text)
    for name in ("README.md", "LICENSE"):
        shutil.copyfile(DATA_DOCS / name, out / name)
    labels = Counter(g["verdict"]["label"] for g in games)
    print(f"compat-export build: {len(store)} reports, {len(games)} games, "
          + ", ".join(f"{k} {v}" for k, v in sorted(labels.items())))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch", help="add new reports to the store")
    f.add_argument("dir", type=Path)
    f.add_argument("--full", action="store_true", help="re-read every report and replace the store")
    f.add_argument("--prune", action="store_true", help="drop reports whose discussion is gone")
    f.add_argument("--force", action="store_true", help="accept a read that shrinks the store a lot")
    f.add_argument("--from", dest="source", help="Discussion nodes as JSON instead of GitHub")
    b = sub.add_parser("build", help="write compat.json, compat-index.json and board.md")
    b.add_argument("dir", type=Path)
    b.add_argument("--now", help="the export time, ISO 8601 UTC (default: now)")
    b.add_argument("--anticheat", help="AreWeAntiCheatYet's games.json, for the anti-cheat names")
    args = ap.parse_args(argv)
    if args.cmd == "fetch":
        fetch(args.dir, full=args.full, prune=args.prune, force=args.force, source=args.source)
    else:
        now = parse_date(args.now) if args.now else datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
        build(args.dir, now, anticheat=args.anticheat)


if __name__ == "__main__":
    main()
