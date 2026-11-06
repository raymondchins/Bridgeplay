#!/usr/bin/env bash
# np-test-game.sh - launch one Steam game through Bridgeplay, observe it, collect logs.
#
#   scripts/np-test-game.sh <appid> [--seconds N] [--backend dxmt|dxvk|wined3d|d3dmetal] [--stop]
#
# Output: compat/runs/<appid>-<UTC timestamp>/ (logs, ps snapshots, result.json).
# Exit status: 0 running, 1 crashed, 2 no_launch, 64 usage/setup error.
# shellcheck disable=SC2009,SC2012,SC2015,SC2329
set -u

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

APPID=""
SECONDS_MAX=90
BACKEND=""
STOP=0
STABLE=20     # seconds the exe must be seen after first sighting (extends deadline)
INTERVAL=2
CRASH_MISSES=5 # consecutive missed samples after first sighting => crashed

while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) SECONDS_MAX="${2:-}"; shift 2 || usage ;;
    --backend) BACKEND="${2:-}"; shift 2 || usage ;;
    --stop) STOP=1; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) [ -z "$APPID" ] && APPID="$1" || usage; shift ;;
  esac
done
[[ "$APPID" =~ ^[0-9]+$ ]] || usage
[[ "$SECONDS_MAX" =~ ^[0-9]+$ ]] || usage
case "$BACKEND" in ""|dxmt|dxvk|wined3d|d3dmetal) ;; *) echo "bad backend: $BACKEND" >&2; usage ;; esac
command -v jq >/dev/null || { echo "jq required" >&2; exit 64; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUP="$HOME/Library/Application Support"
STEAMAPPS="$SUP/Steam/steamapps"
# The support folder and log names moved to bridgeplay in 3.0.0; fall back to the old
# ones on a Mac the app has not migrated yet.
NP="$SUP/bridgeplay"
[ -d "$NP" ] || [ ! -d "$SUP/notproton" ] || NP="$SUP/notproton"
MANIFEST="$STEAMAPPS/appmanifest_${APPID}.acf"
[ -f "$MANIFEST" ] || { echo "app $APPID is not installed (no $MANIFEST)" >&2; exit 64; }

acf() { sed -n "s/^[[:space:]]*\"$1\"[[:space:]]*\"\(.*\)\"[[:space:]]*$/\1/p" "$MANIFEST" | head -1; }
NAME="$(acf name)"
INSTALLDIR="$STEAMAPPS/common/$(acf installdir)"
PFX="$STEAMAPPS/compatdata/$APPID/pfx"
# Each log is read under both names (see legacy_of below).
RUNLOG="$STEAMAPPS/compatdata/$APPID/bridgeplay-run.log"
WINELOG="$NP/launchers/$APPID/bridgeplay-wine.log"
NPLOG="$NP/bridgeplay.log"
FIXDIR="$NP/gamefixes"
FIX="$FIXDIR/$APPID.conf"

STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OUT="$REPO/compat/runs/${APPID}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
WORK="$(mktemp -d)"

# ---- candidate Windows exe names (from the install dir; extended from the run log) ----
PATS="$WORK/exe-patterns"
: > "$PATS"
if [ -d "$INSTALLDIR" ]; then
  find "$INSTALLDIR" -maxdepth 2 -iname '*.exe' 2>/dev/null \
    | sed 's#.*/##' \
    | grep -Eiv 'unins|crash|redist|vcredist|dxsetup|dotnet|installer|setup|eac|battleye|helper|crs-|touchup|cleanup|overlayinjector|bugsplat|bssndrpt|repair' \
    | sort -u >> "$PATS"
fi
add_exes_from_runlog() { # $1 = file with new run-log bytes
  grep -E '^[[:space:]]*\[.*\.exe\][[:space:]]*$' "$1" 2>/dev/null \
    | sed 's/^[[:space:]]*\[//; s/\][[:space:]]*$//; s#.*[/\\]##' \
    | grep -Eiv '^(iscriptevaluator|steam|wineboot|winedevice|services|explorer)\.exe$' >> "$PATS" || true
  sort -u -o "$PATS" "$PATS"
}

# ---- gamefix backup/restore ----
WROTE_FIX=0; FIX_EXISTED=0; FIXDIR_CREATED=0; FIX_BACKUP=""
restore_fix() {
  [ "$WROTE_FIX" = 1 ] || return 0
  WROTE_FIX=0
  if [ "$FIX_EXISTED" = 1 ]; then
    cp -p "$FIX_BACKUP" "$FIX"
  else
    rm -f "$FIX"
    [ "$FIXDIR_CREATED" = 1 ] && rmdir "$FIXDIR" 2>/dev/null
  fi
}
cleanup() { restore_fix; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ -n "$BACKEND" ]; then
  WROTE_FIX=1
  [ -d "$FIXDIR" ] || { mkdir -p "$FIXDIR"; FIXDIR_CREATED=1; }
  if [ -f "$FIX" ]; then
    FIX_EXISTED=1; FIX_BACKUP="$WORK/orig.conf"; cp -p "$FIX" "$FIX_BACKUP"
    { grep -v '^[[:space:]]*BACKEND=' "$FIX_BACKUP"; echo "BACKEND=$BACKEND"; } > "$FIX"
  else
    echo "BACKEND=$BACKEND" > "$FIX"
  fi
else
  BACKEND="$(sed -n 's/^[[:space:]]*BACKEND=//p' "$FIX" 2>/dev/null | tail -1)"
  BACKEND="${BACKEND:-default}"
fi

# ---- helpers ----
ps_game() { # print ps lines belonging to the game's wine exe
  [ -s "$PATS" ] || return 1
  ps -axww -o pid=,command= 2>/dev/null \
    | grep -iFf "$PATS" \
    | grep -iE '[[:space:]][A-Z]:\\|wine' \
    | grep -Ev 'waitforexitandrun|/bin/sh -c|np-test-game|grep ' || true
}
wine_procs() { ps -axww -o pid=,command= 2>/dev/null | grep -Ei 'wineserver|wine-preloader|/wine(64)? ' | grep -v grep || true; }
now() { date +%s; }
size_of() { [ -f "$1" ] && stat -f %z "$1" || echo 0; }
since() { # $1 file, $2 offset -> bytes after offset
  [ -f "$1" ] && tail -c +"$(( $2 + 1 ))" "$1" || true
}
# Before 3.0.0 the logs were notproton-*.log. Reading both names keeps runs against a
# build or prefix from before the rename working; the old file just stops growing.
legacy_of() { echo "${1%/*}/notproton${1##*/bridgeplay}"; }
latest_of() { if [ -f "$1" ]; then echo "$1"; else legacy_of "$1"; fi; }
size2() { echo "$(size_of "$1") $(size_of "$(legacy_of "$1")")"; }
since2() { # $1 file, $2 "offset legacy_offset" -> new bytes of both names
  # shellcheck disable=SC2086 # split "offset legacy_offset" into $2 $3
  set -- "$1" $2
  since "$1" "$2"; since "$(legacy_of "$1")" "$3"
}

if [ -n "$(ps_game)" ]; then
  echo "game exe already running under wine; run with --stop first or: scripts/np-test-game.sh $APPID --stop" >&2
  exit 64
fi
pgrep -xq steam_osx || echo "warning: Steam does not appear to be running; 'open steam://' will start it" >&2

OFF_RUN=$(size2 "$RUNLOG"); OFF_WINE=$(size2 "$WINELOG"); OFF_NP=$(size2 "$NPLOG")
T0=$(now)
echo "[$APPID] $NAME  backend=$BACKEND  max=${SECONDS_MAX}s  -> $OUT" >&2
open "steam://rungameid/$APPID"

# ---- sample loop ----
FIRST=""; LAST=""; MISSES=0; WINE_SEEN=0; DEADLINE=$(( T0 + SECONDS_MAX )); CRASHED=0
while :; do
  sleep "$INTERVAL"
  t=$(now)
  since2 "$RUNLOG" "$OFF_RUN" > "$WORK/run.new"; add_exes_from_runlog "$WORK/run.new"
  [ -n "$(wine_procs)" ] && WINE_SEEN=1
  hit="$(ps_game)"
  if [ -n "$hit" ]; then
    if [ -z "$FIRST" ]; then
      FIRST=$t; echo "[$APPID] exe seen after $(( t - T0 ))s" >&2
      ps -axww -o pid=,etime=,command= > "$OUT/ps-first-seen.txt" 2>/dev/null
      [ $(( FIRST + STABLE )) -gt "$DEADLINE" ] && DEADLINE=$(( FIRST + STABLE ))
    fi
    LAST=$t; MISSES=0
  elif [ -n "$FIRST" ]; then
    MISSES=$(( MISSES + 1 ))
    if [ "$MISSES" -ge "$CRASH_MISSES" ]; then CRASHED=1; break; fi
  fi
  [ "$t" -ge "$DEADLINE" ] && break
done

# ---- collect ----
ps -axww -o pid=,etime=,command= > "$OUT/ps-end.txt" 2>/dev/null
[ -n "$(ps_game)" ] && ALIVE=true || ALIVE=false
since2 "$RUNLOG" "$OFF_RUN" > "$OUT/bridgeplay-run.log"
since2 "$WINELOG" "$OFF_WINE" | tail -n 2000 > "$OUT/bridgeplay-wine.log"
since2 "$NPLOG" "$OFF_NP" > "$OUT/bridgeplay.log"
[ -f "$(latest_of "$RUNLOG")" ] && tail -n 200 "$(latest_of "$RUNLOG")" > "$OUT/bridgeplay-run.tail.log"

# engine
ENGINE="$(grep -h 'state crossOver' "$NP/app.log" 2>/dev/null | tail -1 | sed -n 's/.*state crossOver \(.*\) version=.*/\1/p')"
[ -n "$ENGINE" ] || ENGINE="$(basename "$(readlink "$NP/runners/current" 2>/dev/null)" 2>/dev/null)"
[ -n "$ENGINE" ] || ENGINE=unknown

# error signatures
SIG='err:module|err:seh|err:virtual|err:d3d|err:ntdll|DXGI_ERROR|DXMT.*(error|fail)|vkd3d.*(error|fail)|Unhandled exception|wine: could not load|wine: cannot find|No such file|Bad CPU type|Assertion failed|Segmentation fault|page fault|fixme:.*not implemented|cannot open|failed to'
cat "$OUT/bridgeplay-run.log" "$OUT/bridgeplay-wine.log" "$OUT/bridgeplay.log" 2>/dev/null \
  | grep -Ei "$SIG" \
  | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:]+Z? //; s/^[0-9a-f]{4}:(err|fixme)/\1/; s/0x[0-9a-fA-F]+/0xN/g' \
  | cut -c1-200 | sort | uniq -c | sort -rn | head -10 \
  | sed -E 's/^ *([0-9]+) (.*)$/\2 (x\1)/' > "$WORK/errors.txt"

# verdict
if [ -z "$FIRST" ]; then
  if [ -s "$WORK/errors.txt" ] && [ "$WINE_SEEN" = 1 ]; then VERDICT=crashed; else VERDICT=no_launch; fi
elif [ "$CRASHED" = 1 ] || [ "$ALIVE" = false ]; then VERDICT=crashed
else VERDICT=running; fi
if [ -n "$FIRST" ]; then SECS=$(( LAST - FIRST + INTERVAL )); else SECS=0; fi

jq -n --arg appid "$APPID" --arg name "$NAME" --arg backend "$BACKEND" --arg engine "$ENGINE" \
  --arg started "$STARTED" --argjson alive "$ALIVE" --argjson secs "$SECS" --arg verdict "$VERDICT" \
  --rawfile errs "$WORK/errors.txt" \
  '{appid:($appid|tonumber), name:$name, backend:$backend, engine:$engine, started:$started,
    alive_at_end:$alive, seconds_alive:$secs, verdict:$verdict,
    top_errors:($errs|split("\n")|map(select(length>0)))}' > "$OUT/result.json"

# restore gamefix before optional stop so a relaunch uses user config
restore_fix

# ---- stop ----
stop_game() {
  local ws=""
  ws="$(sed -n 's/^WINESERVER=//p' "$(latest_of "$RUNLOG")" 2>/dev/null | tail -1)"
  # The server's name depends on the engine, as in WineServer.swift: wineserver-arm64, wineserver or wineserver-x86.
  [ -x "$ws" ] || ws="$(ls -d "$NP"/engines/*/Contents/SharedSupport/CrossOver/bin/wineserver{-arm64,,-x86} 2>/dev/null | head -1)"
  [ -x "$ws" ] || ws="$(ls "$NP"/runners/*/CrossOver/bin/wineserver{-arm64,,-x86} "$NP"/runners/current/bin/wineserver{-arm64,,-x86} 2>/dev/null | head -1)"
  if [ -x "$ws" ] && [ -d "$PFX" ]; then
    WINEPREFIX="$PFX" "$ws" -k 2>/dev/null || true
    sleep 2
  fi
  if [ -n "$(ps_game)" ]; then
    ps_game | awk '{print $1}' | while read -r pid; do
      cmd="$(ps -p "$pid" -o command= 2>/dev/null)"
      case "$cmd" in *steam_osx*|*Steam.app*|*steamwebhelper*) continue ;; esac
      kill "$pid" 2>/dev/null || true
    done
  fi
  echo "[$APPID] stopped" >&2
}
[ "$STOP" = 1 ] && stop_game
# always allow standalone stop when exe is up but no --stop given? no: leave running.

cat "$OUT/result.json"
case "$VERDICT" in running) exit 0 ;; crashed) exit 1 ;; *) exit 2 ;; esac
