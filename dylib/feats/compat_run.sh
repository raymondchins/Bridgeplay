#!/bin/sh
# bridgeplay CrossOver compatibility tool shim
set -e

verb="$1"
shift || true

# hook_launch.c passes the launch options through a shell before this script runs, matching
# Linux Steam. A NAME=value option placed ahead of %command% is an environment variable,
# and anything after %command% is a launch argument passed to the game.
launch_args="$*"

# Steam launch options and gamefix confs spell the settings BRIDGEPLAY_<X>; everything below
# reads NOTPROTON_<X>, the name upstream NotProton uses. NOTPROTON_<X> stays honored and wins
# when both are set, so launch options written before Bridgeplay 3.0 keep working.
for np_name in $(env | LC_ALL=C sed -n 's/^BRIDGEPLAY_\([A-Z0-9_]*\)=.*/\1/p'); do
  eval "np_new=\${BRIDGEPLAY_$np_name+x} np_old=\${NOTPROTON_$np_name+x}"
  # shellcheck disable=SC2154 # eval assigns np_new and np_old on the line above
  if [ -n "$np_new" ] && [ -z "$np_old" ]; then
    eval "export NOTPROTON_$np_name=\"\$BRIDGEPLAY_$np_name\""
  fi
done

case "$verb" in
  getcompatpath)
    printf '%s\n' "$STEAM_COMPAT_DATA_PATH"
    exit 0
    ;;
esac

np_support="$HOME/Library/Application Support/bridgeplay"
# Before the app moves the support folder over, a game still runs from the old one.
if [ ! -d "$np_support" ] && [ -d "$HOME/Library/Application Support/notproton" ]; then
  np_support="$HOME/Library/Application Support/notproton"
fi
iconmaker="$np_support/iconmaker"

find_client_root() {
  client_root="$1"
  while [ -n "$client_root" ] && [ "$client_root" != "/" ] && [ ! -d "$client_root/appcache" ]; do
    client_root=$(dirname "$client_root")
  done
}

read_app_meta() {
  appinfo_tool="$np_support/appinfo"
  appinfo_vdf="$client_root/appcache/appinfo.vdf"
  meta_name=""
  meta_icon=""
  meta_clienticon=""
  if [ -x "$appinfo_tool" ] && { [ -f "$appinfo_vdf" ] || [ -d "${appinfo_vdf%.vdf}" ]; }; then
    meta=$("$appinfo_tool" "$appinfo_vdf" "$app_id" 2>> "$log") || meta=""
    meta_name=$(printf '%s\n' "$meta" | sed -n 's/^name=//p')
    meta_icon=$(printf '%s\n' "$meta" | sed -n 's/^icon=//p')
    meta_clienticon=$(printf '%s\n' "$meta" | sed -n 's/^clienticon=//p')
    case "$meta_icon" in *[!0-9a-f]*) meta_icon="" ;; esac
    case "$meta_clienticon" in *[!0-9a-f]*) meta_clienticon="" ;; esac
  fi
}

fetch_client_icon() {
  url="https://shared.fastly.steamstatic.com/community_assets/images/apps/$app_id/$meta_clienticon.ico"
  code=$(curl -fsL --connect-timeout 5 --max-time 20 -w '%{http_code}' -o "$ico.new.$$" "$url" 2>>"$log")
  magic=$(od -An -tx1 -N4 "$ico.new.$$" 2>/dev/null | tr -d ' \n')
  if [ "$magic" = "00000100" ]; then
    mv -f "$ico.new.$$" "$ico"
    echo "fetched client icon $meta_clienticon" >> "$log" 2>&1 || true
  else
    rm -f "$ico.new.$$"
    if [ "$code" = "404" ]; then
      : > "$absent"
      echo "no client icon published for $meta_clienticon" >> "$log" 2>&1 || true
    else
      : > "$failed"
      echo "client icon fetch for $meta_clienticon failed (http ${code:-none}), will retry in an hour" >> "$log" 2>&1 || true
    fi
  fi
}

# With icon_fetch_bg=1 (a game launch) the download runs beside the launch, which uses other art
# until a later launch finds the icon cached, so an offline Mac does not wait up to 20 s.
resolve_icon() {
  set +e
  art_dir="$client_root/appcache/librarycache/$app_id"
  art=""
  ico=""
  if [ -n "$meta_clienticon" ]; then
    ico="$icon_root/clienticon-$meta_clienticon.ico"
    absent="$icon_root/clienticon-$meta_clienticon.absent"
    failed="$icon_root/clienticon-$meta_clienticon.failed"
    fetching="$icon_root/clienticon-$meta_clienticon.fetching"
    find "$icon_root" -maxdepth 1 -name 'clienticon-*'   ! -name "clienticon-$meta_clienticon.*" -delete 2>/dev/null || true
    find "$absent" -mtime +14 -delete 2>/dev/null || true
    find "$failed" -mmin +60 -delete 2>/dev/null || true
    find "$fetching" -mmin +2 -delete 2>/dev/null || true
    if [ ! -s "$ico" ] && [ ! -f "$absent" ] && [ ! -f "$failed" ]; then
      if [ "${icon_fetch_bg:-0}" != 1 ]; then
        fetch_client_icon
      elif (set -C; : > "$fetching") 2>/dev/null; then
        (fetch_client_icon; rm -f "$fetching") < /dev/null > /dev/null 2>&1 5>&- 7>&- 8>&- 9>&- &
        echo "client icon $meta_clienticon is downloading beside the launch, a later launch uses it" >> "$log" 2>&1 || true
      fi
    fi
    [ -s "$ico" ] && art="$ico"
  fi
  if [ -z "$art" ] && [ -n "$meta_icon" ] && [ -f "$art_dir/$meta_icon.jpg" ]; then
    art="$art_dir/$meta_icon.jpg"
  fi
  if [ -z "$art" ]; then
    art=$(find "$art_dir" -maxdepth 1 -type f -name '*.jpg' 2>/dev/null |   grep -E '/[0-9a-f]{40}\.jpg$' | head -1)
  fi
  # Capsule art (horrible) fallback if no icon at all exists...
  if [ -z "$art" ]; then
    for name in library_600x900.jpg header.jpg; do
      found=$(find "$art_dir" -name "$name" 2>/dev/null | head -1)
      [ -n "$found" ] && { art="$found"; break; }
    done
  fi
  # non-Steam shortcuts have no art, so (as a temporary measure while I think of
  # better ways to solve for this) let's use the icon in the EXE itself instead.
  if [ -z "$art" ] && [ -f "$target" ]; then
    case "$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')" in
      *.exe) art="$target" ;;
    esac
  fi
  icon_source=""
  if [ -n "$art" ]; then
    icon_source="$art $(stat -f %m "$art" 2>/dev/null || echo 0)"
  fi
  icon_cache="$icon_root/game.icns"
  icon_status=1
  if [ -n "$art" ] && [ -s "$icon_cache" ] &&   [ "$(cat "$icon_root/bridgeplay-icon.source" 2>/dev/null)" =   "$icon_source" ]; then
    icon_status=0
    echo "icon reused from $art" >> "$log" 2>&1 || true
  elif [ -n "$art" ] && [ -x "$iconmaker" ]; then
    if "$iconmaker" "$art" "$icon_cache" >> "$log" 2>&1; then
      icon_status=0
      printf '%s\n' "$icon_source" > "$icon_root/bridgeplay-icon.source"
      echo "icon built from $art" >> "$log" 2>&1 || true
    elif [ "$art" = "$ico" ]; then
      # A cached .ico that iconmaker rejects is corrupt and passes the size
      # guard on every launch, so drop it to force a clean fetch next time.
      rm -f "$ico"
      echo "discarded unreadable client icon $meta_clienticon" >> "$log" 2>&1 || true
    fi
  fi
  set -e
  return $icon_status
}

case "$verb" in
  shortcut-icons)
    app_id="$1"
    case "$app_id" in ''|0|*[!0-9]*) exit 1 ;; esac
    case "$2" in /*) ;; *) exit 1 ;; esac
    find_client_root "$2"
    icon_root="$np_support/shortcut-icons/$app_id"
    mkdir -p "$icon_root"
    log="$icon_root/icon.log"
    : > "$log"
    target=""
    read_app_meta
    resolve_icon && "$iconmaker" --shortcuts "$app_id" "$icon_cache" "$2/steam.icns" >> "$log" 2>&1 || true
    exit 0
    ;;
esac

# cxcompatdb resolves its database through CX_HOME and logs an error for
# every module loaded without it :(
export CX_HOME="$HOME/Library/Application Support/CrossOver"
np_flavor=""
np_build=""
CDPATH=''
np_tool_dir=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || np_tool_dir=""
if [ -n "$np_tool_dir" ] && [ -r "$np_tool_dir/flavor" ]; then
  read -r np_flavor < "$np_tool_dir/flavor" || np_flavor=""
fi
if [ -n "$np_tool_dir" ] && [ -r "$np_tool_dir/build" ]; then
  read -r np_build < "$np_tool_dir/build" || np_build=""
fi
case "$np_build" in *[!A-Za-z0-9.-]*) np_build="" ;; esac
np_display=$(sed -n 's/.*"display_name"[[:space:]]*"\(.*\)".*/\1/p' \
  "$np_tool_dir/compatibilitytool.vdf" 2>/dev/null | head -1) || np_display=""
[ -n "$np_display" ] || np_display="CrossOver build ${np_build:-unknown}"
CX_ROOT="$np_support/runners/crossover-$np_build/CrossOver"
export CX_ROOT
# CrossOver initializes Rosetta's Windows thread-state support even without D3DMetal.
if [ -f "$CX_ROOT/lib64/apple_gptk/external/libd3dshared.dylib" ]; then
  export CX_APPLEGPTK_LIBD3DSHARED_PATH="$CX_ROOT/lib64/apple_gptk/external/libd3dshared.dylib"
fi
# WineCX with a Game Porting Toolkit linked in keeps libd3dshared in its own lib/external.
if [ -z "${CX_APPLEGPTK_LIBD3DSHARED_PATH:-}" ] \
  && [ -f "$CX_ROOT/lib/notproton-backends/d3dmetal.enabled" ] \
  && [ -f "$CX_ROOT/lib/external/libd3dshared.dylib" ]; then
  export CX_APPLEGPTK_LIBD3DSHARED_PATH="$CX_ROOT/lib/external/libd3dshared.dylib"
fi

wine_unix="$CX_ROOT/lib/wine/aarch64-unix"
WINELOADER="$wine_unix/wine.app/Contents/MacOS/wine"
WINESERVER="$CX_ROOT/bin/wineserver-arm64"
if [ "$np_flavor" = rosetta ] || [ ! -x "$WINELOADER" ] || [ ! -x "$WINESERVER" ]; then
  wine_unix="$CX_ROOT/lib/wine/x86_64-unix"
  WINELOADER="$wine_unix/wine"
  WINESERVER="$CX_ROOT/bin/wineserver"
  [ -x "$WINESERVER" ] || WINESERVER="$CX_ROOT/bin/wineserver-x86"
fi
export WINELOADER WINESERVER

np_dropped=""
if [ "${wine_unix##*/}" = aarch64-unix ]; then
  if [ "${CX_GRAPHICS_BACKEND:-}" = d3dmetal ]; then
    unset -v CX_GRAPHICS_BACKEND
    np_dropped="CX_GRAPHICS_BACKEND=d3dmetal"
  fi
  for name in $(env | LC_ALL=C sed -nE 's/^(D3DM_[A-Z0-9_]*|ROSETTA_ADVERTISE_AVX)=.*/\1/p' | LC_ALL=C sort); do
    unset -v "$name"
    np_dropped="$np_dropped${np_dropped:+ }$name"
  done
  fex_from=environment
  [ -n "${FEX_X87REDUCEDPRECISION+x}" ] || fex_from=default
  export FEX_X87REDUCEDPRECISION="${FEX_X87REDUCEDPRECISION-1}"
else
  avx_from=environment
  [ -n "$ROSETTA_ADVERTISE_AVX" ] || avx_from=default
  export ROSETTA_ADVERTISE_AVX="${ROSETTA_ADVERTISE_AVX:-1}"
fi

# Keeps Wine from inheriting the prefix and template locks (fd 8 and 9). A redirection on a
# shell function makes /bin/sh (bash 3.2) keep a copy of the fd, at 10 or above, open in every
# program the function starts, so boot_client closes the locks on its own programs instead.
without_lock_fds() {
  if [ "$1" = boot_client ]; then "$@"; else "$@" 8>&- 9>&-; fi
}

# If two WINEDLLPATH directories have the same DLL, Wine uses the one listed first.
export WINEDLLPATH="$CX_ROOT/lib/wine/x86_64-windows:$wine_unix${WINEDLLPATH:+:$WINEDLLPATH}"
export PATH="$CX_ROOT/bin:$PATH"

# Milliseconds since 1970 in np_ms, for the step times. /bin/date has %N on macOS 27; without
# it perl, then whole seconds.
np_clock=seconds
np_ms=$(/bin/date +%s%N 2>/dev/null) || np_ms=""
case "$np_ms" in
  *[!0-9]*|'') [ ! -x /usr/bin/perl ] || ! /usr/bin/perl -MTime::HiRes -e 1 2>/dev/null || np_clock=perl-hires ;;
  *) [ "${#np_ms}" -lt 19 ] || np_clock=date-ns ;;
esac
np_now_ms() {
  case "$np_clock" in
    date-ns) np_ms=$(/bin/date +%s%N 2>/dev/null) || np_ms=""; np_ms=${np_ms%??????} ;;
    perl-hires) np_ms=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d", time * 1000' 2>/dev/null) || np_ms="" ;;
    *) np_ms=$(date +%s 2>/dev/null)000 ;;
  esac
  # Never anything set -e or the arithmetic could stop the launch on.
  case "$np_ms" in ''|*[!0-9]*) np_ms=${np_t0:-0} ;; esac
}
# Milliseconds as seconds with three decimals, in np_sec.
np_seconds() {
  [ "$1" -ge 0 ] || set -- 0
  np_sec=$(($1 % 1000))
  case "$np_sec" in [0-9]) np_sec=00$np_sec ;; [0-9][0-9]) np_sec=0$np_sec ;; esac
  np_sec="$(($1 / 1000)).$np_sec"
}
np_now_ms
np_t0=$np_ms

if [ -n "$STEAM_COMPAT_DATA_PATH" ]; then
  log="$STEAM_COMPAT_DATA_PATH/bridgeplay-run.log"
else
  log=/dev/null
fi
[ "$(stat -f %z "$log" 2>/dev/null || echo 0)" -gt 262144 ] \
  && : > "$log" || true
{
  echo "=== bridgeplay run $(date) ==="
  echo "time: steps are seconds since this run started (clock: $np_clock)"
  echo "verb=$verb"
  echo "args:"; for a in "$@"; do printf '  [%s]\n' "$a"; done
  echo "cwd=$(pwd)"
  echo "STEAM_COMPAT_DATA_PATH=$STEAM_COMPAT_DATA_PATH"
  echo "STEAM_COMPAT_INSTALL_PATH=$STEAM_COMPAT_INSTALL_PATH"
  echo "STEAM_COMPAT_APP_ID=$STEAM_COMPAT_APP_ID"
  echo "-- steam env passed through --"
  # Players attach this log to public issues, so the login name and video token stay out.
  env | grep -iE '^(Steam|SDL_)' | grep -ivE '^(SteamUser|SteamAppUser|STEAMVIDEOTOKEN)=' | sort
  [ -z "$np_dropped" ] || echo "ignored on arm64 Wine: $np_dropped"
} >> "$log" 2>&1 || true

# Wine keeps its server socket in <tmp>/.wine-<uid> and the wineserver refuses to start when
# others can read it ("must not be accessible by other users"). A directory of ours with a
# looser mode goes back to 0700. A link, or a directory someone else owns, is only reported:
# it is never followed or changed.
heal_wine_tmp() {
  wine_tmp="$1/.wine-$(id -u)"
  if [ -L "$wine_tmp" ]; then
    echo "=== warning: $wine_tmp is a symlink, left alone; wineserver may refuse to start ===" >> "$log" 2>&1 || true
    return 0
  fi
  [ -e "$wine_tmp" ] || return 0
  wine_tmp_info=$(stat -f '%u %Lp %HT' "$wine_tmp" 2>/dev/null) || return 0
  wine_tmp_owner=${wine_tmp_info%% *}
  wine_tmp_rest=${wine_tmp_info#* }
  wine_tmp_mode=${wine_tmp_rest%% *}
  wine_tmp_type=${wine_tmp_rest#* }
  if [ "$wine_tmp_type" != Directory ]; then
    echo "=== warning: $wine_tmp is not a directory ($wine_tmp_type), left alone ===" >> "$log" 2>&1 || true
    return 0
  fi
  if [ "$wine_tmp_owner" != "$(id -u)" ]; then
    echo "=== warning: $wine_tmp belongs to uid $wine_tmp_owner, left alone; wineserver may refuse to start ===" >> "$log" 2>&1 || true
    return 0
  fi
  [ "$wine_tmp_mode" != 700 ] || return 0
  # -h: should the directory have been swapped for a link since the checks, the link
  # itself changes, never what it points at.
  if chmod -h 700 "$wine_tmp" 2>> "$log"; then
    echo "=== $wine_tmp was mode $wine_tmp_mode, set to 700 ===" >> "$log" 2>&1 || true
  else
    echo "=== warning: could not set $wine_tmp to mode 700 ===" >> "$log" 2>&1 || true
  fi
}
heal_wine_tmp /tmp

# The step the launch is on, for the abort line, logged with its time.
mark() {
  stage_step=$1
  np_now_ms
  np_seconds $((np_ms - np_t0))
  echo "time: $1 at ${np_sec}s" >> "$log" 2>&1 || true
}

# How the last game launch ended, for Bridgeplay's Status page: KEY=VALUE lines, written aside
# and renamed over. code is one word from the list in docs/DEVELOPING.md, never a sentence.
# Arguments: code, game exit status (empty when it never ran), seconds it ran, who stopped it
# (steam, game or unknown), seconds to its first window (empty when the launch panel watched
# and saw none, - when nothing watched, which leaves the key out).
write_last_launch() {
  [ "$verb" = waitforexitandrun ] && [ -n "$STEAM_COMPAT_DATA_PATH" ] || return 0
  ll_file="$STEAM_COMPAT_DATA_PATH/bridgeplay-last-launch"
  rm -f "$ll_file.new" 2>/dev/null || true
  ll_window="window=$5
"
  [ "$5" != - ] || ll_window=""
  if ! { printf 'version=1\ncode=%s\nexit=%s\nseconds=%s\nstopped=%s\nbackend=%s\nengine=%s\n%sended=%s\n' \
      "$1" "$2" "$3" "$4" "${backend:-}" "${np_build:-}" "$ll_window" "$(date +%s)" > "$ll_file.new" \
    && mv -f "$ll_file.new" "$ll_file"; } 2>/dev/null; then
    rm -f "$ll_file.new" 2>/dev/null || true
    echo "=== could not record the outcome in $ll_file ===" >> "$log" 2>&1 || true
  fi
}

# Set before an exit that has its own outcome code.
np_outcome=""
mark startup
# shellcheck disable=SC2329 # the trap below invokes this
report_early_exit() {
  status=$?
  # A signal (Steam's Stop) reaches this with status 0, as does only the anti-cheat
  # prompt's exit, which sets its outcome. One the seed's traps caught carries its status.
  if [ "$status" != 0 ] && [ "${np_signalled:-0}" != 1 ]; then
    echo "=== aborted during $stage_step (exit $status) before launch ===" \
      >> "$log" 2>&1 || true
    write_last_launch "${np_outcome:-aborted}" "" 0 unknown -
  elif [ -z "$np_outcome" ]; then
    echo "=== stopped during $stage_step before launch ===" >> "$log" 2>&1 || true
    write_last_launch aborted "" 0 steam -
  else
    write_last_launch "$np_outcome" "" 0 unknown -
  fi
}
trap report_early_exit EXIT

while :; do
  case "$STEAM_COMPAT_INSTALL_PATH" in
    ?*/) STEAM_COMPAT_INSTALL_PATH="${STEAM_COMPAT_INSTALL_PATH%/}" ;;
    *) break ;;
  esac
done
export STEAM_COMPAT_INSTALL_PATH

app_id="$STEAM_COMPAT_APP_ID"
case "$app_id" in ''|0) app_id="$SteamAppId" ;; esac
case "$app_id" in ''|0) app_id=$(basename "$STEAM_COMPAT_DATA_PATH" 2>/dev/null) ;; esac
case "$app_id" in ''|*[!0-9]*) app_id=0 ;; esac
echo "app_id=$app_id (STEAM_COMPAT_APP_ID=$STEAM_COMPAT_APP_ID)" >> "$log" 2>&1 || true

# SDL has no built-in mapping for some pads (GameSir G7 Pro dongle, 3537:1022), so
# winebus hands games their raw button order. Mappings in gamecontrollerdb.txt reach
# winebus through the environment; its registry "map" loader crashes in this Wine.
# macOS Steam has no virtual gamepad Wine could read, so a pad Steam Input claims (and
# lists in SDL_GAMECONTROLLER_IGNORE_DEVICES) would reach the game as nothing. Games read
# pads directly unless the launch options set BRIDGEPLAY_RAW_CONTROLLERS=0.
if [ "${NOTPROTON_RAW_CONTROLLERS:-1}" = "1" ]; then
  NOTPROTON_RAW_CONTROLLERS=1
  SDL_GAMECONTROLLER_IGNORE_DEVICES=
  export NOTPROTON_RAW_CONTROLLERS SDL_GAMECONTROLLER_IGNORE_DEVICES
fi

# SDL hands pads that macOS GameController.framework knows (GameSir G7 Pro over Bluetooth)
# to its MFi driver, which finds nothing outside an app run loop such as winedevice.exe's,
# so the pad never reached Wine. IOKit reads them instead.
SDL_JOYSTICK_MFI=0
export SDL_JOYSTICK_MFI

# The full database, gamecontrollerdb.merged.txt from scripts/update-gamecontrollerdb.sh
# (~90 KB), reaches SDL as a file: SDL_Init reads SDL_GAMECONTROLLERCONFIG_FILE (SDL 2.0.22+),
# then the variable's lines, which outrank the file's. Only the hand-written lines ride in
# the variable, which every Wine process inherits. A runner SDL without the hint gets the
# database in the variable instead. The variable keeps the last line per GUID, newest
# first, up to pad_cap bytes.
np_pad_mappings() {
  pad_db="$np_support/gamecontrollerdb.txt"
  pad_full="$np_support/gamecontrollerdb.merged.txt"
  pad_sdl="$CX_ROOT/lib/libSDL2-2.0.0.dylib"
  pad_cap=32768
  pad_env_src=""
  if [ -f "$pad_full" ] && [ -z "$SDL_GAMECONTROLLERCONFIG_FILE" ]; then
    if [ -f "$pad_sdl" ] && LC_ALL=C grep -q -a SDL_GAMECONTROLLERCONFIG_FILE "$pad_sdl" 2>/dev/null; then
      SDL_GAMECONTROLLERCONFIG_FILE="$pad_full"
      export SDL_GAMECONTROLLERCONFIG_FILE
      echo "controllers: mapping file $pad_full" >> "$log" 2>&1 || true
    else
      pad_env_src="$pad_full"
      echo "controllers: $pad_sdl lacks SDL_GAMECONTROLLERCONFIG_FILE, $pad_full goes in the environment (capped)" >> "$log" 2>&1 || true
    fi
  fi
  [ -f "$pad_db" ] || pad_db=""
  [ -n "$pad_env_src$pad_db" ] || return 0
  # Last line per GUID, newest first until pad_cap bytes, printed in file order
  pad_maps=$(cat ${pad_env_src:+"$pad_env_src"} ${pad_db:+"$pad_db"} | tr -d '\r' \
    | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
    | awk -v cap="$pad_cap" '
      { line[NR] = $0 }
      END {
        for (i = NR; i >= 1; i--) {
          g = tolower(substr(line[i], 1, 32))
          if (g in seen) continue
          seen[g] = 1
          if (size + length(line[i]) + 1 > cap) { dropped++; continue }
          size += length(line[i]) + 1
          keep[i] = 1
        }
        for (i = 1; i <= NR; i++) if (i in keep) print line[i]
        if (dropped) printf "controllers: %d mapping(s) over the %d-byte cap dropped\n", dropped, cap > "/dev/stderr"
      }' 2>> "$log")
  [ -n "$pad_maps" ] || return 0
  if [ -n "$SDL_GAMECONTROLLERCONFIG" ]; then
    SDL_GAMECONTROLLERCONFIG="$SDL_GAMECONTROLLERCONFIG
$pad_maps"
  else
    SDL_GAMECONTROLLERCONFIG="$pad_maps"
  fi
  export SDL_GAMECONTROLLERCONFIG
  echo "controllers: $(printf '%s\n' "$pad_maps" | wc -l | tr -d ' ') mapping(s) in SDL_GAMECONTROLLERCONFIG from ${pad_env_src:+$pad_env_src }${pad_db}" >> "$log" 2>&1 || true
}
np_pad_mappings

# Settings for every game, then per-game fixes, the later file winning per key: the shipped
# gamefixes-default/default.conf, the user's gamefixes/default.conf (Game Defaults in the
# app), the shipped gamefixes-default/<appid>.conf, then the user's gamefixes/<appid>.conf.
# KEY=VALUE lines are checked against an allow-list and never sourced, and the launch
# options win over every file.
gamefix_keys=""
gamefix_backend=""
gamefix_dlloverrides=""
gamefix_msync=""
gamefix_nvapi=""
gamefix_dlss_fg=""
gamefix_args=""
gamefix_rockstar_shim=""

gamefix_log() {
  echo "gamefix: $*" >> "$log" 2>&1 || true
}

# Wine syntax: name[,name...]=[n|b|n,b|b,n|d] entries joined by semicolons.
valid_dll_overrides() {
  rest=$1
  [ -n "$rest" ] || return 1
  while [ -n "$rest" ]; do
    entry=${rest%%;*}
    case "$rest" in *';'*) rest=${rest#*;} ;; *) rest="" ;; esac
    [ -n "$entry" ] || continue
    case "$entry" in *=*) ;; *) return 1 ;; esac
    case "${entry%%=*}" in ''|,*|*,|*,,*|*[!A-Za-z0-9_.,+-]*) return 1 ;; esac
    case "${entry#*=}" in ''|n|b|d|n,b|b,n) ;; *) return 1 ;; esac
  done
}

# Prints why a pair is refused, and nothing when it is allowed.
gamefix_reason() {
  # shellcheck disable=SC2016 # the patterns match these characters literally
  case "$2" in
    *'`'*|*'$('*|*'"'*|*"'"*) echo "a backtick, \$( or a quote in the value"; return 0 ;;
    *[[:cntrl:]]*) echo "a control character in the value"; return 0 ;;
  esac
  if [ "${#2}" -gt 1024 ]; then echo "a value over 1024 characters"; return 0; fi
  case "$1" in
    BACKEND)
      case "$2" in dxmt|dxvk|wined3d|d3dmetal) ;; *) echo "not dxmt, dxvk, wined3d or d3dmetal" ;; esac ;;
    MSYNC|RETINA|NVAPI|DLSS_FG|STDOUT_NULL|VSYNC|GAME_MODE|HIDE_WINE_EXPORTS|FRAMEGEN_UI|FRAMEGEN_FALLBACK|STEAMDECK|ROCKSTAR_SHIM|FPS_LIMIT_OFF|SUSTAINED)
      case "$2" in 0|1) ;; *) echo "not 0 or 1" ;; esac ;;
    FRAMEGEN)
      # 1 is the 2x of the first release.
      case "$2" in 0|1|2|3|adaptive) ;; *) echo "not 0, 1, 2, 3 or adaptive" ;; esac ;;
    FRAMEGEN_QUALITY)
      case "$2" in performance|balanced|quality) ;; *) echo "not performance, balanced or quality" ;; esac ;;
    FRAMEGEN_ENGINE)
      case "$2" in own|metalfx) ;; *) echo "not own or metalfx" ;; esac ;;
    PERF_OVERLAY)
      case "$2" in 0|fps|summary|detailed) ;; *) echo "not 0, fps, summary or detailed" ;; esac ;;
    SCALING_FILTER)
      case "$2" in 0|linear|nearest|integer) ;; *) echo "not 0, linear, nearest or integer" ;; esac ;;
    FPS_LIMIT)
      case "$2" in
        0|display|half|[1-9][0-9]|[1-3][0-9][0-9])
          case "$2" in [1-3][0-9][0-9]) [ "$2" -le 360 ] || echo "not 0, display, half or 10 to 360" ;; esac ;;
        *) echo "not 0, display, half or 10 to 360" ;;
      esac ;;
    DLLOVERRIDES)
      valid_dll_overrides "$2" || echo "not Wine override syntax" ;;
    ARGS)
      # Space-separated arguments, each of A-Za-z0-9_+./:=,- only, so none can glob or quote.
      case "$2" in *[!A-Za-z0-9_+./:=,\ -]*) echo "an argument with characters outside A-Za-z0-9_+./:=,-" ;; esac ;;
    MTL_HUD_ENABLED|WINEDEBUG|WINE_LARGE_ADDRESS_AWARE|WINE_CPU_TOPOLOGY|CX_FWD_COMPAT_GL_CTX) ;;
    ROSETTA_ADVERTISE_AVX)
      case "$2" in 0|1) ;; *) echo "not 0 or 1" ;; esac ;;
    DXMT_?*|DXVK_?*|MVK_?*|VKD3D_?*|D3DM_?*|STAGING_?*) ;;
    *) echo "not on the allow-list" ;;
  esac
}

gamefix_read() {
  [ -f "$1" ] || return 0
  if [ ! -r "$1" ] || [ "$(stat -f %z "$1" 2>/dev/null || echo 0)" -gt 65536 ]; then
    gamefix_log "$2 conf $1 is unreadable or over 64 KiB, ignored"
    return 0
  fi
  gamefix_log "reading the $2 conf $1"
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    while :; do case "$line" in [[:space:]]*) line=${line#?} ;; *) break ;; esac; done
    while :; do case "$line" in *[[:space:]]) line=${line%?} ;; *) break ;; esac; done
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    case "$line" in
      [A-Z]*=*) case "$key" in *[!A-Z0-9_]*) key="" ;; esac ;;
      *) key="" ;;
    esac
    if [ -z "$key" ]; then
      gamefix_log "$2 conf line $lineno rejected: not KEY=VALUE"
      continue
    fi
    # The keys that set a BRIDGEPLAY_ variable also take its full name: BRIDGEPLAY_RETINA=1 is RETINA=1.
    case "$key" in
      BRIDGEPLAY_STDOUT_NULL|BRIDGEPLAY_VSYNC|BRIDGEPLAY_GAME_MODE|BRIDGEPLAY_HIDE_WINE_EXPORTS|BRIDGEPLAY_NVAPI|BRIDGEPLAY_RETINA|BRIDGEPLAY_FRAMEGEN|BRIDGEPLAY_FRAMEGEN_?*|BRIDGEPLAY_PERF_OVERLAY|BRIDGEPLAY_FPS_LIMIT|BRIDGEPLAY_FPS_LIMIT_OFF|BRIDGEPLAY_SCALING_FILTER|BRIDGEPLAY_SUSTAINED|BRIDGEPLAY_EXE|BRIDGEPLAY_EXE_FROM)
        key=${key#BRIDGEPLAY_} ;;
    esac
    value=${line#*=}
    reason=$(gamefix_reason "$key" "$value")
    if [ -n "$reason" ]; then
      gamefix_log "$2 conf line $lineno rejected $key: $reason"
      continue
    fi
    case " $gamefix_keys " in
      *" $key "*) gamefix_log "$2 conf line $lineno replaces the earlier $key" ;;
      *) gamefix_keys="${gamefix_keys:+$gamefix_keys }$key" ;;
    esac
    # key is [A-Z0-9_] only, so the eval names a variable and copies the value verbatim
    eval "gamefix_value_$key=\$value gamefix_from_$key=\$2"
  done < "$1"
}

gamefix_apply_env() {
  eval "launch_set=\${$1+x}"
  if [ -n "$launch_set" ]; then
    gamefix_log "$1 kept from the launch options, the $3 conf value is not applied"
  else
    export "$1=$2"
    gamefix_log "applied $1=$2 from the $3 conf"
  fi
}

load_gamefixes() {
  case "$app_id" in ''|0) return 0 ;; esac
  gamefix_read "$np_support/gamefixes-default/default.conf" shipped-global
  gamefix_read "$np_support/gamefixes/default.conf" global
  gamefix_read "$np_support/gamefixes-default/$app_id.conf" default
  gamefix_read "$np_support/gamefixes/$app_id.conf" user
  for key in $gamefix_keys; do
    eval "value=\$gamefix_value_$key from=\$gamefix_from_$key"
    # shellcheck disable=SC2154 # eval assigns from on the line above
    case "$key" in
      BACKEND) gamefix_backend=$value; gamefix_log "BACKEND=$value from the $from conf" ;;
      DLLOVERRIDES) gamefix_dlloverrides=$value
        gamefix_log "DLLOVERRIDES=$value from the $from conf, launch options still win per DLL" ;;
      MSYNC) gamefix_msync=$value; gamefix_log "MSYNC=$value from the $from conf" ;;
      NVAPI) gamefix_nvapi=$value; gamefix_log "NVAPI=$value from the $from conf" ;;
      DLSS_FG) gamefix_dlss_fg=$value; gamefix_log "DLSS_FG=$value from the $from conf" ;;
      ROCKSTAR_SHIM) gamefix_rockstar_shim=$value; gamefix_log "ROCKSTAR_SHIM=$value from the $from conf" ;;
      STDOUT_NULL) gamefix_apply_env NOTPROTON_STDOUT_NULL "$value" "$from" ;;
      VSYNC) gamefix_apply_env NOTPROTON_VSYNC "$value" "$from" ;;
      GAME_MODE) gamefix_apply_env NOTPROTON_GAME_MODE "$value" "$from" ;;
      HIDE_WINE_EXPORTS) gamefix_apply_env NOTPROTON_HIDE_WINE_EXPORTS "$value" "$from" ;;
      ARGS)
        if [ "$verb" = waitforexitandrun ]; then
          gamefix_args=$value
          gamefix_log "ARGS=$value from the $from conf, added after the launch options' arguments"
        else
          gamefix_log "ARGS not applied, $verb is not the game launch"
        fi ;;
      RETINA) gamefix_apply_env NOTPROTON_RETINA "$value" "$from" ;;
      # Steam reads SteamDeck in mixed case, which a conf key cannot spell.
      STEAMDECK) gamefix_apply_env SteamDeck "$value" "$from" ;;
      FRAMEGEN|FRAMEGEN_QUALITY|FRAMEGEN_UI|FRAMEGEN_FALLBACK|FRAMEGEN_ENGINE|PERF_OVERLAY|FPS_LIMIT|FPS_LIMIT_OFF|SCALING_FILTER|SUSTAINED)
        gamefix_apply_env "NOTPROTON_$key" "$value" "$from" ;;
      *) gamefix_apply_env "$key" "$value" "$from" ;;
    esac
  done
  # Report an NVIDIA GPU in Steam Properties writes BRIDGEPLAY_NVAPI, which wins over every conf.
  case "${NOTPROTON_NVAPI-}" in
    '') ;;
    0|1) gamefix_nvapi=$NOTPROTON_NVAPI; gamefix_log "NVAPI=$NOTPROTON_NVAPI from the launch options" ;;
    *) gamefix_log "BRIDGEPLAY_NVAPI in the launch options ignored: not 0 or 1" ;;
  esac
}

# Launch options > gamefix MSYNC > an engine with msync > the prefix's last choice > off.
resolve_msync() {
  msync_from=environment
  [ -z "$WINEMSYNC" ] || return 0
  engine_msync=0
  [ ! -e "$CX_ROOT/.notproton-msync" ] || engine_msync=1
  case "$gamefix_msync" in
    0) WINEMSYNC=0; msync_from=gamefix; return 0 ;;
    1)
      if [ "$engine_msync" -eq 1 ]; then WINEMSYNC=1; msync_from=gamefix; return 0; fi
      gamefix_log "MSYNC=1 not applied, the engine has no .notproton-msync" ;;
  esac
  if [ "$engine_msync" -eq 1 ]; then WINEMSYNC=1; msync_from=engine; return 0; fi
  if [ -r "$STEAM_COMPAT_DATA_PATH/notproton-msync" ]; then
    WINEMSYNC=$(tr -d ' \t\n' \
      < "$STEAM_COMPAT_DATA_PATH/notproton-msync" 2>/dev/null || true)
    msync_from=carried-over
  fi
  [ -n "$WINEMSYNC" ] || msync_from=default
}

# Graphics backends. The engine keeps Wine's own dxgi/d3d11/d3d10core/d3d12 in lib/wine and
# ships the alternatives under lib/notproton-backends/<name>/<arch>-windows, which a game
# gets as natives in its prefix. WineCX with d3dmetal.enabled has Apple's D3DMetal as those
# builtins instead and defaults to it. An engine without that folder bakes its DLLs into
# lib/wine, so nothing is swapped there.
backend_root="$CX_ROOT/lib/notproton-backends"
backend=""
backend_from=""
backend_overrides=""

graphics_log() {
  echo "graphics: $*" >> "$log" 2>&1 || true
}

# WineCX with a Game Porting Toolkit linked in: Apple's D3DMetal forwarders are the
# dxgi/d3d10/d3d11/d3d12 builtins of lib/wine, and Wine's own are set aside in
# notproton-backends/wine-stock, so wined3d is not there to fall back on.
d3dmetal_engine() {
  [ -f "$backend_root/d3dmetal.enabled" ]
}

# The lower-case module names of the DLLs in one backend folder, winemetal left to lib/wine.
backend_dlls() {
  for f in "$1"/*.[dD][lL][lL]; do
    [ -f "$f" ] || continue
    name=${f##*/}
    name=$(printf '%s' "${name%.*}" | tr '[:upper:]' '[:lower:]')
    case "$name" in ''|*[!a-z0-9_]*|winemetal) continue ;; esac
    printf '%s\n' "$name"
  done
}

# Every DLL some backend ships, so a copy one of them left in the prefix can be overridden.
managed_dlls() {
  {
    printf '%s\n' dxgi d3d11 d3d10core
    ! d3dmetal_engine || printf '%s\n' d3d10 d3d12
    for dir in "$backend_root"/*/x86_64-windows "$backend_root"/*/i386-windows; do
      # nvapi-shim, rockstar-shim and d3d12-stub are not Direct3D backends; their DLLs are
      # handled with NVAPI, ROCKSTAR_SHIM and dxmt below.
      case "$dir" in "$backend_root"/wine-stock/*|"$backend_root"/nvapi-shim/*|"$backend_root"/rockstar-shim/*|"$backend_root"/d3d12-stub/*) continue ;; esac
      [ ! -d "$dir" ] || backend_dlls "$dir"
    done
  } | sort -u
}

backend_available() {
  case "$1" in
    wined3d) ! d3dmetal_engine ;;
    d3dmetal) d3dmetal_engine ;;
    dxmt|dxvk) [ -n "$(backend_dlls "$backend_root/$1/x86_64-windows")" ] ;;
    *) return 1 ;;
  esac
}

# dxmt on a D3DMetal engine, with no d3d12 of DXMT's own. The builtin d3d12 is then Apple's,
# which reads a null pointer on DXMT's dxgi adapter before a game can fall back to D3D11
# (#2513), so d3d12-stub/ stands in for it: it answers D3D12CreateDevice like Windows on a
# GPU without D3D12.
dxmt_without_d3d12() {
  [ "$backend" = dxmt ] && d3dmetal_engine || return 1
  for f in "$backend_root"/dxmt/x86_64-windows/[dD]3[dD]12.[dD][lL][lL]; do
    [ ! -f "$f" ] || return 1
  done
}

backend_record() {
  record="$STEAM_COMPAT_DATA_PATH/notproton-backend"
  [ -n "$STEAM_COMPAT_DATA_PATH" ] && [ -f "$record" ] && [ ! -L "$record" ] || return 1
  recorded=$(sed -n 1p "$record" 2>/dev/null) || return 1
  case "$recorded" in
    dxmt|dxvk|wined3d|d3dmetal|dxmt-builtin) printf '%s' "$recorded" ;;
    *) return 1 ;;
  esac
}

# One little-endian unsigned word of 1, 2 or 4 bytes, inside the file only.
pe_word() {
  [ "$2" -ge 0 ] && [ $(($2 + $3)) -le "$pe_size" ] || return 1
  word=$(od -A n -t "u$3" -j "$2" -N "$3" "$1" 2>/dev/null | tr -d ' \n')
  case "$word" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$word"
}

# Count 4-byte words, all of them inside the file, space-separated.
pe_words() {
  [ "$2" -ge 0 ] && [ $(($2 + $3 * 4)) -le "$pe_size" ] || return 1
  od -A n -v -t u4 -j "$2" -N $(($3 * 4)) "$1" 2>/dev/null | tr -s ' \n' '  '
}

# The file offset of an RVA, from the section table words in pe_sections.
pe_rva_offset() {
  rva=$1
  # shellcheck disable=SC2086 # the table is a list of numbers and has to split
  set -- $pe_sections
  while [ "$#" -ge 10 ]; do
    span=$3
    [ "$5" -le "$span" ] || span=$5
    if [ "$rva" -ge "$4" ] && [ "$rva" -lt $(($4 + span)) ]; then
      [ $((rva - $4)) -lt "$5" ] || return 1
      offset=$((rva - $4 + $6))
      [ "$offset" -lt "$pe_size" ] || return 1
      printf '%s' "$offset"
      return 0
    fi
    shift 10
  done
  return 1
}

# A game whose exe imports d3d12.dll is D3D12, which needs Wine's own dxgi (vkd3d), since
# DXMT's dxgi refuses swap chains for devices it did not make. Only the static import
# table counts, and anything that does not parse as a PE detects nothing.
# Whether the game's exe imports d3d12.dll, worked out once per exe: per run, and with launch
# stamps across launches.
imports_d3d12() {
  pe_key="$1 $(stat -f '%d:%i:%z:%Fm:%Fc' "$1" 2>/dev/null)"
  if [ -n "${np_pe_result:-}" ] && [ "$pe_key" = "${np_pe_key:-}" ]; then
    return "$np_pe_result"
  fi
  pe_result=1
  if [ "${np_stamps_ready:-0}" = 1 ]; then
    stamp_key "$pe_key"
    if stamp_hit "pe-$verb" 0; then
      pe_result=0
    elif ! stamp_hit "pe-$verb" 1; then
      ! pe_imports_d3d12 "$1" || pe_result=0
      stamp_put "pe-$verb" "$pe_result"
    fi
  else
    ! pe_imports_d3d12 "$1" || pe_result=0
  fi
  np_pe_key=$pe_key
  np_pe_result=$pe_result
  return "$pe_result"
}

pe_imports_d3d12() {
  pe=$1
  [ -f "$pe" ] || return 1
  pe_size=$(stat -f %z "$pe" 2>/dev/null) || return 1
  [ "$(od -A n -t x1 -N 2 "$pe" 2>/dev/null | tr -d ' \n')" = 4d5a ] || return 1
  header=$(pe_word "$pe" 60 4) || return 1
  [ "$(od -A n -t x1 -j "$header" -N 4 "$pe" 2>/dev/null | tr -d ' \n')" = 50450000 ] || return 1
  section_count=$(pe_word "$pe" $((header + 6)) 2) || return 1
  optional_size=$(pe_word "$pe" $((header + 20)) 2) || return 1
  optional=$((header + 24))
  case "$(pe_word "$pe" "$optional" 2)" in
    267) directories=$((optional + 96)) ;;
    523) directories=$((optional + 112)) ;;
    *) return 1 ;;
  esac
  directory_count=$(pe_word "$pe" $((directories - 4)) 4) || return 1
  [ "$directory_count" -ge 2 ] && [ $((directories + 16)) -le $((optional + optional_size)) ] || return 1
  import_rva=$(pe_word "$pe" $((directories + 8)) 4) || return 1
  [ "$import_rva" -gt 0 ] && [ "$section_count" -ge 1 ] && [ "$section_count" -le 96 ] || return 1
  pe_sections=$(pe_words "$pe" $((optional + optional_size)) $((section_count * 10))) || return 1
  imports=$(pe_rva_offset "$import_rva") || return 1
  descriptors=$(((pe_size - imports) / 20))
  [ "$descriptors" -le 512 ] || descriptors=512
  [ "$descriptors" -ge 1 ] || return 1
  table=$(pe_words "$pe" "$imports" $((descriptors * 5))) || return 1
  # shellcheck disable=SC2086 # the table is a list of numbers and has to split
  set -- $table
  while [ "$#" -ge 5 ]; do
    [ "$1$4$5" != 000 ] || return 1
    if [ "$4" -gt 0 ] && name_at=$(pe_rva_offset "$4"); then
      module=$(dd if="$pe" bs=1 skip="$name_at" count=16 2>/dev/null \
        | LC_ALL=C tr '\0' '\n' | head -n 1 | LC_ALL=C tr '[:upper:]' '[:lower:]')
      [ "$module" != d3d12.dll ] || return 0
    fi
    shift 5
  done
  return 1
}

# BRIDGEPLAY_BACKEND > CX_GRAPHICS_BACKEND > gamefix BACKEND > auto-detect > dxmt, then down
# to what the engine has.
select_backend() {
  wanted=""
  backend_from=""
  if [ ! -d "$backend_root" ]; then
    backend=dxmt-builtin
    backend_from="legacy engine layout, no lib/notproton-backends"
    if [ -n "${NOTPROTON_BACKEND:-}$gamefix_backend" ]; then
      graphics_log "requested backend ${NOTPROTON_BACKEND:-$gamefix_backend} ignored, the engine bakes its graphics DLLs into lib/wine"
    fi
    return 0
  fi
  case "${NOTPROTON_BACKEND:-}" in
    '') ;;
    dxmt|dxvk|wined3d|d3dmetal)
      wanted=$NOTPROTON_BACKEND
      backend_from="BRIDGEPLAY_BACKEND in the launch options" ;;
    *) graphics_log "BRIDGEPLAY_BACKEND is not dxmt, dxvk, wined3d or d3dmetal, ignored" ;;
  esac
  # The Steam panel's Graphics menu writes CX_GRAPHICS_BACKEND.
  if [ -z "$wanted" ] && [ -n "${CX_GRAPHICS_BACKEND:-}" ]; then
    case "$(printf '%s' "$CX_GRAPHICS_BACKEND" | tr '[:upper:]' '[:lower:]')" in
      d3dmetal) wanted=d3dmetal ;;
      dxmt) wanted=dxmt ;;
      dxvk) wanted=dxvk ;;
      wined3d|opengl|wine) wanted=wined3d ;;
      *) graphics_log "CX_GRAPHICS_BACKEND is not a backend this engine maps, ignored" ;;
    esac
    [ -z "$wanted" ] || backend_from="CX_GRAPHICS_BACKEND in the launch options"
  fi
  if [ -z "$wanted" ] && [ -n "$gamefix_backend" ]; then
    wanted=$gamefix_backend
    # Names the layer, so a fallback from a Game Defaults choice reads as one in the log.
    backend_from="BACKEND in the ${gamefix_from_BACKEND:-gamefix} conf"
  fi
  # A helper has no game to inspect, so it keeps what the game last ran with.
  if [ -z "$wanted" ] && [ "$verb" != waitforexitandrun ] \
    && recorded=$(backend_record) && [ "$recorded" != dxmt-builtin ]; then
    wanted=$recorded
    backend_from="carried over from the last launch"
  fi
  # D3DMetal, when the engine has it, runs D3D11 and D3D12 alike and is the default.
  if [ -z "$wanted" ] && [ "$verb" = waitforexitandrun ] && [ -f "$1" ]; then
    if imports_d3d12 "$1"; then
      if d3dmetal_engine; then wanted=d3dmetal; else wanted=wined3d; fi
      backend_from="auto-detected, the game imports d3d12.dll"
    elif d3dmetal_engine; then
      wanted=d3dmetal
      backend_from="auto-detected, the engine has D3DMetal"
    else
      wanted=dxmt
      backend_from="auto-detected, the game does not import d3d12.dll"
    fi
  fi
  if [ -z "$wanted" ]; then
    if d3dmetal_engine; then wanted=d3dmetal; else wanted=dxmt; fi
    backend_from=default
  fi
  backend=$wanted
  # A conf Bridgeplay ships names a backend for the engines that have it (BACKEND=wined3d for
  # the ones without D3DMetal), so on another engine the next one is the plan, not a fallback.
  shipped_choice=""
  case "$backend_from" in "BACKEND in the default conf"|"BACKEND in the shipped-global conf")
    shipped_choice=${gamefix_from_BACKEND} ;;
  esac
  while ! backend_available "$backend"; do
    case "$backend" in
      d3dmetal) why="no d3dmetal.enabled marker"; next=dxmt ;;
      dxvk) why="no x86_64 DLLs in notproton-backends/dxvk"; next=dxmt ;;
      wined3d) why="D3DMetal replaces Wine's Direct3D in this engine"; next=d3dmetal ;;
      *)
        why="no x86_64 DLLs in notproton-backends/$backend"
        if d3dmetal_engine; then next=d3dmetal; else next=wined3d; fi ;;
    esac
    if [ -n "$shipped_choice" ]; then
      graphics_log "the $shipped_choice conf's BACKEND=$backend is for engines that have it, this one does not ($why), so the game runs on $next"
      backend_from="the $shipped_choice conf's BACKEND=$backend is for other engines"
      shipped_choice=""
    else
      graphics_log "$backend is not available ($why), falling back to $next"
      backend_from="$backend_from, fell back from $backend"
    fi
    backend=$next
  done
  # A game whose exe imports d3d12.dll is a D3D12 game.
  if [ "$verb" = waitforexitandrun ] && dxmt_without_d3d12 && imports_d3d12 "$1"; then
    graphics_log "dxmt has no Direct3D 12 and the game imports d3d12.dll, running it on d3dmetal instead"
    backend_from="$backend_from, moved to d3dmetal because the game imports d3d12.dll"
    backend=d3dmetal
  fi
}

# Wine through FEX has no D3DMetal and no Direct3D 12 (its DXMT is Direct3D 10 and 11). A game
# that needs either is told so once per prefix and build, in a notification beside the launch,
# and the log says it every launch. The Rosetta tool of the same CrossOver has both.
fex_graphics_notice() {
  [ "${wine_unix##*/}" = aarch64-unix ] && [ "$verb" = waitforexitandrun ] || return 0
  if imports_d3d12 "$1"; then
    graphics_log "the game imports d3d12.dll, and Wine through FEX has no Direct3D 12 yet, so it may quit or stay black"
    fex_title="This game needs Direct3D 12"
    fex_body="Wine through FEX can't run Direct3D 12 yet, so the game may quit or stay black. For Direct3D 12, pick this CrossOver's Rosetta tool in the game's Compatibility settings in Steam."
  else
    case " $np_dropped " in *" CX_GRAPHICS_BACKEND=d3dmetal "*) ;; *) return 0 ;; esac
    graphics_log "D3DMetal was asked for, and Wine through FEX has none, so the engine picks the graphics"
    fex_title="D3DMetal is off on FEX"
    fex_body="Wine through FEX has no D3DMetal, so the game runs without it. For D3DMetal, pick this CrossOver's Rosetta tool in the game's Compatibility settings in Steam."
  fi
  fex_mark="$STEAM_COMPAT_DATA_PATH/bridgeplay-fex-noticed"
  [ -n "$STEAM_COMPAT_DATA_PATH" ] && [ "$(sed -n 1p "$fex_mark" 2>/dev/null)" != "$np_build" ] || return 0
  printf '%s\n' "$np_build" > "$fex_mark" 2>/dev/null || true
  notify_user "$fex_title" "$fex_body"
}

# Returns 0 when the destination already matches or was replaced.
stage_backend_file() {
  [ -f "$1" ] && [ ! -d "$2" ] || return 1
  if [ -f "$2" ] && [ ! -L "$2" ] \
    && [ "$(stat -f %z "$1" 2>/dev/null)" = "$(stat -f %z "$2" 2>/dev/null)" ] \
    && cmp -s "$1" "$2"; then
    return 0
  fi
  staging="$2.notproton.$$"
  rm -f "$staging" 2>/dev/null || true
  if { cp -c -f "$1" "$staging" 2>/dev/null || cp -f "$1" "$staging" 2>> "$log"; } \
    && mv -f "$staging" "$2" 2>> "$log"; then
    graphics_log "staged ${1#"$CX_ROOT/"} as ${2#"$WINEPREFIX/"}"
    return 0
  fi
  rm -f "$staging" 2>/dev/null || true
  return 1
}

# A prefix copy identical to some backend's DLL was put there by a launch, so it goes
# back to Wine's own. Anything else in the prefix is left alone.
restore_stock_dll() {
  [ -f "$3" ] && [ ! -L "$3" ] || return 0
  # Wine's own copy, which D3DMetal moves aside. A link in lib/wine is Apple's and is
  # never copied into a prefix.
  stock="$backend_root/wine-stock/$1/$2.dll"
  [ -f "$stock" ] && [ ! -L "$stock" ] || stock="$CX_ROOT/lib/wine/$1/$2.dll"
  [ -f "$stock" ] && [ ! -L "$stock" ] || return 0
  ! cmp -s "$stock" "$3" || return 0
  # d3d12-stub counts here, so a stub the backend no longer wants goes back to Wine's d3d12.
  for theirs in "$backend_root"/*/"$1"/*.[dD][lL][lL]; do
    case "$theirs" in "$backend_root"/wine-stock/*|"$backend_root"/nvapi-shim/*|"$backend_root"/rockstar-shim/*) continue ;; esac
    [ -f "$theirs" ] || continue
    base=${theirs##*/}
    [ "$(printf '%s' "${base%.*}" | tr '[:upper:]' '[:lower:]')" = "$2" ] || continue
    if cmp -s "$theirs" "$3"; then
      stage_backend_file "$stock" "$3"
      return
    fi
  done
  return 0
}

# Copies the chosen backend's DLLs into the prefix and sets them native, and sets every
# other DLL a backend could have left there builtin.
# Every file the staging below reads or writes, and what it chose.
backend_inputs() {
  printf '%s\n' "$backend $backend_root $d3d12_stub" "$managed" "$shipped"
  ! d3dmetal_engine || echo d3dmetal
  for name in $managed; do
    stat -f '%N %d:%i:%z:%Fm:%Fc' "$WINEPREFIX/drive_c/windows/system32/$name.dll" \
      "$WINEPREFIX/drive_c/windows/syswow64/$name.dll" "$CX_ROOT/lib/wine/x86_64-windows/$name.dll" \
      "$CX_ROOT/lib/wine/i386-windows/$name.dll" 2>/dev/null || echo "$name -"
  done
  [ ! -d "$backend_root" ] || find "$backend_root" \( -type f -o -type l \) -exec stat -f '%N %d:%i:%z:%Fm:%Fc' {} + 2>/dev/null | LC_ALL=C sort
}

activate_backend() {
  backend_overrides=""
  [ "$backend" != dxmt-builtin ] || return 0
  managed=$(managed_dlls)
  shipped=""
  case "$backend" in
    dxmt|dxvk) shipped=$({ backend_dlls "$backend_root/$backend/x86_64-windows"
      backend_dlls "$backend_root/$backend/i386-windows"; } | sort -u | tr '\n' ' ') ;;
  esac
  # The stub ships with dxmt here, 64-bit only: a 32-bit game keeps the builtin.
  d3d12_stub=""
  if dxmt_without_d3d12; then
    if [ -f "$backend_root/d3d12-stub/x86_64-windows/d3d12.dll" ]; then
      d3d12_stub=d3d12
      shipped="$shipped d3d12"
    else
      graphics_log "no d3d12-stub in this engine, Apple's d3d12 stays builtin under dxmt"
    fi
  fi
  staging_failed=0
  backend_warned=0
  backend_stamped=0
  if [ "${np_stamps_ready:-0}" = 1 ]; then
    stamp_key "$(backend_inputs)"
    if stamp_hit backend; then
      backend_stamped=1
      graphics_log "$backend DLLs in the prefix unchanged since the last good launch, not staged again"
    fi
  fi
  for pair in x86_64-windows:system32 i386-windows:syswow64; do
    [ "$backend_stamped" = 0 ] || break
    arch=${pair%%:*}
    dir="$WINEPREFIX/drive_c/windows/${pair##*:}"
    [ -n "$WINEPREFIX" ] && [ -d "$dir" ] || continue
    ships=""
    case "$backend" in
      dxmt|dxvk) ships=$(backend_dlls "$backend_root/$backend/$arch" | tr '\n' ' ') ;;
    esac
    [ "$arch" != x86_64-windows ] || ships="$ships $d3d12_stub"
    for name in $managed; do
      case " $ships " in
        *" $name "*)
          src="$backend_root/$backend/$arch/$name.dll"
          [ -f "$src" ] || src="$backend_root/d3d12-stub/$arch/$name.dll"
          if ! stage_backend_file "$src" "$dir/$name.dll"; then
            graphics_log "could not stage ${src#"$backend_root/"} into the prefix"
            staging_failed=1
          fi ;;
        *)
          restore_stock_dll "$arch" "$name" "$dir/$name.dll" \
            || { backend_warned=1; graphics_log "could not restore Wine's $arch/$name.dll in the prefix"; } ;;
      esac
    done
  done
  # d3d12 is managed only on a D3DMetal engine, so a stub left from before the engine's
  # D3DMetal was unlinked goes back to Wine's copy here.
  stub="$backend_root/d3d12-stub/x86_64-windows/d3d12.dll"
  if [ "$backend_stamped" = 0 ] && ! d3dmetal_engine && [ -n "$WINEPREFIX" ] && [ -f "$stub" ] \
    && cmp -s "$stub" "$WINEPREFIX/drive_c/windows/system32/d3d12.dll"; then
    restore_stock_dll x86_64-windows d3d12 "$WINEPREFIX/drive_c/windows/system32/d3d12.dll" \
      || { backend_warned=1; graphics_log "could not restore Wine's x86_64-windows/d3d12.dll in the prefix"; }
  fi
  if [ "$staging_failed" -eq 1 ]; then
    if d3dmetal_engine; then next=d3dmetal; else next=wined3d; fi
    graphics_log "$backend could not be staged, falling back to $next"
    backend=$next
    backend_from="$backend_from, fell back after staging failed"
    activate_backend
    return
  fi
  if [ "$backend_stamped" = 0 ] && [ "$backend_warned" = 0 ] && [ "${np_stamps_ready:-0}" = 1 ]; then
    stamp_key "$(backend_inputs)"
    stamp_put backend
  fi
  native=""
  builtin=""
  for name in $managed; do
    case " $shipped " in
      *" $name "*) native="${native:+$native,}$name" ;;
      *) builtin="${builtin:+$builtin,}$name" ;;
    esac
  done
  backend_overrides="${native:+$native=n,b}"
  [ -z "$builtin" ] || backend_overrides="${backend_overrides:+$backend_overrides;}$builtin=b"
  [ -z "$d3d12_stub" ] || graphics_log "d3d12 is d3d12-stub: dxmt has no Direct3D 12, so a game that tries it first falls back to Direct3D 11"
  # A linked Game Porting Toolkit can bring Apple's nvapi64 and nvngx (DLSS on MetalFX) into
  # lib/wine. An nvapi that answers sends some games down NVIDIA-only paths, so both stay
  # disabled unless the game's conf says NVAPI=1, and then only on D3DMetal, the only
  # backend they talk to.
  if d3dmetal_engine && [ -e "$CX_ROOT/lib/wine/x86_64-windows/nvapi64.dll" ]; then
    nv_dlls=nvapi64
    [ ! -e "$CX_ROOT/lib/wine/x86_64-windows/nvngx.dll" ] || nv_dlls="nvapi64,nvngx"
    if [ "$gamefix_nvapi" = 1 ] && [ "$backend" = d3dmetal ]; then
      # Apple's nvapi reports driver 561.09, which some games call out of date (Deadlock)
      # and hide DLSS for. nvapi-shim/ goes in front as a native nvapi64 and reports a newer
      # driver (NOTPROTON_NVAPI_DRIVER), passing everything else to Apple's nvapi.dll.
      # The shim reaches Apple's nvapi by its internal name nvapi.dll, which Wine only maps to
      # the lib/wine builtin when a builtin-marked placeholder of that name is in system32.
      if stage_backend_file "$CX_ROOT/lib/wine/x86_64-windows/nvapi.dll" \
          "$WINEPREFIX/drive_c/windows/system32/nvapi.dll" \
        && stage_backend_file "$backend_root/nvapi-shim/x86_64-windows/nvapi64.dll" \
          "$WINEPREFIX/drive_c/windows/system32/nvapi64.dll"; then
        backend_overrides="${backend_overrides:+$backend_overrides;}nvapi64=n,b"
        nv_dlls=${nv_dlls#nvapi64}
        nv_dlls=${nv_dlls#,}
      fi
      [ -z "$nv_dlls" ] || backend_overrides="${backend_overrides:+$backend_overrides;}$nv_dlls=b"
      # D3DMetal reports an AMD adapter (0x1002) on its own, and games only offer DLSS on an
      # NVIDIA one. A D3DM_* value from a conf or the launch options wins.
      export D3DM_VENDOR_ID="${D3DM_VENDOR_ID:-0x10de}" D3DM_DEVICE_ID="${D3DM_DEVICE_ID:-0x2684}"
      export D3DM_DEVICE_DESCRIPTION="${D3DM_DEVICE_DESCRIPTION:-NVIDIA GeForce RTX 4090}"
      # Streamline loads an NGX core only when it is NVIDIA-signed; the engine's crypt32 and
      # wintrust answer for Apple's bridge from a signed Streamline module (ngx-signer-patch/).
      export NOTPROTON_NGX_SIGNER=1
      # wined3d (wined3d-patch/) reports this instead of its table's GeForce 8 era 31.0.13.4052,
      # which games read through d3d9 (Deadlock: driver warning, no async shader creation).
      export NOTPROTON_DRIVER_VERSION="${NOTPROTON_DRIVER_VERSION:-32.0.15.9541}"
      # DLSS frame generation wants hardware GPU scheduling; winecx's win32u reports it on
      # only for CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal (CW HACK 24905). Opt-in: frank Whisky
      # #231 saw MetalFX frame interpolation on an M5 with D3DMetal 4.0b2 hang WindowServer.
      if [ "$gamefix_dlss_fg" = 1 ]; then
        export CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal
        graphics_log "DLSS_FG=1: hardware GPU scheduling reported on for DLSS frame generation"
      fi
      graphics_log "NVAPI=1: $nv_dlls on, adapter $D3DM_VENDOR_ID:$D3DM_DEVICE_ID ($D3DM_DEVICE_DESCRIPTION)"
    else
      [ "$gamefix_nvapi" != 1 ] || graphics_log "NVAPI=1 not applied, $backend is not d3dmetal"
      backend_overrides="${backend_overrides:+$backend_overrides;}$nv_dlls=d"
    fi
  fi
  if [ "$backend" = d3dmetal ]; then
    if [ -n "${CX_GRAPHICS_BACKEND:-}" ] && [ "$CX_GRAPHICS_BACKEND" != d3dmetal ]; then
      graphics_log "CX_GRAPHICS_BACKEND=$CX_GRAPHICS_BACKEND replaced by d3dmetal"
    fi
    export CX_GRAPHICS_BACKEND=d3dmetal
  fi
}

# A copy some launch staged, from this engine's shim or another engine's build: every build
# carries the "rockstar-shim: " log prefix, which no other version.dll has.
rockstar_shim_copy() {
  [ -f "$2" ] && [ ! -L "$2" ] || return 1
  cmp -s "$1" "$2" || LC_ALL=C grep -qaF 'rockstar-shim: ' "$2"
}

# Puts the player's $2 back from $1. A dxgi.dll's note goes first, so it can never name the
# player's file; while one that would cannot be removed, the file stays in its backup.
rockstar_put_back() {
  case "$2" in */dxgi.dll)
    if ! rm -f "$2.bridgeplay-staged" 2>> "$log"; then
      sum=$(/usr/bin/shasum -a 256 "$1" 2>/dev/null | cut -d ' ' -f 1)
      [ -n "$sum" ] && ! grep -qxF -- "$sum" "$2.bridgeplay-staged" 2>/dev/null || return 1
    fi ;;
  esac
  mv "$1" "$2" 2>> "$log"
}

# DXVK's dxgi carries no such prefix and a player may copy the same release there by hand, so
# a dxgi.dll is ours only when its sha256 is one a launch noted beside it before staging. That
# also holds after an engine update changed dxgx.dll and on an engine without it.
rockstar_dxgi_copy() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ -f "$1.bridgeplay-staged" ] && [ ! -L "$1.bridgeplay-staged" ] || return 1
  sum=$(/usr/bin/shasum -a 256 "$1" 2>/dev/null | cut -d ' ' -f 1)
  [ -n "$sum" ] && grep -qxF -- "$sum" "$1.bridgeplay-staged"
}

# Writes the sha256s after $1 to the note $1, one per line. Written aside and renamed over, so
# a link another user puts at the note's name is replaced, never written through, and a note
# another user wrote is still updated. A folder at that name fails it.
rockstar_note() {
  note=$1
  shift
  if rm -f "$note.$$" && (umask 022; set -C; printf '%s\n' "$@" > "$note.$$") \
    && { [ ! -L "$note" ] || rm -f "$note"; } && [ ! -d "$note" ] && mv -f "$note.$$" "$note"; then
    return 0
  fi
  rm -f "$note.$$" 2>/dev/null || true
  return 1
}

# Opens fd $1 on the lock file $2, created readable by every macOS user sharing the folder:
# read-write when it can be (some network volumes lock only a writable fd), else read-only.
# The exclusive create never makes a file through a link another user puts there, and a
# link is never opened. The checks make the exec certain to work, since a failed one ends
# the script. No `command exec`: after one, bash 3.2 spins forever on exit.
rockstar_shim_lock_fd() {
  [ -e "$2" ] || [ -L "$2" ] || (umask 022; set -C; : > "$2") 2>/dev/null || true
  [ -f "$2" ] && [ ! -L "$2" ] && [ -r "$2" ] || return 1
  if [ -w "$2" ]; then eval "exec $1>> \"\$2\""; else eval "exec $1< \"\$2\""; fi
}

# A launch that stages the shim holds an .inuse file in the game folder locked until it
# ends, so a launch by another macOS user sharing the folder can tell the shim is in use.
# Only lockf's EX_TEMPFAIL (75) means a holder; a file it cannot open or lock says nothing.
rockstar_shim_in_use() {
  for held in "$1"/.bridgeplay-rockstar-shim.*.inuse; do
    [ -f "$held" ] && [ ! -L "$held" ] || continue
    # The mark this launch holds itself says nothing about another one.
    [ "$held" != "${own_mark:-}" ] || continue
    rc=0
    /usr/bin/lockf -k -n -s -t 0 "$held" true 2>/dev/null || rc=$?
    [ "$rc" != 75 ] || return 0
  done
  return 1
}

# Stages, removes or restores version.dll in Social Club and the game folder, and DXVK's dxgi
# as dxgi.dll in Unreal's exe folder inside it when $dxgi_wanted is 1 (under the game folder's
# lock and in-use marks). The first lock
# is per macOS user. Several users can share the game folder, so it also gets a lock of its
# own, taken only when the folder has something of the shim's in it. A volume that cannot
# hold that lock falls back to the per-user one. Exits 3 when another launch held it.
rockstar_shim_folders() {
  (
    exec 6>> "$np_support/.rockstar-shim.lock" && /usr/bin/lockf -s -t 30 6 || exit 1
    game=${STEAM_COMPAT_INSTALL_PATH:-}
    lock="$game/.bridgeplay-rockstar-shim.lock"
    # Unreal's exe (GTA San Andreas DE's SanAndreas.exe) is not in the game folder's root.
    win64="$game/Gameface/Binaries/Win64"
    game_locked=0
    busy=0
    if [ -z "$game" ] || [ ! -d "$game" ]; then
      game=""
    elif [ "$shim_wanted" = 1 ] || [ -f "$lock" ] || [ -e "$game/version.dll.bridgeplay-orig" ] \
      || [ -L "$game/version.dll.bridgeplay-orig" ] || rockstar_shim_copy "$shim/version.dll" "$game/version.dll" \
      || [ -e "$win64/version.dll.bridgeplay-orig" ] || [ -L "$win64/version.dll.bridgeplay-orig" ] \
      || rockstar_shim_copy "$shim/version.dll" "$win64/version.dll" \
      || [ -e "$win64/dxgi.dll.bridgeplay-orig" ] || [ -L "$win64/dxgi.dll.bridgeplay-orig" ] \
      || rockstar_dxgi_copy "$win64/dxgi.dll"; then
      rc=1
      if rockstar_shim_lock_fd 7 "$lock"; then rc=0; /usr/bin/lockf -s -t 30 7 || rc=$?; fi
      if [ "$rc" = 0 ]; then
        game_locked=1
      elif [ "$rc" = 75 ]; then
        graphics_log "rockstar-shim: another launch holds the lock on $game, left alone"
        game=""
        busy=1
      else
        graphics_log "rockstar-shim: could not lock $game, only this macOS user's launches take turns there"
      fi
    else
      game=""
    fi
    [ -n "$game" ] || win64=""
    for dir in "$social_club" "$game" "$win64"; do
      [ -n "$dir" ] && [ -d "$dir" ] || continue
      for name in version.dll dxgi.dll; do
        src=$shim/version.dll
        want=$shim_wanted
        if [ "$name" = dxgi.dll ]; then
          # SanAndreas.exe imports dxgi.dll statically, so DXVK's goes beside it as dxgi.dll.
          [ "$dir" = "$win64" ] || continue
          src=$shim/dxgx.dll
          want=$dxgi_wanted
        elif [ "$dir" = "$win64" ]; then
          # The shim acts only in SocialClubHelper.exe and GTA5.exe, so the exe folder never
          # gets it: a mod loader's version.dll there keeps loading. One an earlier build
          # staged comes out.
          want=0
        fi
        target="$dir/$name"
        saved="$dir/$name.bridgeplay-orig"
        is_shim=0
        if [ "$name" = dxgi.dll ]; then
          ! rockstar_dxgi_copy "$target" || is_shim=1
          # The note names a copy that is no longer there.
          [ "$is_shim" = 1 ] || rm -f "$target.bridgeplay-staged" 2>/dev/null || true
        else
          ! rockstar_shim_copy "$src" "$target" || is_shim=1
        fi
        # A launch of an older build killed between claiming the backup name and the move
        # left it empty, with the game's own file still in place. One still claiming it now
        # made it moments ago.
        if [ -f "$saved" ] && [ ! -L "$saved" ] && [ ! -s "$saved" ] \
          && { [ -e "$target" ] || [ -L "$target" ]; } && [ "$is_shim" = 0 ] \
          && [ -n "$(find "$saved" -prune -mmin +1 2>/dev/null)" ]; then
          rm -f "$saved" 2>> "$log" && graphics_log "rockstar-shim: removed an empty $name.bridgeplay-orig from $dir"
        fi
        if [ "$want" = 1 ]; then
          moved=0
          if { [ -e "$target" ] || [ -L "$target" ]; } && [ "$is_shim" = 0 ]; then
            if [ -e "$saved" ] || [ -L "$saved" ]; then
              graphics_log "rockstar-shim: $dir has its own $name and a $name.bridgeplay-orig, both left alone"
              continue
            fi
            # One rename: a killed launch leaves the file under one name or the other, never
            # an empty backup. Without the folder's lock another user's launch could rename a
            # file over it, so then the game's own file stays.
            if { [ "$dir" != "$social_club" ] && [ "$game_locked" = 0 ]; } || ! mv "$target" "$saved" 2>> "$log"; then
              graphics_log "rockstar-shim: could not set aside the $name in $dir, left alone"
              continue
            fi
            moved=1
            graphics_log "rockstar-shim: moved the $name in $dir to $name.bridgeplay-orig"
          fi
          # DXVK's dxgi is noted before it is staged, along with the copy of ours it replaces,
          # so a launch killed at any point leaves every dxgi.dll of ours known as ours.
          old=""
          if [ "$name" = dxgi.dll ]; then
            sum=$(/usr/bin/shasum -a 256 "$src" 2>/dev/null | cut -d ' ' -f 1)
            [ "$is_shim" = 0 ] || old=$(/usr/bin/shasum -a 256 "$target" 2>/dev/null | cut -d ' ' -f 1)
            if [ -z "$sum" ] || ! rockstar_note "$target.bridgeplay-staged" "$sum" ${old:+"$old"} 2>> "$log"; then
              graphics_log "rockstar-shim: could not note the dxgi.dll to stage in $dir, left as it was"
              [ "$moved" = 0 ] || rockstar_put_back "$saved" "$target" || true
              continue
            fi
          fi
          if ! stage_backend_file "$src" "$target"; then
            graphics_log "rockstar-shim: could not stage $name into $dir"
            [ "$moved" = 0 ] || rockstar_put_back "$saved" "$target" || true
          elif [ "$dir" != "$social_club" ]; then
            # Other macOS users' launches read it too.
            chmod a+r "$target" 2>/dev/null || true
            # The copy it replaced is gone.
            [ -z "$old" ] || rockstar_note "$target.bridgeplay-staged" "$sum" 2>> "$log" || true
          fi
          continue
        fi
        # The in-use marks are in the game folder, also for the exe folder inside it.
        held_in=$dir
        [ "$dir" != "$win64" ] || held_in=$game
        if rockstar_shim_in_use "$held_in"; then
          graphics_log "rockstar-shim: another launch is using the $name in $dir, left alone"
          continue
        fi
        if [ "$is_shim" = 1 ]; then
          # The note goes only with the copy it names.
          rm -f "$target" 2>> "$log" && graphics_log "rockstar-shim: removed $name from $dir" \
            && rm -f "$target.bridgeplay-staged" 2>/dev/null || true
        fi
        if [ -e "$saved" ] || [ -L "$saved" ]; then
          if [ -e "$target" ] || [ -L "$target" ]; then
            graphics_log "rockstar-shim: $dir has a new $name, $name.bridgeplay-orig left alone"
          elif rockstar_put_back "$saved" "$target"; then
            graphics_log "rockstar-shim: put the $name in $dir back"
          fi
        fi
      done
    done
    [ "$busy" = 0 ] || exit 3
    exit 0
  )
}

# Rockstar Games Launcher and GTA V Legacy (ROCKSTAR_SHIM=1, rockstar-shim/): a version.dll
# next to SocialClubHelper.exe makes the launcher's CEF windows draw on winemac, and the one
# next to the game hands GTA5.exe DXVK's dxgi on the dxvk backend. Unreal's exe folder
# (SanAndreas.exe) gets only DXVK's dxgi as dxgi.dll, as the game imports it statically. A
# version.dll or dxgi.dll of the game's own (a mod loader) is moved to <name>.bridgeplay-orig
# first. Without the key, or on an engine without the shim, the staged copy is removed and
# that file put back, unless another launch is using the folder.
stage_rockstar_shim() {
  shim="$backend_root/rockstar-shim/x86_64-windows"
  social_club="$WINEPREFIX/drive_c/Program Files/Rockstar Games/Social Club"
  shim_wanted=0
  dxgi_wanted=0
  own_mark=""
  if [ "$gamefix_rockstar_shim" = 1 ] && [ "$verb" = waitforexitandrun ]; then
    [ ! -f "$shim/version.dll" ] || shim_wanted=1
    [ "$shim_wanted" = 0 ] || [ "$backend" != dxvk ] || [ ! -f "$shim/dxgx.dll" ] || dxgi_wanted=1
  elif [ "$gamefix_rockstar_shim" = 1 ]; then
    # Helpers (verb run) leave the game's files as they are.
    return 0
  fi
  # Held before staging, so no other launch can take the shim out between the two, and kept
  # from the game's launch, so it ends with this script. One per macOS user and prefix, so
  # two prefixes on one game each hold their own.
  if [ "$shim_wanted" = 1 ] && [ -d "${STEAM_COMPAT_INSTALL_PATH:-}" ]; then
    inuse="$STEAM_COMPAT_INSTALL_PATH/.bridgeplay-rockstar-shim.$(id -u)-$(printf '%s' "${STEAM_COMPAT_DATA_PATH:-}" | cksum | cut -d ' ' -f 1)"
    # A mark the previous launch of this prefix still holds while it shuts down sends this
    # launch to a second one.
    if { rockstar_shim_lock_fd 5 "$inuse.inuse" && /usr/bin/lockf -s -t 1 5; }; then
      own_mark="$inuse.inuse"
    elif { rockstar_shim_lock_fd 5 "$inuse-2.inuse" && /usr/bin/lockf -s -t 5 5; }; then
      own_mark="$inuse-2.inuse"
    else
      graphics_log "rockstar-shim: could not mark the game folder in use"
    fi
  fi
  # Launches that share a folder (two prefixes on one game) take turns, so one cannot undo
  # a move or a restore the other is making.
  folders=0
  rockstar_shim_folders || folders=$?
  [ "$folders" != 1 ] || graphics_log "rockstar-shim: could not take the lock, version.dll left as it is"
  if [ "$shim_wanted" = 0 ]; then
    [ "$gamefix_rockstar_shim" != 1 ] || graphics_log "rockstar-shim: not in this engine, ROCKSTAR_SHIM=1 does nothing"
    return 0
  fi
  # No shim of any build in the game folder, nothing there for other launches to leave
  # alone. A folder another launch is staging keeps the mark.
  win64=""
  [ -z "${STEAM_COMPAT_INSTALL_PATH:-}" ] || win64="$STEAM_COMPAT_INSTALL_PATH/Gameface/Binaries/Win64"
  [ "$folders" = 3 ] || rockstar_shim_copy "$shim/version.dll" "${STEAM_COMPAT_INSTALL_PATH:-}/version.dll" \
    || { [ -n "$win64" ] && rockstar_shim_copy "$shim/version.dll" "$win64/version.dll"; } \
    || { [ -n "$win64" ] && rockstar_dxgi_copy "$win64/dxgi.dll"; } || exec 5>&-
  gamefix_dlloverrides="${gamefix_dlloverrides:+$gamefix_dlloverrides;}version=n,b"
  # dxgx.dll is DXVK's dxgi under a name the backend's dxgi=b does not cover.
  if [ "$backend" = dxvk ] && [ -f "$shim/dxgx.dll" ]; then
    NOTPROTON_ROCKSTAR_DXGI="Z:$(printf '%s' "$shim/dxgx.dll" | tr / '\134')"
    export NOTPROTON_ROCKSTAR_DXGI
    graphics_log "rockstar-shim: GTA5.exe gets DXVK's dxgi"
  fi
  # An Unreal game links dxgi.dll statically: DXVK's copy beside its exe, native first. Only
  # when it is there (a user's own dxgi.dll left alone is not ours to load first).
  if [ "$dxgi_wanted" = 1 ] && [ -n "$win64" ] && rockstar_shim_copy "$shim/dxgx.dll" "$win64/dxgi.dll"; then
    gamefix_dlloverrides="${gamefix_dlloverrides:+$gamefix_dlloverrides;}dxgi=n,b"
    graphics_log "rockstar-shim: DXVK's dxgi staged beside the game exe, dxgi=n,b"
  fi
}

record_backend() {
  [ -n "$STEAM_COMPAT_DATA_PATH" ] || return 0
  record="$STEAM_COMPAT_DATA_PATH/notproton-backend"
  [ ! -L "$record" ] || return 0
  previous=$(backend_record) || previous=""
  if [ -n "$previous" ] && [ "$previous" != "$backend" ]; then
    graphics_log "backend switched from $previous to $backend"
  fi
  if ! { printf '%s\n%s\n' "$backend" "$backend_from" > "$record.new" \
    && mv -f "$record.new" "$record"; } 2>/dev/null; then
    rm -f "$record.new" 2>/dev/null || true
    graphics_log "could not record the backend in $record"
  fi
}

# Last entry wins: backend, then the gamefix conf, then the launch options.
compose_dll_overrides() {
  composed=$backend_overrides
  for part in "$gamefix_dlloverrides" "${WINEDLLOVERRIDES:-}"; do
    [ -n "$part" ] || continue
    composed="${composed:+$composed;}$part"
  done
  [ -z "$composed" ] || export WINEDLLOVERRIDES="$composed"
}

load_gamefixes || true

# The in-game sidebar writes its picks to quick-settings/<app_id>.conf. Steam's own JS
# normally carries them into Steam launch options a few seconds later, but that poller only
# runs once the Compatibility or Settings page module has evaluated, so a session where the
# user never visits either page leaves the file on disk. Promote any still-pending change
# over the launch options for this run so the pick takes effect whether or not the poller
# came, and leave the file in place so another relaunch in the same situation gets the
# same value; the Steam JS poller unlinks it once it runs, and the gamefixes mirror the
# sidebar writes beside this file gives persistence after that happens. Only applied on a
# real game launch (waitforexitandrun), so the Steam helpers that also run compat_run.sh
# do not steal the pending change. The regular file check keeps a fifo or socket at this
# name from stalling the read, and symlinks at the path are refused.
consume_sidebar_quick_settings() {
  case "$app_id" in ''|0) return 0 ;; esac
  [ "${verb:-}" = waitforexitandrun ] || return 0
  qs_file="$np_support/quick-settings/$app_id.conf"
  [ -f "$qs_file" ] || return 0
  qs_mode=$(stat -f %HT "$qs_file" 2>/dev/null)
  if [ "$qs_mode" != "Regular File" ]; then
    gamefix_log "quick-settings conf $qs_file is not a regular file ($qs_mode), left in place"
    return 0
  fi
  if [ ! -r "$qs_file" ] || [ "$(stat -f %z "$qs_file" 2>/dev/null || echo 0)" -gt 4096 ]; then
    gamefix_log "quick-settings conf $qs_file is unreadable or over 4 KiB, left in place"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    while :; do case "$line" in [[:space:]]*) line=${line#?} ;; *) break ;; esac; done
    while :; do case "$line" in *[[:space:]]) line=${line%?} ;; *) break ;; esac; done
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    case "$key" in
      BRIDGEPLAY_FPS_LIMIT|BRIDGEPLAY_FPS_LIMIT_OFF|BRIDGEPLAY_PERF_OVERLAY|BRIDGEPLAY_SCALING_FILTER)
        key=${key#BRIDGEPLAY_} ;;
      *) continue ;;
    esac
    value=${line#*=}
    reason=$(gamefix_reason "$key" "$value")
    if [ -n "$reason" ]; then
      gamefix_log "quick-settings $key=$value rejected: $reason"
      continue
    fi
    # Last write wins: the sidebar's pick overrides launch options for this session.
    export "NOTPROTON_$key=$value"
    gamefix_log "applied NOTPROTON_$key=$value from the sidebar's quick-settings"
  done < "$qs_file"
}

# A failure (unlikely, but a poller rename between the check and the read could trip it)
# must never abort the launch.
consume_sidebar_quick_settings || true

# Steam gives every non-Steam shortcut a game ID ending in 0x02000000.
shortcut_game_id() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 20 ] || return 1
  high=0
  low="$1"
  if [ "${#1}" -gt 10 ]; then
    high="${1%??????????}"
    low="${1#"$high"}"
  fi
  high="${high#"${high%%[!0]*}"}"
  low="${low#"${low%%[!0]*}"}"
  [ $(( (${high:-0} % 4294967296 * 1410065408 + ${low:-0}) % 4294967296 )) = 33554432 ]
}

# Steam does not set SteamAppId or SteamGameId for helpers like the install-script
# evaluator. If they are set, SteamAPI_Init registers the helper as the running game so the
# real launch fails with AppError_16. Not applicable to non-Steam shortcuts, which come in
# as waitforexitandrun.
case "$verb" in
  waitforexitandrun)
    # Some games are poorly engineered and treat a shortcut's SteamAppID as if it were a real
    # Steam appid. Those games immediately fail Steam ownership checks rather than looking
    # inward and realizing that the actual game build that is running is a version that was
    # sold outside of Steam and that the applicable ownership checks should be performed (not
    # the Steam ones). Rockstar: do better?
    if shortcut_game_id "$SteamGameId"; then
      unset SteamAppId
    else
      [ -n "$SteamAppId" ] || export SteamAppId="$app_id"
    fi
    [ -n "$SteamGameId" ] || export SteamGameId="$app_id"
    ;;
esac

prefix_machine() {
  dll="$WINEPREFIX/drive_c/windows/system32/ntdll.dll"
  [ -f "$dll" ] || return 1
  off=$(od -A n -t u4 -j 60 -N 4 "$dll" 2>/dev/null | tr -d ' ')
  case "$off" in ''|*[!0-9]*) return 1 ;; esac
  sig=$(od -A n -t x1 -j "$off" -N 4 "$dll" 2>/dev/null | tr -d ' \n')
  [ "$sig" = 50450000 ] || return 1
  od -A n -t x2 -j "$((off + 4))" -N 2 "$dll" 2>/dev/null | tr -d ' \n'
}

tool_name() {
  case "$1" in
    aa64) printf 'FEX' ;;
    8664) printf 'Rosetta' ;;
    *) printf '32-bit' ;;
  esac
}

# CrossOver's previews are versioned by date, which reads as a release without the word.
preview_name() {
  case "$1" in
    # The date keeps its spaces and the arch its hyphen, but the dialog may only wrap
    # before the version, never inside it.
    "CrossOver 20"[0-9][0-9]" "*)
      printf 'CrossOver Preview %s' "$(printf '%s' "${1#CrossOver }" \
        | sed "s/ /$(printf '\302\240')/g; s/-/$(printf '\342\200\221')/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Tool names already end in the arch, which the sentence names on its own.
running_name() {
  run_name=$1
  case "$run_name" in *" - Rosetta" | *" - FEX") run_name=${run_name% - *} ;; esac
  printf '%s, running through %s' "$(preview_name "$run_name")" "$2"
}

# Steam passes "run" for helpers such as install scripts, which get no dialog.
show_alert() {
  [ "$verb" != run ] || return 0
  launch_step dialog
  exec 8>&- 9>&-
  osascript - "$1" "$2" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
  display alert (item 1 of argv) message (item 2 of argv) as critical
end run
APPLESCRIPT
}

# Bridgeplay's panel says the launch is still going until the game shows a window or this
# script ends, and what it is doing as launch_step writes it. It runs beside the launch and
# only reads a file, so it never holds the launch up. Later launches show it only when slow
# (LaunchProgress.swift). Without the app, a new prefix still gets the old notice.
launch_progress() {
  [ "$verb" = waitforexitandrun ] && [ "$app_id" != 0 ] || return 0
  launch_step_file="$STEAM_COMPAT_DATA_PATH/bridgeplay-launch-step"
  # The panel writes the time it saw the game's first window here, read when the game exits.
  rm -f "$STEAM_COMPAT_DATA_PATH/bridgeplay-first-window" 2>/dev/null || true
  launch_step "$1"
  progress_app=$(cat "$np_support/app-executable" 2>/dev/null) || progress_app=""
  # An app from before the panel would open its main window for a flag it does not know.
  if [ -x "$progress_app" ] && LC_ALL=C grep -q -a -F -- --launch-progress "$progress_app" 2>/dev/null; then
    # A child of this script, so the panel can tell when the script is gone.
    env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      "$progress_app" --launch-progress "$STEAM_COMPAT_DATA_PATH" "$prefix_was_new" \
      "$np_support/launchers/$app_id/bridgeplay-wine.log" "$$" \
      < /dev/null > /dev/null 2>&1 7>&- 8>&- 9>&- &
    np_panel_pid=$!
    echo "launch: progress panel started (new prefix: $prefix_was_new)" >> "$log" 2>&1 || true
  elif [ "$prefix_was_new" = 1 ]; then
    notify_user "Getting this game ready" "The first launch sets the game up and prepares its graphics. It can take a few minutes, and the screen may stay black until it is ready."
  fi
}

launch_step() {
  [ -z "${launch_step_file:-}" ] || printf '%s\n' "$1" > "$launch_step_file" 2>/dev/null || true
}

# After a game launch that went wrong, Bridgeplay's panel says why in the Status card's words,
# with one next step (LaunchEnded.swift). The app reads the record just written and decides;
# this only skips the ends that look like a normal quit. Like the rebuild, the app is
# reparented to launchd and leaves Steam's process group, so Steam shows Play at once.
# Without the app nothing is shown. Arguments: the outcome code, the record's window value.
launch_ended() {
  [ "$verb" = waitforexitandrun ] && [ "$app_id" != 0 ] && [ -n "$STEAM_COMPAT_DATA_PATH" ] || return 0
  case "$1" in
    ok | launch_services) return 0 ;;
    # Stopped after a window, or with nothing watching: a normal quit as far as anyone knows.
    stopped_from_steam) [ -z "$2" ] || return 0 ;;
  esac
  ended_app=$(cat "$np_support/app-executable" 2>/dev/null) || ended_app=""
  # An app from before the panel would open its main window for a flag it does not know.
  [ -x "$ended_app" ] && LC_ALL=C grep -q -a -F -- --launch-ended-panel "$ended_app" 2>/dev/null || return 0
  (
    env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      "$ended_app" --launch-ended-panel "$STEAM_COMPAT_DATA_PATH" \
      < /dev/null > /dev/null 2>&1 5>&- 6>&- 7>&- 8>&- 9>&- &
  )
  echo "launch: why-it-stopped panel started ($1)" >> "$log" 2>&1 || true
}

# Prints 1 when Low Power Mode is on, 0 when off, nothing when pmset does not say. pmset's
# "Currently in use" values are what ProcessInfo.isLowPowerModeEnabled reports, the lowPower
# field of compatibility reports (GameReport.swift). Macs with High Power Mode call it
# powermode (0 automatic, 1 low, 2 high).
low_power_mode() {
  pmset -g 2>/dev/null | awk '$1 == "lowpowermode" || $1 == "powermode" { seen = 1; if ($2 == "1") low = 1 }
    END { if (seen) print low ? 1 : 0 }'
}

# Low Power Mode lowers the GPU's clocks, and players do not tie that to a slow game. Says so
# once per Low Power Mode session for each macOS user: the mark goes when a launch finds it
# off. Runs beside the launch, and when pmset gives no answer nothing is shown or cleared.
low_power_notice() {
  [ "$verb" = waitforexitandrun ] || return 0
  (
    exec 8>&- 9>&-
    mark="$np_support/low-power-noticed"
    # Games starting together read pmset and change the mark one at a time, so a launch that
    # read "off" cannot remove a mark made after its read. No lock means no notice.
    exec 7>> "$np_support/.low-power.lock" && /usr/bin/lockf -s -t 5 7 || exit 0
    tell=""
    case "$(low_power_mode)" in
      0) rm -f "$mark" ;;
      1)
        echo "power: Low Power Mode is on" >> "$log" 2>&1 || true
        [ -e "$mark" ] || { : > "$mark" && tell=1; } || true
        ;;
    esac
    exec 7>&-
    [ -z "$tell" ] || notify_user "Low Power Mode is on" "Games run slower while it is on. Turn it off in System Settings > Battery, or Energy on a desktop Mac."
  ) >/dev/null 2>&1 &
}

# Posted by the Bridgeplay app, so it carries Bridgeplay's name and icon; osascript (shown
# as Script Editor) only when the app cannot be found. Never holds up the launch.
notify_user() {
  (
    exec 8>&- 9>&-
    title="Bridgeplay" subtitle=$(alert_safe "$1") body=$(alert_safe "$2")
    open -n -g -b com.bridgeplay.Bridgeplay --args --notify "$title" "$subtitle" "$body" ||
      osascript -e "display notification \"$body\" with title \"$title\" subtitle \"$subtitle\""
  ) >/dev/null 2>&1 &
}

# A quote or backslash in the text would end the AppleScript string early.
alert_safe() {
  # shellcheck disable=SC1003 # the pair deletes a literal backslash, not a quote
  printf '%s' "$1" | tr -d '"\\'
}

# The log path reaches AppleScript as an argument, so a quote in it cannot end a string.
show_rebuild_failure() {
  [ "$verb" != run ] || return 0
  launch_step dialog
  exec 8>&- 9>&-
  answer=$(osascript - "$log" <<'APPLESCRIPT'
on run argv
  set answer to display alert "Prefix rebuild failed!" message ("Check bridgeplay-run.log at " & (item 1 of argv) & ".") as critical buttons {"Open Log", "OK"} default button "OK"
  return button returned of answer
end run
APPLESCRIPT
  ) || answer=""
  [ "$answer" != "Open Log" ] || { [ -f "$log" ] && [ ! -L "$log" ] && open -t "$log" >/dev/null 2>&1; } || true
}

# Kernel anti-cheat needs a Windows driver, which Wine cannot load, so these games quit at
# start. Prints the anti-cheat's name for one of its file names, nothing otherwise.
kernel_anticheat_name() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    randgrid.sys) echo "Ricochet" ;;
    xhunter1.sys) echo "XIGNCODE3" ;;
    eaanticheat.installer.exe | eaanticheat.gameservicelauncher.exe) echo "EA Javelin" ;;
  esac
}

# The first kernel anti-cheat in a game folder, as "Name (file)". Shallow, so a large
# install does not hold up the launch.
find_kernel_anticheat() {
  [ -d "$1" ] || return 0
  find "$1" -maxdepth 3 -type f \( -iname '*.sys' -o -iname 'eaanticheat.*.exe' \) 2>/dev/null |
    while IFS= read -r ka_file; do
      ka_name=$(kernel_anticheat_name "${ka_file##*/}")
      [ -z "$ka_name" ] || { printf '%s (%s)\n' "$ka_name" "${ka_file##*/}"; break; }
    done
}

# Seconds the anti-cheat prompt waits. Steam shows the game as running until it is answered.
kernel_anticheat_wait=90

# Asks before a launch that cannot work and that could get the account banned. Only Launch
# Anyway goes ahead: Don't Launch, no answer in time or a dialog that cannot show all exit
# before Wine or the prefix is touched.
kernel_anticheat_notice() {
  [ "$verb" = waitforexitandrun ] || return 0
  ka_found=$(find_kernel_anticheat "$STEAM_COMPAT_INSTALL_PATH")
  [ -n "$ka_found" ] || return 0
  echo "anticheat: found kernel anti-cheat $ka_found, whose driver Wine cannot load" >> "$log" 2>&1 || true
  ka_status=0
  answer=$(osascript - "$ka_found" "$kernel_anticheat_wait" 8>&- 9>&- 2>> "$log" <<'APPLESCRIPT'
on run argv
  set answer to display alert "This game's anti-cheat can't run" message ("It uses " & (item 1 of argv) & ", kernel anti-cheat that needs a Windows driver. Wine cannot load it, so the game will most likely quit at start. Playing online with it is at your own risk.") as critical buttons {"Launch Anyway", "Don't Launch"} default button "Don't Launch" giving up after ((item 2 of argv) as integer)
  if gave up of answer then return "gave up"
  return button returned of answer
end run
APPLESCRIPT
  ) || ka_status=$?
  case "$ka_status:$answer" in
    "0:Launch Anyway")
      echo "anticheat: the player chose Launch Anyway" >> "$log" 2>&1 || true
      return 0
      ;;
    "0:Don't Launch") ka_why="the player chose Don't Launch" ;;
    "0:gave up") ka_why="no answer within ${kernel_anticheat_wait}s" ;;
    0:*) ka_why="the dialog returned no choice" ;;
    *) ka_why="the dialog could not be shown (exit $ka_status)" ;;
  esac
  {
    echo "=== not launched: kernel anti-cheat, $ka_why ==="
    echo "=== exit summary: not launched, stopped before Wine started ==="
    echo "=== exit cause: blocked: kernel anti-cheat $ka_found not confirmed, $ka_why ==="
  } >> "$log" 2>&1 || true
  np_outcome=anticheat_blocked
  exit 0
}

# The anti-cheat whose driver failed to load, from Wine's log.
exit_anticheat() {
  [ -f "$1" ] || return 0
  grep -a -E 'err:(module:import_dll|ntoskrnl:ZwLoadDriver)' "$1" 2>/dev/null |
    grep -a -o -i -E '[a-z0-9_.-]+\.sys' | while IFS= read -r ea_file; do
      ea_name=$(kernel_anticheat_name "$ea_file")
      [ -z "$ea_name" ] || { printf '%s (%s)\n' "$ea_name" "$ea_file"; break; }
    done
}

# Steam shows the game as running while this waits, and Stop kills the script's process
# group and children. A rebuild killed between its two renames leaves no pfx at all, so the
# app runs outside both: the inner subshell is reparented to launchd and the app calls
# setsid. The script only waits for the exit status the subshell leaves behind.
run_rebuild() {
  # A second launch can choose rebuild while this one is waiting for the app.
  rebuild_wait=$(mktemp -d "${TMPDIR:-/tmp}/bridgeplay-rebuild.XXXXXX") || return 1
  rebuild_exit="$rebuild_wait/status"
  rebuild_lock="$STEAM_COMPAT_DATA_PATH/.notproton-rebuild.lock"
  (
    (
      env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        NOTPROTON_REBUILD_WINDOW=1 \
        "$1" --rebuild-prefix "$STEAM_COMPAT_DATA_PATH" "${np_tool_dir##*/}" \
        "$np_build" "$np_flavor" "$2" >> "$log" 2>&1 < /dev/null
      echo "$?" > "$rebuild_wait/pending" && mv -f "$rebuild_wait/pending" "$rebuild_exit"
    ) &
  )
  waited=0
  while [ ! -f "$rebuild_exit" ]; do
    sleep 1
    waited=$((waited + 1))
    # Nothing holds the lock once the app is gone. The grace covers its startup.
    if [ "$waited" -gt 30 ] && /usr/bin/lockf -k -s -t 0 "$rebuild_lock" true 2>/dev/null; then
      sleep 2
      if [ ! -f "$rebuild_exit" ]; then
        rmdir "$rebuild_wait" 2>/dev/null || true
        return 1
      fi
    fi
  done
  read -r rebuild_status_code < "$rebuild_exit" || rebuild_status_code=1
  rm -f "$rebuild_exit"
  rmdir "$rebuild_wait" 2>/dev/null || true
  [ "$rebuild_status_code" = 0 ]
}

# $1 is the title, $2 the message. With $3, that button skips the rebuild and the launch goes on.
# With $4 set to keep-backup, Rebuild Prefix also keeps a backup.
rebuild_prefix() {
  # Install-script helpers must never prompt or rebuild behind the player's back.
  [ "$verb" != run ] || { [ -n "$3" ] && return 0; exit 1; }
  [ "${np_rebuilt:-0}" != 1 ] || {
    show_rebuild_failure
    exit 1
  }
  launch_step dialog
  exec 8>&- 9>&-
  # AppleScript run from a shell has no icon of its own, so caution comes badged with a folder.
  icon=$(cat "$np_support/app-executable" 2>/dev/null) || icon=""
  icon="${icon%/Contents/MacOS/*}/Contents/Resources/Bridgeplay.icns"
  [ -f "$icon" ] || icon=""
  choice=$(osascript - "$1" "$2" "${3:-Cancel}" "$icon" "${4:-}" <<'APPLESCRIPT'
on run argv
  set choices to {item 3 of argv, "Rebuild Prefix", "Backup & Rebuild Prefix"}
  set preferred to "Backup & Rebuild Prefix"
  if item 5 of argv is "keep-backup" then
    set choices to {item 3 of argv, "Rebuild Prefix"}
    set preferred to "Rebuild Prefix"
  end if
  if item 4 of argv is "" then
    set answer to display dialog (item 2 of argv) with title (item 1 of argv) buttons choices default button preferred cancel button (item 3 of argv) with icon caution
  else
    set answer to display dialog (item 2 of argv) with title (item 1 of argv) buttons choices default button preferred cancel button (item 3 of argv) with icon ((POSIX file (item 4 of argv)) as alias)
  end if
  return button returned of answer
end run
APPLESCRIPT
  ) || choice=""
  case "$choice" in
    'Backup & Rebuild Prefix') backup=keep-backup ;;
    'Rebuild Prefix')
      backup=discard-backup
      [ "$4" != keep-backup ] || backup=keep-backup
      ;;
    *)
      [ -n "$3" ] || exit 1
      prepare_prefix_directory || exit 1
      return 0
      ;;
  esac
  executable=$(cat "$np_support/app-executable" 2>/dev/null) || executable=""
  if [ ! -x "$executable" ]; then
    show_alert "Couldn't find the Bridgeplay app" "The prefix wasn't rebuilt and the game wasn't launched, because the Bridgeplay app was moved or deleted since it was installed, or was installed from a disk image or Downloads. Move Bridgeplay to Applications, open it and click Install again, then launch the game."
    exit 1
  fi
  if ! run_rebuild "$executable" "$backup"; then
    # This dialog says it failed, so the page should not say it again later. A refusal
    # because another rebuild runs left that rebuild's progress, which stays.
    rebuild_status="$STEAM_COMPAT_DATA_PATH/notproton-rebuild"
    [ "$(head -n 1 "$rebuild_status" 2>/dev/null)" != failed ] || rm -f "$rebuild_status"
    show_rebuild_failure
    exit 1
  fi
  rm -f "$STEAM_COMPAT_DATA_PATH/notproton-switch" "$STEAM_COMPAT_DATA_PATH/notproton-rebuild"
  # A competing launch or rebuild may have run while the dialog was open.
  # Retake the normal launch lock and check both mismatches before touching Wine.
  if ! prepare_prefix_directory; then
    show_alert "Prefix rebuilt" "Another launch is using this prefix. Wait for it to finish, then launch the game again."
    exit 1
  fi
  np_rebuilt=1
  note_other_build
  refuse_foreign_prefix
}

refuse_foreign_prefix() {
  case "${wine_unix##*/}" in
    aarch64-unix) want=aa64 ;;
    *) want=8664 ;;
  esac
  have=$(prefix_machine) || return 0
  [ "$have" = "$want" ] && return 0
  echo "=== prefix ntdll is $have and this compatibility tool wants $want, rebuild the prefix in Bridgeplay ===" >> "$log" 2>&1 || true
  had_tool=$(tool_name "$have")
  want_tool=$(tool_name "$want")
  explanation="$had_tool prefixes cannot be used with versions of CrossOver that run through $want_tool unless they are rebuilt."
  # note_other_build read the build that set up the prefix.
  case "$have:$had_display" in
    aa64:?* | 8664:?*)
      explanation="This game's prefix was last used by $(running_name "$had_display" "$had_tool"). $explanation"
      ;;
  esac
  rebuild_prefix "This game needs its prefix rebuilt" "$explanation

Do you want to rebuild the prefix for $(running_name "$np_display" "$want_tool")? Your save games will be preserved and not lost."
}

last_wine_build() {
  updated_file="$STEAM_COMPAT_DATA_PATH/pfx/.update-timestamp"
  [ -r "$updated_file" ] || return 0
  read -r updated _ < "$updated_file" || true
  # Wine ends the line with CRLF.
  updated=${updated%"$(printf '\r')"}
  case "$updated" in '' | *[!0-9]*) return 0 ;; esac
  [ "$updated" = "$(stat -f %m "$CX_ROOT/share/wine/wine.inf" 2>/dev/null)" ] && return 0
  had_build=other
  had_display="another version of CrossOver"
  for inf in "$np_support"/runners/crossover-*/CrossOver/share/wine/wine.inf; do
    [ "$(stat -f %m "$inf" 2>/dev/null)" = "$updated" ] || continue
    if [ "$had_build" != other ]; then
      had_build=other
      had_display="another version of CrossOver"
      break
    fi
    had_build=${inf#"$np_support/runners/crossover-"}
    had_build=${had_build%%/*}
    had_display=$(awk -F '\t' -v b="$had_build" '$2 == b { print $4; exit }' \
      "$np_support/tools" 2>/dev/null) || had_display=""
  done
}

# A prefix from another build of the same arch runs as is, in either direction. Its
# .update-timestamp no longer matches wine.inf, and Wine reruns wine.inf on first start,
# which replaces builtin DLLs and keeps native ones.
note_other_build() {
  record="$STEAM_COMPAT_DATA_PATH/notproton-build"
  had_build=""
  had_display=""
  if [ -r "$record" ]; then
    {
      read -r had_build || true
      read -r had_display || true
    } < "$record"
  else
    last_wine_build
  fi
  if [ -n "$had_build" ] && [ "$had_build" != "$np_build" ]; then
    echo "=== prefix was last run by build $had_build (${had_display:-unknown}), Wine updates it for $np_build ===" >> "$log" 2>&1 || true
    case "${wine_unix##*/}:$(prefix_machine)" in
      aarch64-unix:8664 | aarch64-unix:014c | x86_64-unix:aa64 | x86_64-unix:014c) return 0 ;;
    esac
    switch="$STEAM_COMPAT_DATA_PATH/notproton-switch"
    rm -f "$switch"
    # Only a build the game is known to have run on can be blamed for a crash after the switch.
    if [ "$(head -1 "$STEAM_COMPAT_DATA_PATH/notproton-healthy" 2>/dev/null)" = "$had_build" ]; then
      printf '%s\n%s\n0\n' "$had_build" "${had_display:-CrossOver build $had_build}" > "$switch" 2>/dev/null || true
    fi
  fi
}

# The lines Wine prints when a process dies or cannot start: what the exit summary quotes and
# what makes a session crashed.
wine_crash_pattern() {
  printf '%s' 'Unhandled (page fault|exception|illegal instruction|stack overflow)|^wine: (Call from|could not|cannot|failed)|err:module:(import_dll|LdrInitializeThunk)|wine client error'
}

# Exit statuses that are crashes, from exit_meaning and exit_signal: Windows exception codes
# and the signals of a Mac-side crash.
crash_status() {
  case "$1" in
    3|5|9|23|29|53|66|99|116|253|132|133|134|136|138|139) return 0 ;;
  esac
  return 1
}

# Healthy is a session that ran a minute or more without a crash. Failed is a crash within the
# first minute that Steam did not stop. Anything else, a quick quit without a crash too, says
# nothing about the build. Prints the word, then the reason after a comma when it is not
# healthy. Arguments: the Wine log, seconds, 1 if Steam stopped it, the exit status.
session_health() {
  crashed=0
  grep -a -q -E "$(wine_crash_pattern)" "$1" 2>/dev/null && crashed=1
  # Through Launch Services the status is open's, not the game's.
  if [ "${NOTPROTON_LAUNCH_SERVICES:-0}" != 1 ] && crash_status "${4:-0}"; then crashed=1; fi
  if [ "$crashed" = 0 ] && [ "$2" -ge 60 ]; then
    echo healthy
  elif [ "$3" = 1 ] && [ "$crashed" = 1 ]; then
    echo "unknown, stopped from Steam after a crash"
  elif [ "$3" = 1 ]; then
    echo "unknown, stopped from Steam within a minute"
  elif [ "$crashed" = 1 ] && [ "$2" -lt 60 ]; then
    echo "failed, a crash within the first minute"
  elif [ "$crashed" = 1 ]; then
    echo "unknown, a crash after the first minute"
  else
    echo "unknown, quit within a minute"
  fi
}

set_switch_state() {
  if ! { sed -n 1,2p "$switch" && printf '%s\n' "$1"; } > "$switch.$$" \
    || ! mv -f "$switch.$$" "$switch"; then
    rm -f "$switch.$$"
  fi
}

# The switch record is old build, its name, then the healthy sessions since or "failed".
# Two healthy sessions clear it.
record_session() {
  switch="$STEAM_COMPAT_DATA_PATH/notproton-switch"
  health=$(session_health "$1" "$2" "$3" "$4")
  health_why=""
  case "$health" in *", "*) health_why=", ${health#*, }"; health=${health%%, *} ;; esac
  echo "=== session health: $health after $2s$health_why ===" >> "$log" 2>&1 || true
  case "$health" in
    healthy)
      printf '%s\n' "$np_build" > "$STEAM_COMPAT_DATA_PATH/notproton-healthy" 2>/dev/null || true
      [ -f "$switch" ] || return 0
      count=$(sed -n 3p "$switch")
      case "$count" in
        0) set_switch_state 1 ;;
        *) rm -f "$switch" ;;
      esac
      ;;
    failed)
      [ -f "$switch" ] || return 0
      set_switch_state failed
      ;;
  esac
}

# Wine exits with the low byte of the Windows exit code, so 0xc0000005 arrives as 5 and
# 0xc0000135 as 53. A game can also exit with that number itself, so the summary says
# "likely". Codes not listed stay raw.
exit_meaning() {
  case "$1" in
    1) echo "a generic failure, from the game or from Wine starting it" ;;
    3) echo "abort() in the C runtime or a breakpoint, usually after the game's own error message" ;;
    5) echo "0xc0000005, an access violation: the game crashed" ;;
    9) echo "0xc0000409, the game stopped itself on a fatal error (fail fast or stack buffer overrun)" ;;
    23) echo "0xc0000417, an invalid parameter to the C runtime" ;;
    29) echo "0xc000001d, an illegal instruction, often a CPU feature the Mac does not have" ;;
    53) echo "0xc0000135, a DLL the game needs was not found" ;;
    66) echo "0xc0000142, a DLL failed to initialize" ;;
    99) echo "0xe06d7363, a C++ exception nothing caught" ;;
    116) echo "0xc0000374, heap corruption" ;;
    253) echo "0xc00000fd, a stack overflow" ;;
    255) echo "exit code -1, a failure the game reported itself" ;;
  esac
}

# The launcher is a shell, so a Wine process killed by signal N ends with 128+N. Wine
# handles the signals Windows code raises, so these come from the Mac side.
exit_signal() {
  case "$1" in
    129) echo "SIGHUP" ;;
    130) echo "SIGINT" ;;
    132) echo "SIGILL, an illegal instruction in Mac-side code" ;;
    133) echo "SIGTRAP, a trap in Mac-side code such as Wine, D3DMetal or a macOS framework" ;;
    134) echo "SIGABRT, an abort in Mac-side code such as Wine, D3DMetal or a macOS framework" ;;
    136) echo "SIGFPE, an arithmetic error in Mac-side code" ;;
    137) echo "SIGKILL, killed by macOS or another process; running out of memory is a common cause" ;;
    138) echo "SIGBUS, a crash in Mac-side code such as Wine, D3DMetal or MoltenVK" ;;
    139) echo "SIGSEGV, a crash in Mac-side code such as Wine, D3DMetal or MoltenVK" ;;
    143) echo "SIGTERM, asked to quit from outside Steam" ;;
  esac
}

# Wine's crash lines, the first three. iconv drops invalid bytes, so the run log stays UTF-8
# for the app, and keeps a home folder with an accented name whole for the report's redaction
# to match.
exit_crash_lines() {
  [ -f "$1" ] || return 0
  grep -a -E -m 3 "$(wine_crash_pattern)" \
    "$1" 2>/dev/null | LC_ALL=C tr -d '\0-\10\13-\37\177' | LC_ALL=C cut -b 1-300 | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true
}

# The outcome record's code, then who stopped the game (steam, game or unknown): the exit
# summary's account as fixed words (docs/DEVELOPING.md). Same arguments as exit_summary.
exit_outcome() {
  if [ "$3" = 1 ]; then echo "stopped_from_steam steam"; return 0; fi
  if [ "${NOTPROTON_LAUNCH_SERVICES:-0}" = 1 ]; then echo "launch_services unknown"; return 0; fi
  if [ -n "$(exit_anticheat "$4")" ]; then echo "anticheat_driver game"; return 0; fi
  case "$1" in
    129) echo "sighup unknown" ;;
    130) echo "sigint unknown" ;;
    132) echo "sigill game" ;;
    133) echo "sigtrap game" ;;
    134) echo "sigabrt game" ;;
    136) echo "sigfpe game" ;;
    137) echo "sigkill unknown" ;;
    138) echo "sigbus game" ;;
    139) echo "sigsegv game" ;;
    143) echo "sigterm unknown" ;;
    3) echo "abort game" ;;
    5) echo "access_violation game" ;;
    9) echo "fail_fast game" ;;
    23) echo "invalid_parameter game" ;;
    29) echo "illegal_instruction game" ;;
    53) echo "dll_not_found game" ;;
    66) echo "dll_init_failed game" ;;
    99) echo "cpp_exception game" ;;
    116) echo "heap_corruption game" ;;
    253) echo "stack_overflow game" ;;
    *)
      eo_crashed=0
      grep -a -q -E "$(wine_crash_pattern)" "$4" 2>/dev/null && eo_crashed=1
      if [ "$1" = 0 ] && [ "$2" -ge 60 ]; then echo "ok game"
      elif [ "$eo_crashed" = 1 ]; then echo "crashed game"
      elif [ "$1" = 0 ]; then echo "quit_early game"
      elif [ "$1" = 1 ]; then echo "generic_failure game"
      elif [ "$1" = 255 ]; then echo "game_error game"
      else echo "exit_code game"
      fi ;;
  esac
}

# How the game ended, in one line, plus Wine's crash lines. GameSession.swift reads these
# into play reports. Arguments: exit status, seconds, 1 if Steam stopped it, the Wine log.
exit_summary() {
  if [ "$2" -ge 120 ]; then es_took="$(($2 / 60)) min"; else es_took="${2}s"; fi
  es_signal=$(exit_signal "$1")
  es_meaning=$(exit_meaning "$1")
  if [ "$3" = 1 ]; then
    es_how="stopped from Steam"
  elif [ "${NOTPROTON_LAUNCH_SERVICES:-0}" = 1 ]; then
    es_how="started through Launch Services, so the status is open's and not the game's"
  elif [ -n "$es_signal" ]; then
    es_how="Wine was likely killed by $es_signal"
  elif [ "$1" = 0 ] && [ "$2" -lt 60 ]; then
    es_how="the game quit by itself within a minute without an error code, usually after its own error message"
  elif [ "$1" = 0 ]; then
    es_how="the game quit normally"
  elif [ -n "$es_meaning" ]; then
    es_how="the game quit by itself (likely $es_meaning)"
  else
    es_how="the game quit by itself"
  fi
  printf '=== exit summary: exit status %s after %s, %s ===\n' "$1" "$es_took" "$es_how"
  es_anticheat=$(exit_anticheat "$4")
  [ -z "$es_anticheat" ] || printf '=== exit cause: kernel anti-cheat %s could not load its Windows driver, which Wine cannot run, so the game will not start ===\n' "$es_anticheat"
  exit_crash_lines "$4" | while IFS= read -r es_line; do
    printf '=== exit cause: %s ===\n' "$es_line"
  done
  # winedbg's "has encountered a serious problem" dialog holds the game open until closed.
  if grep -a -q -E 'starting debugger|exe=winedbg' "$4" 2>/dev/null; then
    echo "=== exit note: Wine started its crash handler, whose error dialog can sit behind the game ==="
  fi
}

# Milliseconds since 1970 at which the launch panel saw the game's first window, from the file
# it writes in compatdata $1 (LaunchProgress.swift).
first_window_ms() {
  fw_ms=$(sed -n 1p "$1/bridgeplay-first-window" 2>/dev/null) || return 1
  case "$fw_ms" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$fw_ms"
}

# The same for the first Metal drawable, from the overlay shim's line in the Wine log $1. A
# call that got no drawable is not a frame.
first_frame_ms() {
  ff_ms=$(grep -a -m 1 -o 'overlay_shim hook_next_drawable: .* drawable=yes t=[0-9]*' "$1" 2>/dev/null | sed 's/.* t=//')
  case "$ff_ms" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$ff_ms"
}

# Succeeds while process $1 runs; a zombie has ended.
process_running() {
  pr_stat=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  case "$pr_stat" in ''|Z*) return 1 ;; esac
}

# The game's times since its start, which was $1 in milliseconds since 1970; it exited at $2.
# Sets np_window to the whole seconds to its first window: empty when the launch panel was
# still watching when the game exited ($4 is 1) and saw none, - when nothing watched (no app,
# or the panel's time limit). $3 is the Wine log.
launch_times() {
  np_seconds $(($2 - np_t0))
  echo "time: game exited at ${np_sec}s"
  np_window=-
  if lt_ms=$(first_window_ms "$STEAM_COMPAT_DATA_PATH"); then
    [ "$lt_ms" -ge "$1" ] || lt_ms=$1
    np_window=$(((lt_ms - $1) / 1000))
    np_seconds $((lt_ms - $1))
    echo "time: first window ${np_sec}s after the game started"
  elif [ "${4:-0}" = 1 ]; then
    np_window=""
    echo "time: no first window noted"
  else
    echo "time: first window not measured, the launch panel was not watching"
  fi
  if lt_ms=$(first_frame_ms "$3"); then
    [ "$lt_ms" -ge "$1" ] || lt_ms=$1
    np_seconds $((lt_ms - $1))
    echo "time: first frame ${np_sec}s after the game started"
  fi
}

# Asked once per switch, at the next launch after the crash.
offer_switch_rebuild() {
  switch="$STEAM_COMPAT_DATA_PATH/notproton-switch"
  [ "$(sed -n 3p "$switch" 2>/dev/null)" = failed ] || return 0
  [ "$verb" != run ] || return 0
  old_display=$(sed -n 2p "$switch")
  case "${wine_unix##*/}" in
    aarch64-unix) now_arch=aa64 ;;
    *) now_arch=8664 ;;
  esac
  rm -f "$switch"
  echo "=== last session crashed after switching from $old_display, offering a rebuild ===" >> "$log" 2>&1 || true
  rebuild_prefix "This game may need its prefix rebuilt" \
    "Something appears to have gone wrong the last time you ran this game! Rebuilding the prefix may fix it.

Rebuild your prefix for $(running_name "$np_display" "$(tool_name "$now_arch")")? Your save games will be preserved and not lost." \
    "Launch Without Rebuilding"
}

claim_prefix() {
  [ -r "$STEAM_COMPAT_DATA_PATH/notproton-build" ] \
    || echo "=== prefix claimed by build $np_build ===" >> "$log" 2>&1 || true
  printf '%s\n%s\n' "$np_build" "$np_display" > "$STEAM_COMPAT_DATA_PATH/notproton-build" 2>/dev/null \
    || echo "=== could not record build $np_build in the prefix ===" >> "$log" 2>&1 || true
}
# Wine prefixes are only tested on APFS (and HFS+). Every run logs the file system so a
# report from an exFAT or network library says so; a new prefix there also tells the player.
volume_type() {
  device=$(stat -f %Sd "$1" 2>/dev/null) || return 1
  mount | sed -n "s|^/dev/$device on \(.*\) (\([^,)]*\).*|\2 \1|p" | head -1
}

note_prefix_volume() {
  vol=$(volume_type "$STEAM_COMPAT_DATA_PATH") || vol=""
  fs=${vol%% *}
  echo "volume: compatdata on ${fs:-unknown} (${vol#* })" >> "$log" 2>&1 || true
  case "$fs" in apfs|hfs|"") return 0 ;; esac
  echo "=== compatdata is on $fs, not APFS: Wine prefixes are only tested on APFS, games may hang or fail to start ===" \
    >> "$log" 2>&1 || true
  [ "$prefix_was_new" = 1 ] || return 0
  notify_user "This Steam library is not on APFS" "It is formatted $fs. Games run from it may hang or fail to start. Move the game to a library on an APFS drive for the best results."
}

# Without C:\windows\system32 Wine stops at "could not load kernel32.dll" and the game quits
# with no window. exFAT and FAT have no symbolic links, so dosdevices/c: cannot exist there.
# A prefix with only some DLLs (see missing_core_dll) quits with "Library ... not found".
# Offers to rebuild a broken prefix and sets broken_rebuilt=1 once it is rebuilt; ends the
# launch otherwise. A second broken check after a rebuild shows the rebuild failure and exits.
refuse_broken_prefix() {
  broken_rebuilt=0
  missing=$(missing_core_dll "$WINEPREFIX/dosdevices/c:/windows") || return 0
  printf '=== the prefix has no C:\\windows\\%s, Wine did not finish building it ===\n' "$missing" \
    >> "$log" 2>&1 || true
  [ "$verb" != run ] || exit 1
  if [ "${np_rebuilt:-0}" = 1 ]; then
    show_rebuild_failure
    exit 1
  fi
  vol=$(volume_type "$STEAM_COMPAT_DATA_PATH") || vol=""
  fs=${vol%% *}
  case "$fs" in exfat|msdos|ntfs)
    show_alert "This Steam library cannot hold the game's prefix" "It is formatted $fs, which has no symbolic links, so Wine cannot set up the game here. Move the game to a library on an APFS drive."
    exit 1
  esac
  # Wine reports a full disk only as error=112 on each file it could not copy.
  free_kb=$(df -Pk "$STEAM_COMPAT_DATA_PATH" 2>/dev/null | awk 'NR == 2 { print $4 }')
  if [ -n "$free_kb" ] && [ "$free_kb" -lt 2097152 ]; then
    show_alert "The disk is too full for the game's prefix" "Wine needs about 2 GB free to set up the game. Free some space on the drive that holds this Steam library, then rebuild the prefix in Bridgeplay."
    exit 1
  fi
  # set_up_prefix_contents runs reg import, which can leave wineserver holding the prefix
  # while Bridgeplay tries to claim it for the rebuild.
  if [ -n "$WINESERVER" ]; then
    np_boot_fp=""
    without_lock_fds "$WINESERVER" -k >> "$log" 2>&1 || true
    without_lock_fds "$WINESERVER" -w >> "$log" 2>&1 || true
  fi
  # The rebuild skips system.reg, which may contain game data.
  rebuild_prefix "The game's prefix could not be set up" "Wine did not finish building it, so the game can't start. Rebuild the prefix now? Bridgeplay will keep a backup of the old prefix." "" keep-backup
  broken_rebuilt=1
}

# Steam keeps a game's prefix in the library that holds the game, so a game moved to another
# library starts over with an empty one: saves and launcher sign-ins kept only in the old
# prefix seem lost. Names the old one when a new prefix is about to be built.
steam_libraries() {
  for vdf in "$client_root/steamapps/libraryfolders.vdf" "$client_root/config/libraryfolders.vdf"; do
    [ -f "$vdf" ] || continue
    sed -nE 's/^[[:space:]]*"path"[[:space:]]*"(.*)"[[:space:]]*$/\1/p' "$vdf" | sed 's/\\\\/\\/g'
    return 0
  done
}

note_other_prefixes() {
  [ "$prefix_was_new" = 1 ] && [ "$app_id" != 0 ] || return 0
  here=$(cd -P -- "$STEAM_COMPAT_DATA_PATH" 2>/dev/null && pwd) || return 0
  old_prefix=""
  while IFS= read -r library; do
    [ -n "$library" ] || continue
    other="$library/steamapps/compatdata/$app_id"
    [ -f "$other/pfx/system.reg" ] || continue
    there=$(cd -P -- "$other" 2>/dev/null && pwd) || continue
    [ "$there" != "$here" ] || continue
    echo "=== an older prefix for this game is in another library: $other ===" >> "$log" 2>&1 || true
    [ -n "$old_prefix" ] || old_prefix=$other
  done <<EOF_LIBRARIES
$(steam_libraries)
EOF_LIBRARIES
  [ -n "$old_prefix" ] || return 0
  notify_user "This game starts with a new prefix" "Its earlier prefix is still in $old_prefix. Saves or launcher sign-ins kept only there are not in the new one."
}

# Steam cloud related
merge_user_dir() {
  src=$1
  dst=$2
  failed=
  set -- ""
  while [ "$#" -gt 0 ]; do
    rest=$1
    shift
    src_dir="$src$rest"
    dst_dir="$dst$rest"
    if [ ! -r "$src_dir" ] || [ ! -x "$src_dir" ]; then failed=1; continue; fi
    if [ -L "$dst_dir" ]; then failed=1; continue; fi
    probe=$dst_dir
    through=
    while [ -n "$probe" ] && [ "$probe" != "$dst" ]; do
      if [ -L "$probe" ]; then through=1; break; fi
      probe=${probe%/*}
    done
    if [ -n "$through" ]; then
      echo "=== $rest is held by a link, merge refused ===" >> "$log" 2>&1 || true
      failed=1
      continue
    fi
    if [ -e "$dst_dir" ] && [ ! -d "$dst_dir" ]; then
      failed=1
      continue
    fi
    if ! mkdir -p "$dst_dir" 2>/dev/null; then failed=1; continue; fi
    for entry in "$src_dir"/* "$src_dir"/.[!.]* "$src_dir"/..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      name=${entry##*/}
      if [ -d "$entry" ] && [ ! -L "$entry" ]; then
        set -- "$@" "$rest/$name"
        continue
      fi
      landing="$dst_dir/$name"
      if [ -e "$landing" ] || [ -L "$landing" ]; then
        if [ -L "$entry" ] && [ -L "$landing" ] \
          && [ "$(readlink "$entry")" = "$(readlink "$landing")" ]; then continue; fi
        if [ -f "$entry" ] && [ ! -L "$entry" ] && [ -f "$landing" ] \
          && [ ! -L "$landing" ] && cmp -s "$entry" "$landing"; then continue; fi
        echo "=== conflicting profile file: $landing ===" >> "$log" 2>&1 || true
        failed=1
        continue
      fi
      if [ -L "$entry" ]; then
        if ! cp -Ppn "$entry" "$landing" 2>/dev/null; then
          failed=1
        fi
      else
        if ! cp -pn "$entry" "$landing" 2>/dev/null || ! cmp -s "$entry" "$landing"; then
          failed=1
        fi
        chmod u+w "$landing" 2>/dev/null || true
      fi
    done
  done
  [ -z "$failed" ]
}

# Steam Cloud stuff
migrate_user_paths() {
  profile=$1
  migration_failed=0
  for pair in \
    "Local Settings/Application Data|AppData/Local|../AppData/Local" \
    "Application Data|AppData/Roaming|./AppData/Roaming" \
    "My Documents|Documents|./Documents"; do
    old_rel=${pair%%|*}
    rest=${pair#*|}
    new_rel=${rest%%|*}
    link=${rest#*|}
    old="$profile/$old_rel"
    new="$profile/$new_rel"
    case "$(readlink "$new" 2>/dev/null || true)" in
      *"drive_c/users/steamuser/$old_rel") rm -f "$new" 2>/dev/null || true ;;
    esac
    if [ -L "$new" ]; then
      echo "=== $new_rel is a link, rebuild the prefix for cloud saves ===" \
        >> "$log" 2>&1 || true
      migration_failed=1
      continue
    fi
    held=
    for rel in "$old_rel" "$new_rel"; do
      probe=$rel
      while [ "$probe" != "${probe%/*}" ]; do
        probe=${probe%/*}
        if [ -L "$profile/$probe" ]; then held=$probe; break; fi
      done
      if [ -n "$held" ]; then break; fi
    done
    if [ -n "$held" ]; then
      echo "=== $held is a link, rebuild the prefix for cloud saves ===" \
        >> "$log" 2>&1 || true
      migration_failed=1
      continue
    fi
    if [ -e "$old" ] && [ ! -L "$old" ]; then
      if ! merge_user_dir "$old" "$new"; then
        echo "=== $old_rel did not merge into $new_rel, left in place ===" \
          >> "$log" 2>&1 || true
        migration_failed=1
        continue
      fi
      backup="$old BACKUP"
      backup_number=2
      while [ -e "$backup" ] || [ -L "$backup" ]; do
        backup="$old BACKUP $backup_number"
        backup_number=$((backup_number + 1))
      done
      if ! mv "$old" "$backup" 2>> "$log"; then
        echo "=== $old_rel could not be moved aside, cloud saves stay split ===" \
          >> "$log" 2>&1 || true
        migration_failed=1
        continue
      fi
    fi
    if [ ! -e "$old" ] && [ ! -L "$old" ]; then
      mkdir -p "${old%/*}" 2>/dev/null || true
      ln -s "$link" "$old" 2>/dev/null \
        || echo "=== $old_rel could not be aliased onto $new_rel ===" >> "$log" 2>&1 \
        || true
    elif [ -L "$old" ] && [ "$(readlink "$old")" != "$link" ]; then
      rm -f "$old" 2>/dev/null || true
      ln -s "$link" "$old" 2>/dev/null \
        || echo "=== $old_rel could not be aliased onto $new_rel ===" >> "$log" 2>&1 \
        || true
    fi
  done
  [ "$migration_failed" -eq 0 ]
}

lay_out_proton_profile() {
  users="${1:-$WINEPREFIX}/drive_c/users"
  if [ -d "$users/crossover" ] && [ ! -L "$users/crossover" ]; then
    echo "=== prefix predates the steamuser layout, rebuild it for cloud saves ===" \
      >> "$log" 2>&1 || true
    return 0
  fi
  profile="$users/steamuser"
  if [ -L "$profile" ]; then
    echo "=== the profile is a link, rebuild the prefix for cloud saves ===" \
      >> "$log" 2>&1 || true
    return 0
  fi
  mkdir -p "$profile" 2>/dev/null || return 0
  for folder in Documents Desktop Downloads Music Pictures Videos Templates \
      AppData/Local AppData/Roaming; do
    mkdir -p "$profile/$folder" 2>/dev/null || true
  done
  migrate_user_paths "$profile" || return 1
  if [ -L "$users/crossover" ] && [ ! -e "$users/crossover" ]; then
    rm -f "$users/crossover" 2>/dev/null || true
  fi
  if [ ! -e "$users/crossover" ] \
    && ln -s steamuser "$users/crossover" 2>/dev/null; then
    echo "=== pointed crossover at steamuser ===" >> "$log" 2>&1 || true
  fi
  fold_wine_profile
}

# Stock Wine (the WineHQ engine) names the profile after the Mac user, where CrossOver's
# lineage uses crossover. Same rule as set_home_dir in Wine's ntdll/unix/loader.c.
wine_profile_name() {
  case "$np_build" in winehq-*) ;; *) return 1 ;; esac
  wine_user=${USER:-}
  [ -n "$wine_user" ] || wine_user=$(id -un 2>/dev/null) || return 1
  wine_user=${wine_user##*/}
  wine_user=${wine_user##*\\}
  case "$(printf '%s' "$wine_user" | tr '[:upper:]' '[:lower:]')" in
    ''|.|..|steamuser|crossover|public) return 1 ;;
  esac
  printf '%s' "$wine_user"
}

present() { [ -e "$1" ] || [ -L "$1" ]; }

# The name in $1 that $2 matches ignoring case, else $2. A case-sensitive volume keeps
# "Saves" and "saves" apart, but Wine reads them as one.
fold_landing() {
  # Listed from inside, so only "./<name>" lines are names; a newline in one cannot pass
  # for another name once checked on disk.
  matches=$(cd -P -- "$1" 2>/dev/null && find . -mindepth 1 -maxdepth 1 | want=$2 awk '
    substr($0, 1, 2) == "./" && tolower(substr($0, 3)) == tolower(ENVIRON["want"]) {
      print substr($0, 3)
    }') || matches=""
  while IFS= read -r found; do
    if [ -n "$found" ] && present "$1/$found"; then
      printf '%s' "$1/$found"
      return 0
    fi
  done <<EOF_MATCHES
$matches
EOF_MATCHES
  printf '%s' "$1/$2"
}

# Renames $1 to the free name $2. mv puts it inside a folder that appeared at $2 since the
# check, so the inode says where it went, and a move that nested goes back. Each move is
# noted first, relative to users so a moved library still matches, and the next launch puts
# back one that a killed launch left nested. No move starts while one is unresolved.
fold_move() {
  ! present "$fold_record" || return 1
  # The note is one path per line, so a name with a line break stays put.
  case "${1#"$users"/}${2#"$users"/}" in *'
'*)
    echo "=== ${1#"$users"/} has a line break in its name, rename it to move it into steamuser ===" \
      >> "$log" 2>&1 || true
    return 1 ;;
  esac
  moving=$(stat -f %i "$1" 2>/dev/null) || return 1
  printf '%s\n%s\n%s\n' "$moving" "${1#"$users"/}" "${2#"$users"/}" > "$fold_record" || return 1
  mv -n "$1" "$2" 2>> "$log" || return 1
  fold_unnest
}

# Puts back the move noted by fold_move if it went inside a folder at its target's name.
# Returns 0 only for a move that landed. The note goes only once the file is found where it
# landed or where it started; while it is anywhere else the note stays and launches stop.
fold_unnest() {
  present "$fold_record" || return 0
  fold_moved="" fold_source="" fold_target=""
  if [ -f "$fold_record" ] && [ ! -L "$fold_record" ]; then
    { IFS= read -r fold_moved && IFS= read -r fold_source && IFS= read -r fold_target; } \
      < "$fold_record" || true
  fi
  case "/$fold_source/:/$fold_target/" in
    *//*|*/../*|*/./*) fold_moved="" ;;
  esac
  case "$fold_moved" in ''|*[!0-9]*)
    # Only a note, never a file a game wrote: dropping it leaves every save where it is.
    echo "=== dropped an unreadable note of a move into steamuser ===" >> "$log" 2>&1 || true
    rm -f "$fold_record" 2>/dev/null || true
    return 1 ;;
  esac
  fold_source="$users/$fold_source"
  fold_target="$users/$fold_target"
  if [ "$(stat -f %i "$fold_target" 2>/dev/null)" = "$fold_moved" ] && ! present "$fold_source"; then
    rm -f "$fold_record"
    return 0
  fi
  fold_nested="$fold_target/${fold_source##*/}"
  if [ "$(stat -f %i "$fold_nested" 2>/dev/null)" = "$fold_moved" ] && ! present "$fold_source"; then
    # A killed launch may have left the source's folder gone.
    mkdir -p "${fold_source%/*}" 2>/dev/null || true
    mv -n "$fold_nested" "$fold_source" 2>> "$log" || true
    if [ "$(stat -f %i "$fold_source" 2>/dev/null)" = "$fold_moved" ]; then
      echo "=== put back ${fold_source#"$users"/}, which went inside a folder at its name ===" \
        >> "$log" 2>&1 || true
    fi
  fi
  # A move put back, or one that never happened, did not land.
  if [ "$(stat -f %i "$fold_source" 2>/dev/null)" = "$fold_moved" ]; then
    rm -f "$fold_record"
  else
    echo "=== ${fold_source#"$users"/} is not where its move left it; put it back, then delete $fold_record ===" \
      >> "$log" 2>&1 || true
  fi
  return 1
}

fold_inside_profile() {
  fold_resolved=$(cd -P -- "$1" 2>/dev/null && pwd) || return 1
  fold_profile=$(cd -P -- "$profile" 2>/dev/null && pwd) || return 1
  case "$fold_resolved/" in "$fold_profile"/?*) return 0 ;; esac
  return 1
}

# Moves what is in $1 into $2. Renames only, so a launch killed partway leaves every file
# whole on one side or the other. A file that differs from the one already in $2 is kept
# beside it as "<name> BACKUP" and printed. Fails if anything could not move.
fold_user_dir() (
  status=0
  # Unreadable, the folder would look empty and be dropped from the live profile.
  [ -r "$1" ] && [ -x "$1" ] || exit 1
  for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    present "$entry" || continue
    landing="$2/${entry##*/}"
    if [ "$fold_case" = 1 ] && ! present "$landing"; then
      landing=$(fold_landing "$2" "${entry##*/}")
    fi
    if ! present "$landing"; then
      fold_move "$entry" "$landing" || status=1
      continue
    fi
    # Wine's links out to the Mac's home folders: what is behind them stays there.
    [ ! -L "$entry" ] || continue
    # A link inside steamuser (My Documents to Documents) is merged through, as
    # migrate_user_paths does; one that leads out of the profile is not.
    if [ -d "$entry" ] && [ -d "$landing" ] && { [ ! -L "$landing" ] || fold_inside_profile "$landing"; }; then
      if fold_user_dir "$entry" "$landing"; then
        rmdir "$entry" 2>/dev/null || true
      else
        status=1
      fi
      continue
    fi
    # The live name, then "<name> BACKUP", "<name> BACKUP 2"...: a copy already there is
    # dropped, otherwise the first free name takes it.
    parked=$landing
    parked_number=1
    while present "$parked"; do
      if [ -f "$entry" ] && [ -f "$parked" ] && [ ! -L "$parked" ] && cmp -s "$entry" "$parked"; then
        rm -f "$entry" || status=1
        continue 2
      fi
      parked="$landing BACKUP"
      [ "$parked_number" -eq 1 ] || parked="$parked $parked_number"
      parked_number=$((parked_number + 1))
    done
    if fold_move "$entry" "$parked"; then
      printf '%s\n' "$parked"
    else
      status=1
    fi
  done
  exit "$status"
)

# Steam Cloud syncs users/steamuser, so a profile under the Mac user's name splits a game's
# saves from its cloud saves (#2618). Folds it into steamuser and links the name there.
fold_wine_profile() {
  wine_user=$(wine_profile_name) || return 0
  fold_record="$users/.notproton-fold-moving"
  fold_unnest || true
  if present "$fold_record"; then
    echo "=== an earlier move into steamuser could not be put back ===" >> "$log" 2>&1 || true
    return 1
  fi
  own="$users/$wine_user"
  if [ -L "$own" ]; then
    [ "$(readlink "$own")" = steamuser ] \
      || echo "=== users/$wine_user is a link elsewhere, cloud saves may be split ===" >> "$log" 2>&1 \
      || true
    return 0
  fi
  [ ! "$own" -ef "$profile" ] || return 0
  if [ -e "$own" ]; then
    if [ ! -d "$own" ]; then
      echo "=== users/$wine_user is not a folder, cloud saves may be split ===" >> "$log" 2>&1 || true
      return 0
    fi
    fold_case=1
    [ ! "$users/STEAMUSER" -ef "$profile" ] || fold_case=0
    leftover=""
    if fold_parked=$(fold_user_dir "$own" "$profile"); then
      find "$own" -depth -type d -empty -delete 2>/dev/null || true
      # Only Wine's links out to the Mac's home folders may be left.
      if present "$own"; then
        leftover=$(find "$own" ! -type d ! -type l 2>&1) || leftover=unreadable
      fi
    else
      leftover=unmoved
    fi
    if [ -n "$fold_parked" ]; then
      printf '%s\n' "$fold_parked" | sed 's/^/=== kept both copies, this one as: /; s/$/ ===/' \
        >> "$log" 2>&1 || true
    fi
    if [ -n "$leftover" ]; then
      echo "=== users/$wine_user did not all move into steamuser, left in place ===" \
        >> "$log" 2>&1 || true
      return 1
    fi
    fold_homes=""
    if present "$own"; then
      # What a game saved through these is in the Mac's home folders, and stays there.
      fold_homes=$(find "$own" -type l 2>/dev/null) || fold_homes=""
      printf '%s\n' "$fold_homes" | while IFS= read -r home_link; do
        [ -n "$home_link" ] || continue
        echo "=== ${home_link#"$users"/} led to $(readlink "$home_link"), whose files stay there ===" \
          >> "$log" 2>&1 || true
      done
      # Kept as a pointer to the Mac's home folders the links lead to.
      aside="$own BACKUP"
      aside_number=2
      while present "$aside"; do
        aside="$own BACKUP $aside_number"
        aside_number=$((aside_number + 1))
      done
      mv -n "$own" "$aside" 2>> "$log" || return 1
    fi
    echo "=== moved users/$wine_user into steamuser, where Steam Cloud syncs ===" >> "$log" 2>&1 || true
    fold_note=""
    [ -z "$fold_parked" ] \
      || fold_note="Files that differed from Steam Cloud's copy were kept beside it with BACKUP in the name."
    [ -z "$fold_homes" ] \
      || fold_note="${fold_note:+$fold_note }Files the game kept in your Mac's Documents and other home folders stay there."
    [ -z "$fold_note" ] || notify_user "Saved games moved to where Steam Cloud syncs" "$fold_note"
  fi
  ln -s steamuser "$own" 2>/dev/null \
    || echo "=== could not point users/$wine_user at steamuser ===" >> "$log" 2>&1 || true
}

controller_ids() {
  printf '%s\n' "$1" | tr ',' '\n' | tr 'A-F' 'a-f' \
    | sed -n 's/^[[:space:]]*0x\([0-9a-f]\{4\}\)\/0x\([0-9a-f]\{4\}\)[[:space:]]*$/\1\/\2/p' \
    | sort -u
}

ids_without() {
  printf '%s\n' "$2" -- "$1" \
    | awk '$0 == "--" { s = 1; next } !s { b[$0]; next } $0 != "" && !($0 in b)'
}

hidraw_lines() {
  printf '%s\n' "$2" | while read -r id; do
    [ -n "$id" ] || continue
    if [ "$1" = add ]; then
      printf '%s\r\n' "[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus\\Devices\\$id]" \
        '"Hidraw"=dword:00000000' ''
    else
      printf '%s\r\n' "[-HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\WineBus\\Devices\\$id]" ''
    fi
  done
}

write_owned_controllers() {
  if printf '%s\n' "$1" | sed '/^$/d' | sort -u > "$controllers_file.new" \
    && mv -f "$controllers_file.new" "$controllers_file"; then
    return 0
  fi
  rm -f "$controllers_file.new"
  return 1
}

# Proton hides the controllers that Steam Input handles from the Wine process. CrossOver
# still reads a few directly (DualSense, DualShock 4, Switch 1 Pro Controller and Joy-Cons),
# so Hidraw=0 hides those too. The Switch controllers get Hidraw=0 even when Steam Input
# is off, to avoid silently breaking controller support in most games.
plan_hidden_controllers() {
  controllers_file="$STEAM_COMPAT_DATA_PATH/notproton-hidden-controllers"
  controllers_add=""
  controllers_remove=""
  controllers_wanted=""
  [ -n "$STEAM_COMPAT_DATA_PATH" ] && [ ! -L "$controllers_file" ] || return 1
  owned=""
  [ ! -f "$controllers_file" ] || owned=$(sed -n '/^[0-9a-f]\{4\}\/[0-9a-f]\{4\}$/p' "$controllers_file")
  in_registry=""
  [ ! -f "$WINEPREFIX/system.reg" ] || in_registry=$(tr '[:upper:]' '[:lower:]' < "$WINEPREFIX/system.reg" \
    | sed -n 's/^\[system\\\\controlset001\\\\services\\\\winebus\\\\devices\\\\\([0-9a-f]\{4\}\/[0-9a-f]\{4\}\)\].*/\1/p' \
    | sort -u)
  if [ "$NOTPROTON_RAW_CONTROLLERS" != "1" ]; then
    controllers_wanted=$(ids_without "$(controller_ids "$SDL_GAMECONTROLLER_IGNORE_DEVICES")" \
      "$(controller_ids "$SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT")")
    controllers_wanted=$(printf '%s\n' "$controllers_wanted" 057e/2006 057e/2007 057e/2009 | sed '/^$/d' | sort -u)
    # Steam sends install scripts no ignore list. Keep the game's hidden controllers instead of clearing them.
    if [ "$verb" = run ]; then
      controllers_wanted=$(printf '%s\n' "$controllers_wanted" "$owned" | sed '/^$/d' | sort -u)
    fi
    controllers_wanted=$(ids_without "$controllers_wanted" "$(ids_without "$in_registry" "$owned")")
  fi
  controllers_add=$(ids_without "$controllers_wanted" "$in_registry")
  controllers_remove=$(ids_without "$owned" "$controllers_wanted")
  write_owned_controllers "$owned
$controllers_wanted"
}

# Sets Wine's DisableHidraw for games with "Disable hidraw" checked. When it's
# unchecked, the value is removed only if Bridgeplay set it.
plan_disable_hidraw() {
  hidraw_file="$STEAM_COMPAT_DATA_PATH/notproton-disable-hidraw"
  hidraw_value=""
  [ -n "$STEAM_COMPAT_DATA_PATH" ] && [ ! -L "$hidraw_file" ] || return 1
  hidraw_set=""
  [ ! -f "$WINEPREFIX/system.reg" ] || hidraw_set=$(tr '[:upper:]' '[:lower:]' < "$WINEPREFIX/system.reg" \
    | awk '/^\[/ { s = index($0, "[system\\\\controlset001\\\\services\\\\winebus]") == 1; next }
      s && $0 == "\"disablehidraw\"=dword:00000001" { print 1; exit }')
  if [ "$NOTPROTON_DISABLE_HIDRAW" = "1" ]; then
    [ -n "$hidraw_set" ] || hidraw_value='"DisableHidraw"=dword:00000001'
  elif [ -f "$hidraw_file" ] && [ -n "$hidraw_set" ]; then
    hidraw_value='"DisableHidraw"=-'
  fi
}

winebus_lines() {
  [ -n "$hidraw_value" ] || return 0
  printf '%s\r\n' '[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\WineBus]' "$hidraw_value" ''
}

# High Resolution doubles LogPixels and turning it off halves it
plan_logpixels() {
  dpi_value=""
  new_dpi=""
  read -r retina_was dpi <<EOF
$({ [ ! -f "$WINEPREFIX/user.reg" ] || tr '[:upper:]' '[:lower:]' < "$WINEPREFIX/user.reg"; } | awk '
  /^\[/ { s = 0
    if (index($0, "[software\\\\wine\\\\mac driver]") == 1) s = 1
    else if (index($0, "[control panel\\\\desktop]") == 1) s = 2
    next }
  s == 1 && $0 ~ /^"retinamode"="[yt1]/ { r = 1 }
  s == 2 && $0 ~ /^"logpixels"=dword:[0-9a-f]+$/ && length($0) <= 26 { d = substr($0, 19) }
  END { print r + 0, d }')
EOF
  [ -n "$dpi" ] || [ ! -f "$WINEPREFIX/system.reg" ] || dpi=$(tr '[:upper:]' '[:lower:]' < "$WINEPREFIX/system.reg" \
    | awk '/^\[/ { s = index($0, "[system\\\\controlset001\\\\hardware profiles\\\\current\\\\software\\\\fonts]") == 1; next }
      s && $0 ~ /^"logpixels"=dword:[0-9a-f]+$/ && length($0) <= 26 { print substr($0, 19); exit }')
  dpi=$((0x${dpi:-0}))
  [ "$dpi" -gt 0 ] || dpi=96
  if [ "$NOTPROTON_RETINA" = "1" ]; then
    [ "$retina_was" = 1 ] && [ "$dpi" -ge 110 ] || [ "$dpi" -gt 2147483647 ] || new_dpi=$((dpi * 2))
  elif [ "$retina_was" = 1 ]; then
    new_dpi=$((dpi / 2))
    [ "$new_dpi" -ge 96 ] || new_dpi=96
  fi
  [ -z "$new_dpi" ] || [ "$new_dpi" -eq "$dpi" ] || dpi_value=$(printf '"LogPixels"=dword:%08x' "$new_dpi")
}

video_lines() {
  [ "$verb" = waitforexitandrun ] || return 0
  printf '%s\r\n' '[HKEY_CURRENT_USER\Software\Wine\Mac Driver]' "$retina_line" ''
  [ -n "$dpi_value" ] || return 0
  printf '%s\r\n' '[HKEY_CURRENT_USER\Control Panel\Desktop]' "$dpi_value" ''
}

import_prefix_settings() {
  if [ "$NOTPROTON_RETINA" = "1" ]; then
    retina_line='"RetinaMode"="y"'
  else
    retina_line='"RetinaMode"=-'
  fi
  dpi_value=""
  controllers_planned=0
  if plan_hidden_controllers 2>/dev/null; then
    controllers_planned=1
  else
    controllers_add=""
    controllers_remove=""
    echo "=== could not track the hidden controllers, leaving them as they are ===" >> "$log" 2>&1 || true
  fi
  hidraw_planned=0
  if plan_disable_hidraw 2>/dev/null; then
    hidraw_planned=1
    if [ "$NOTPROTON_DISABLE_HIDRAW" = "1" ] && [ -n "$hidraw_value" ]; then
      : > "$hidraw_file" 2>/dev/null || hidraw_value=""
    fi
  else
    hidraw_value=""
    echo "=== could not track DisableHidraw, leaving it as it is ===" >> "$log" 2>&1 || true
  fi
  # Steam sends install scripts no launch options, so they keep the game's video settings.
  if [ "$verb" = waitforexitandrun ]; then
    plan_logpixels 2>/dev/null || dpi_value=""
  fi
  settings_file=$(mktemp "$WINEPREFIX/drive_c/notproton-settings.XXXXXX" 2>/dev/null) \
    || settings_file=""
  if [ -z "$settings_file" ] || ! { printf '%s\r\n' \
      'Windows Registry Editor Version 5.00' '' \
      '[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\AeDebug]' '"Auto"="0"' '' \
      '[HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug]' '"Auto"="0"' '' \
      '[HKEY_CURRENT_USER\Software\Wine\WineDbg]' '"ShowCrashDialog"=dword:00000000' '' \
      && video_lines && printf '%s\r\n' \
      '[HKEY_LOCAL_MACHINE\Software\Classes\steam]' '"URL Protocol"=""' '' \
      '[HKEY_LOCAL_MACHINE\Software\NVIDIA Corporation\Global\NGXCore]' \
      '"FullPath"="C:\\Windows\\System32"' '' \
      '[HKEY_LOCAL_MACHINE\Software\Classes\steam\shell\open\command]' \
      '@="\"C:\\Program Files (x86)\\Steam\\steam.exe\" \"%1\""' '' \
      && hidraw_lines add "$controllers_add" && hidraw_lines remove "$controllers_remove" \
      && winebus_lines; } \
      > "$settings_file" 2>/dev/null; then
    [ -z "$settings_file" ] || rm -f "$settings_file"
    echo "=== could not write the prefix settings, launching without them ===" >> "$log" 2>&1 || true
    # the bridge staging still needs a built prefix
    without_lock_fds ${np_boot_client:+"$np_boot_client"} "$WINELOADER" wineboot --init >> "$log" 2>&1 || true
    return 0
  fi
  without_lock_fds ${np_boot_client:+"$np_boot_client"} "$WINELOADER" reg import "C:\\${settings_file##*/}" >> "$log" 2>&1 \
    && import_status=0 || import_status=$?
  rm -f "$settings_file"
  if [ "$import_status" -eq 0 ] && [ "$hidraw_planned" -eq 1 ] && [ "$NOTPROTON_DISABLE_HIDRAW" != "1" ]; then
    rm -f "$hidraw_file"
  fi
  if [ "$import_status" -eq 0 ] && [ -n "$controllers_add$controllers_remove$hidraw_value$dpi_value" ]; then
    # Wine only reads these keys when it starts, so restart Wine to apply them.
    np_boot_fp=""
    without_lock_fds "$WINESERVER" -k >> "$log" 2>&1 || true
    without_lock_fds "$WINESERVER" -w >> "$log" 2>&1 || true
  fi
  if [ "$import_status" -eq 0 ] && [ "$hidraw_planned" -eq 1 ] && [ "$NOTPROTON_DISABLE_HIDRAW" = "1" ]; then
    echo "controllers: hidraw disabled (BRIDGEPLAY_DISABLE_HIDRAW=1)" >> "$log" 2>&1 || true
  fi
  if [ "$import_status" -eq 0 ] && [ -n "$dpi_value" ]; then
    echo "video: LogPixels=$new_dpi" >> "$log" 2>&1 || true
  fi
  if [ "$import_status" -eq 0 ] && [ "$controllers_planned" -eq 1 ]; then
    write_owned_controllers "$controllers_wanted" 2>/dev/null || true
    if [ "$NOTPROTON_RAW_CONTROLLERS" = "1" ]; then
      echo "controllers: games read them directly (BRIDGEPLAY_RAW_CONTROLLERS=1)" >> "$log" 2>&1 || true
    elif [ -n "$controllers_wanted" ]; then
      echo "controllers: $(printf '%s\n' "$controllers_wanted" | grep -c .) kept off hidraw" \
        >> "$log" 2>&1 || true
    fi
  fi
  [ "$import_status" -eq 0 ] \
    || echo "=== prefix settings import exited status=$import_status ===" >> "$log" 2>&1 || true
}

mark "runner check"
if [ -z "$np_build" ] || [ ! -d "$CX_ROOT/lib/wine" ]; then
  echo "=== build ${np_build:-(none recorded)} behind this compatibility tool is not set up, set it up in Bridgeplay ===" >> "$log" 2>&1 || true
  show_alert "CrossOver is not set up" "The CrossOver build behind $(alert_safe "$np_display") is not set up. Set it up in Bridgeplay, or pick another compatibility tool for this game."
  np_outcome=engine_missing
  exit 1
fi
echo "runner: build $np_build ($np_display) at $CX_ROOT" >> "$log" 2>&1 || true

# Whether the engine's loader starts at all: wine --version stops before any prefix or server.
engine_loader_runs() {
  without_lock_fds "$WINELOADER" --version >> "$log" 2>&1 < /dev/null
}

# Succeeds when macOS is older than $1.$2.
macos_before() {
  /usr/bin/sw_vers -productVersion 2>/dev/null \
    | awk -F . -v major="$1" -v minor="$2" '{ found = 1; old = ($1 + 0 < major || ($1 + 0 == major && $2 + 0 < minor)) }
      END { exit !(found && old) }'
}

# Intel Wine needs Rosetta 2; without it every Wine call fails with "Bad CPU type" and the
# prefix check misreports it as a broken prefix. macOS updates can drop Rosetta.
mark "rosetta check"
case "$(/usr/bin/file -b "$WINESERVER" 2>/dev/null)" in
  *arm64*)
    # ARM64 Wine needs what macOS 26.5 added (CrossOver falls back to Rosetta before it).
    if [ "${wine_unix##*/}" = aarch64-unix ] && macos_before 26 5 && ! engine_loader_runs; then
      echo "=== Wine through FEX did not start: it needs macOS 26.5 or later ===" >> "$log" 2>&1 || true
      show_alert "This tool needs macOS 26.5" "$(alert_safe "$(preview_name "${np_display% - FEX}")") runs Windows games through FEX, which needs macOS 26.5 or later. Update macOS, or pick this CrossOver's Rosetta tool in the game's Compatibility settings in Steam."
      np_outcome=engine_unsupported
      exit 1
    fi
    ;;
  *)
    # Probing a Mac tool can fail where the engine still runs (macOS 28's game test mode keeps
    # Rosetta for games only), so the engine's own loader decides.
    if ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
      if engine_loader_runs; then
        echo "=== arch -x86_64 failed, but the engine's loader runs, so Rosetta is there for it ===" >> "$log" 2>&1 || true
      else
        echo "=== Rosetta 2 is not installed, Wine cannot run: softwareupdate --install-rosetta --agree-to-license ===" >> "$log" 2>&1 || true
        show_alert "Rosetta 2 is not installed" "Windows games need Rosetta 2, and this Mac does not have it (a macOS update can remove it). Install it in Terminal with: softwareupdate --install-rosetta --agree-to-license, then launch the game again."
        np_outcome=rosetta_missing
        exit 1
      fi
    fi
    ;;
esac

# Each CrossOver build needs its own template.
# FEX builds need two, one for FEX/arm64 Wine and one for Rosetta/AMD64 Wine
runner_id=""
[ -z "$np_build" ] || runner_id="crossover-$np_build-${wine_unix##*/}"

in_template_env() {
  prefix="$1"
  shift
  without_lock_fds \
    env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" TMPDIR="${TMPDIR:-/tmp}" \
    LANG="${LANG:-}" LC_ALL="${LC_ALL:-}" \
    PATH="$CX_ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin" CX_ROOT="$CX_ROOT" CX_HOME="$CX_HOME" \
    WINEDLLPATH="$CX_ROOT/lib/wine/x86_64-windows:$wine_unix" \
    WINELOADER="$WINELOADER" WINESERVER="$WINESERVER" WINEPREFIX="$prefix" "$@"
}

seed_scratch=""
seed_building=0
seed_merging=0
# shellcheck disable=SC2329 # the traps in seed_prefix_from_template invoke this
abandon_seed() {
  # A signal, as Steam's Stop sends: the exit status it carries is not a failure.
  np_signalled=1
  if [ -n "$seed_scratch" ]; then
    if [ "$seed_building" -eq 1 ]; then
      in_template_env "$seed_scratch" "$WINESERVER" -k >/dev/null 2>&1 || true
      in_template_env "$seed_scratch" "$WINESERVER" -w >/dev/null 2>&1 || exit "$1"
    fi
    # Half moved into the prefix: finish now, or keep the rest for the next launch to finish.
    if [ "$seed_merging" -eq 0 ] || { unnest_seed_entry && merge_seed_tree move; }; then
      rm -rf "$seed_scratch" 2>/dev/null || true
    fi
  fi
  exit "$1"
}

prefix_server_dir() {
  [ -n "${1:-$WINEPREFIX}" ] || return 1
  ids=$(stat -f '%d-%i' "${1:-$WINEPREFIX}" 2>/dev/null) || return 1
  [ -n "$ids" ] || return 1
  # Callers lsof and kill -9 whatever is open under this path: refuse a link or a folder
  # another macOS user planted in the shared /tmp.
  for owned in "/tmp/.wine-$(id -u)" \
    "/tmp/.wine-$(id -u)/server-$(printf '%x-%x' "${ids%-*}" "${ids#*-}")"; do
    [ ! -L "$owned" ] || return 1
    [ ! -e "$owned" ] || [ "$(stat -f %u "$owned" 2>/dev/null)" = "$(id -u)" ] || return 1
  done
  printf '%s' "$owned"
}

# A leftover named after a live pid is another launch's, unless the pid is ours: macOS gave
# a dead launch's pid to this one, and this launch has not made its own folder yet.
seed_owner_alive() {
  [ "$1" != "$$" ] && kill -0 "$1" 2>/dev/null
}

sweep_dead_seeds() {
  for leftover in "$@"; do
    [ -d "$leftover" ] && [ ! -L "$leftover" ] || continue
    case "${leftover##*.}" in ''|0|*[!0-9]*) continue ;; esac
    [ "$(stat -f %u "$leftover" 2>/dev/null)" = "$(id -u)" ] || continue
    seed_owner_alive "${leftover##*.}" && continue
    stale_server=$(prefix_server_dir "$leftover") || continue
    if [ -d "$stale_server" ]; then
      stale_users=$(lsof -t +D "$stale_server" 2>&1 || true)
      [ -z "$stale_users" ] || continue
    fi
    rm -rf "$leftover" 2>/dev/null || true
  done
}

same_volume() {
  one=$(stat -f %d "$1" 2>/dev/null) || return 1
  two=$(stat -f %d "$2" 2>/dev/null) || return 1
  [ "$one" = "$two" ]
}

# On non-APFS file systems, a full copy is made rather than a clone.
volume_clones() {
  device=$(stat -f %Sd "$1" 2>/dev/null) || return 1
  mount | grep -q "^/dev/$device on .* (apfs[,)]"
}

# Prints the first of a few core DLLs missing under a Windows folder, as system32\name.dll.
# wineboot copies the DLLs one by one: on a full disk (error=112) or after a crash it still
# writes the registry and the early DLLs, and later ones such as user32.dll are missing
# (#4025, #3927). The 32-bit side is checked when the prefix has one.
missing_core_dll() (
  for side in system32 syswow64; do
    [ "$side" = system32 ] || [ -d "$1/$side" ] || continue
    for name in kernel32 mspatcha ucrtbase user32 version win32u ws2_32; do
      [ -f "$1/$side/$name.dll" ] || { printf '%s\\%s.dll' "$side" "$name"; return 0; }
    done
  done
  return 1
)

# Built in a temporary folder and renamed when the build finishes, so a broken template is never used
build_prefix_template() {
  sweep_dead_seeds "$template_dir"/pfx.building.*
  seed_scratch="$template_dir/pfx.building.$$"
  mkdir "$seed_scratch" || return 1
  echo "=== building the prefix template for $runner_id ===" >> "$log" 2>&1 || true
  # The Steam user folders have to exist before wineboot runs, or wineboot will make its own
  # and cloud saves end up in the wrong place.
  lay_out_proton_profile "$seed_scratch" || return 1
  seed_building=1
  in_template_env "$seed_scratch" "$WINELOADER" wineboot --init >> "$log" 2>&1 &
  initialized=0
  wait $! || initialized=$?
  in_template_env "$seed_scratch" "$WINESERVER" -w >> "$log" 2>&1 &
  if ! wait $!; then
    echo "=== template server did not finish, leaving its staging folder intact ===" >> "$log" 2>&1 || true
    seed_scratch=""
    seed_building=0
    return 1
  fi
  seed_building=0
  if [ "$initialized" -ne 0 ] || [ ! -s "$seed_scratch/system.reg" ] \
    || [ ! -s "$seed_scratch/user.reg" ] || [ ! -s "$seed_scratch/userdef.reg" ] \
    || missing_core_dll "$seed_scratch/drive_c/windows" >/dev/null; then
    echo "=== wineboot did not finish the template, this game gets its own prefix ===" \
      >> "$log" 2>&1 || true
    rm -rf "$seed_scratch" 2>/dev/null || true
    seed_scratch=""
    return 1
  fi
  if [ ! -e "$template_dir/pfx" ] && [ ! -L "$template_dir/pfx" ]; then
    mv "$seed_scratch" "$template_dir/pfx" 2>/dev/null || true
  fi
  rm -rf "$seed_scratch" 2>/dev/null || true
  seed_scratch=""
  [ -f "$template_dir/pfx/system.reg" ]
}

# Puts back a staged folder that mv put inside a folder that appeared at its name since the
# check. Each folder move is noted first, so this also works after a launch killed mid-move.
unnest_seed_entry() {
  placing="$seed_scratch/.notproton-seed-placing"
  [ -s "$placing" ] || return 0
  # Cut short while it was noted, so the move never started.
  { read -r staged && read -r source && read -r target; } < "$placing" || { : > "$placing"; return 0; }
  case "$source:$target" in "$seed_scratch"/*:"$WINEPREFIX"/*) ;; *) return 1 ;; esac
  nested="$target/${source##*/}"
  if [ "$(stat -f %i "$target" 2>/dev/null)" != "$staged" ] \
    && [ "$(stat -f %i "$nested" 2>/dev/null)" = "$staged" ]; then
    mv -n "$nested" "$source" && [ ! -e "$nested" ] || return 1
  fi
  : > "$placing"
}

# Puts one staged entry at a free name in the prefix, never over something that appeared
# there since the check: link(2) and symlink(2) refuse an existing name, and a folder that
# appeared takes ours inside it, which goes back to staging.
place_seed_entry() {
  if [ -d "$1" ] && [ ! -L "$1" ]; then
    staged=$(stat -f %i "$1") || return 1
    printf '%s\n%s\n%s\n' "$staged" "$1" "$2" > "$seed_scratch/.notproton-seed-placing" || return 1
    mv -n "$1" "$2" || return 1
    if [ "$(stat -f %i "$2" 2>/dev/null)" = "$staged" ]; then
      : > "$seed_scratch/.notproton-seed-placing"
      return 0
    fi
    unnest_seed_entry
    return 1
  elif [ -L "$1" ]; then
    link=$(readlink "$1") || return 1
    ln -sh "$link" "$2" || return 1
    if [ -L "$2" ] && [ "$(readlink "$2")" = "$link" ]; then
      rm -f "$1"
      return
    fi
    # ln made it inside a folder that appeared at $2, named after the link's target.
    nested="$2/${link##*/}"
    [ ! -L "$nested" ] || [ "$(readlink "$nested")" != "$link" ] || rm -f "$nested"
    return 1
  else
    ln -h "$1" "$2" || return 1
    if [ ! -L "$2" ] && [ "$1" -ef "$2" ]; then
      rm -f "$1"
      return
    fi
    [ ! "$1" -ef "$2/${1##*/}" ] || rm -f "$2/${1##*/}"
    return 1
  fi
}

# Moves the cloned template into the prefix, one rename per entry. It only descends into
# folders the prefix already has (the Steam profile and dosdevices), so most of the tree
# moves at once. "check" moves nothing and fails where "move" would. system.reg goes in
# last: until it does, the prefix is not seeded.
merge_seed_tree() (
  mode=$1
  same_volume "$seed_scratch" "$WINEPREFIX" || return 1
  set -- ""
  while [ "$#" -gt 0 ]; do
    relative=$1
    shift
    source_dir="$seed_scratch$relative"
    target_dir="$WINEPREFIX$relative"
    [ -d "$target_dir" ] && [ ! -L "$target_dir" ] || return 1
    [ -r "$source_dir" ] && [ -x "$source_dir" ] || return 1
    for source in "$source_dir"/* "$source_dir"/.[!.]* "$source_dir"/..?*; do
      [ -e "$source" ] || [ -L "$source" ] || continue
      name=${source##*/}
      if [ -z "$relative" ]; then
        case "$name" in
          system.reg|.update-timestamp|.notproton-seed-*) continue ;;
        esac
      fi
      target="$target_dir/$name"
      if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        [ -w "$target_dir" ] || return 1
        [ "$mode" = check ] || place_seed_entry "$source" "$target" || return 1
      elif [ -d "$source" ] && [ ! -L "$source" ]; then
        [ -d "$target" ] && [ ! -L "$target" ] || return 1
        set -- "$@" "$relative/$name"
      else
        case "$relative/$name" in
          /drive_c/users/steamuser/*) continue ;;
        esac
        # Linked in by a launch killed before it removed the staged name.
        [ ! -L "$source" ] && [ "$source" -ef "$target" ] && continue
        [ -L "$source" ] && [ -L "$target" ] \
          && [ "$(readlink "$source")" = "$(readlink "$target")" ] || return 1
      fi
    done
  done
  for name in system.reg .update-timestamp; do
    source="$seed_scratch/$name"
    target="$WINEPREFIX/$name"
    if [ -f "$source" ] && [ ! -L "$source" ] && [ "$source" -ef "$target" ]; then
      [ "$mode" = check ] || rm -f "$source" || return 1
    elif [ -f "$source" ] && [ ! -L "$source" ]; then
      [ ! -e "$target" ] && [ ! -L "$target" ] && [ -w "$WINEPREFIX" ] || return 1
      [ "$mode" = check ] || place_seed_entry "$source" "$target" || return 1
    elif [ -e "$source" ] || [ -L "$source" ]; then
      return 1
    fi
  done
  [ "$mode" = check ] || { [ -f "$WINEPREFIX/system.reg" ] && [ ! -L "$WINEPREFIX/system.reg" ]; }
)

copy_template_into_prefix() {
  seed_scratch="$STEAM_COMPAT_DATA_PATH/pfx.seeding.$$"
  if ! mkdir "$seed_scratch" 2>/dev/null; then
    echo "=== prefix staging folder is occupied, skipping the template ===" >> "$log" 2>&1 || true
    seed_scratch=""
    return 0
  fi
  if same_volume "$template_dir" "$STEAM_COMPAT_DATA_PATH" && volume_clones "$template_dir"; then
    how="cloned this prefix from the $runner_id template"
    cp -c -R "$template_dir/pfx/." "$seed_scratch" 2>/dev/null && copied=0 || copied=$?
  else
    how="copied this prefix from the $runner_id template, not a clone"
    cp -R "$template_dir/pfx/." "$seed_scratch" 2>/dev/null && copied=0 || copied=$?
  fi
  # Files go in as hard links. Without them (exFAT, some network shares), back off before
  # anything moves or is recorded for a later launch to finish; staging is on the prefix's
  # volume. The target lets a later launch finish a merge this one could not, into this
  # prefix only. It is the inode alone: an external drive can come back with another
  # device number.
  if [ "$copied" -eq 0 ] \
    && ! ln "$seed_scratch/system.reg" "$seed_scratch/.notproton-seed-link" 2>/dev/null; then
    echo "=== this volume has no hard links, wine builds this prefix itself ===" >> "$log" 2>&1 || true
  elif [ "$copied" -eq 0 ] && prefix_is_bare \
    && stat -f %i "$WINEPREFIX" > "$seed_scratch/.notproton-seed-target" 2>/dev/null \
    && merge_seed_tree check; then
    seed_merging=1
    if merge_seed_tree move; then
      echo "=== $how ===" >> "$log" 2>&1 || true
    else
      echo "=== could not finish seeding from the template, wine completes this prefix ===" \
        >> "$log" 2>&1 || true
    fi
    seed_merging=0
  else
    echo "=== could not seed from the template, wine builds this prefix itself ===" \
      >> "$log" 2>&1 || true
  fi
  rm -rf "$seed_scratch" 2>/dev/null || true
  seed_scratch=""
}

# A launch killed while it moved the template in left the rest in its staging folder.
finish_dead_seeds() {
  dropping=""
  for leftover in "$STEAM_COMPAT_DATA_PATH"/pfx.seeding.*; do
    [ -d "$leftover" ] && [ ! -L "$leftover" ] || continue
    case "${leftover##*.}" in ''|0|*[!0-9]*) continue ;; esac
    [ "$(stat -f %u "$leftover" 2>/dev/null)" = "$(id -u)" ] || continue
    seed_owner_alive "${leftover##*.}" && continue
    if [ ! -f "$leftover/.notproton-seed-target" ]; then
      why="it stopped before it moved anything in"
    elif [ "$(cat "$leftover/.notproton-seed-target" 2>/dev/null)" \
      != "$(stat -f %i "$WINEPREFIX" 2>/dev/null)" ]; then
      why="it was for a prefix that has been replaced since"
    elif ! same_volume "$leftover" "$WINEPREFIX"; then
      why="it is not on the prefix's volume"
    else
      seed_scratch=$leftover
      if unnest_seed_entry && merge_seed_tree check && merge_seed_tree move; then
        echo "=== finished seeding this prefix, which an earlier launch left half done ===" \
          >> "$log" 2>&1 || true
        why=""
      else
        why="it could not be finished, wine completes this prefix"
      fi
      seed_scratch=""
    fi
    [ -z "$why" ] || dropping="$dropping${leftover##*/}|$why
"
  done
  sweep_dead_seeds "$STEAM_COMPAT_DATA_PATH"/pfx.seeding.*
  printf '%s' "$dropping" | while IFS='|' read -r name why; do
    [ ! -e "$STEAM_COMPAT_DATA_PATH/$name" ] || continue
    echo "=== dropped $name, an earlier launch's unfinished seed: $why ===" >> "$log" 2>&1 || true
  done
}

prefix_is_bare() (
  own_profile=$(wine_profile_name) || own_profile=""
  set -- ""
  while [ "$#" -gt 0 ]; do
    relative=$1
    shift
    directory="$WINEPREFIX$relative"
    [ -d "$directory" ] && [ ! -L "$directory" ] \
      && [ -r "$directory" ] && [ -x "$directory" ] || return 1
    for node in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
      [ -e "$node" ] || [ -L "$node" ] || continue
      part="$relative/${node##*/}"
      if [ -L "$node" ]; then
        if [ "$part" = /dosdevices/s: ] && [ "$(readlink "$node")" = "$(game_drive_record)" ]; then
          continue
        fi
        case "$part:$(readlink "$node")" in
          /dosdevices/c::../drive_c|/dosdevices/z::/|/drive_c/users/crossover:steamuser|\
          "/drive_c/users/$own_profile:steamuser"|\
          '/drive_c/users/steamuser/My Documents:./Documents'|\
          '/drive_c/users/steamuser/Application Data:./AppData/Roaming'|\
          '/drive_c/users/steamuser/Local Settings/Application Data:../AppData/Local') continue ;;
          *) return 1 ;;
        esac
      fi
      case "$part" in
        /drive_c|/drive_c/users|/drive_c/users/steamuser|/dosdevices)
          [ -d "$node" ] || return 1 ;;
        /drive_c/users/steamuser/*)
          [ -d "$node" ] || [ -f "$node" ] || return 1 ;;
        *) return 1 ;;
      esac
      if [ -d "$node" ]; then set -- "$@" "$part"; fi
    done
  done
)

template_identity() (
  stat -f '%d:%i:%c' "$CX_ROOT" || return 1
  /usr/bin/shasum -a 256 < "$np_tool_dir/run" || return 1
  cd "$CX_ROOT" || return 1
  set -- "$WINELOADER" "$WINESERVER" share/wine/wine.inf
  for file in lib/wine/*-windows/ntdll.dll lib/wine/*-windows/lsteamclient.dll \
    lib/wine/*-unix/lsteamclient.so; do
    [ ! -f "$file" ] || set -- "$@" "$file"
  done
  /usr/bin/shasum -a 256 "$@"
)

# Each game's prefix is copied from one template (per runner) instead of running wineboot.
# On APFS the copy is a clone, so it takes almost no space.
seed_prefix_from_template() {
  finish_dead_seeds
  [ -n "$runner_id" ] || return 0
  if ! prefix_is_bare; then
    [ -f "$WINEPREFIX/system.reg" ] \
      || echo "=== prefix is not empty or a standalone Steam profile, skipping the template ===" \
        >> "$log" 2>&1 || true
    return 0
  fi
  # Since a user can have more than one Steam library and libraries can be on different drives,
  # the template is stored alongside the Steam library to support APFS cloning.
  template_cache="$(dirname "$STEAM_COMPAT_DATA_PATH")/notproton-template"
  template_lock="$(dirname "$STEAM_COMPAT_DATA_PATH")/.notproton-template.lock"
  [ ! -L "$template_cache" ] && [ ! -L "$template_lock" ] || return 0
  [ ! -e "$template_lock" ] || [ -f "$template_lock" ] || return 0
  if ! { : >> "$template_lock"; } 2>/dev/null; then
    echo "=== prefix template cache is not writable, skipping the template ===" >> "$log" 2>&1 || true
    return 0
  fi
  exec 9>> "$template_lock"
  if ! /usr/bin/lockf -s -t 0 9; then
    exec 9>&-
    echo "=== prefix templates are busy, wine builds this prefix itself ===" >> "$log" 2>&1 || true
    return 0
  fi
  template_dir="$template_cache/$runner_id"
  if [ -L "$template_cache" ] || [ -L "$template_dir" ] \
    || ! mkdir -p "$template_dir"; then exec 9>&-; return 0; fi
  if ! identity=$(template_identity); then exec 9>&-; return 0; fi
  trap 'abandon_seed 143' TERM
  trap 'abandon_seed 130' INT
  trap 'abandon_seed 129' HUP
  if [ -L "$template_dir/pfx" ] || [ -L "$template_dir/ready" ] \
    || { [ -e "$template_dir/pfx" ] && [ ! -d "$template_dir/pfx" ]; } \
    || { [ -e "$template_dir/ready" ] && [ ! -f "$template_dir/ready" ]; }; then
    exec 9>&-
    trap - TERM INT HUP
    return 0
  fi
  # A template built before missing_core_dll was checked can lack DLLs: build it again.
  if [ ! -s "$template_dir/pfx/system.reg" ] \
    || [ "$(cat "$template_dir/ready" 2>/dev/null)" != "$identity" ] \
    || missing_core_dll "$template_dir/pfx/drive_c/windows" >/dev/null; then
    if ! rm -f "$template_dir/ready" || ! rm -rf "$template_dir/pfx"; then
      echo "=== could not invalidate the old prefix template, skipping it ===" >> "$log" 2>&1 || true
      exec 9>&-
      trap - TERM INT HUP
      return 0
    fi
    if build_prefix_template; then
      if ! printf '%s\n' "$identity" > "$template_dir/ready"; then
        rm -f "$template_dir/ready" 2>/dev/null || true
      fi
    fi
  fi
  if [ "$(cat "$template_dir/ready" 2>/dev/null)" = "$identity" ] \
    && [ -s "$template_dir/pfx/system.reg" ]; then
    copy_template_into_prefix
  fi
  exec 9>&-
  trap - TERM INT HUP
}

prepare_prefix_directory() {
  mkdir -p "$STEAM_COMPAT_DATA_PATH" || return 1
  prefix_lock="$STEAM_COMPAT_DATA_PATH/.notproton-prefix.lock"
  [ ! -L "$prefix_lock" ] && { [ ! -e "$prefix_lock" ] || [ -f "$prefix_lock" ]; } || return 1
  exec 8>> "$prefix_lock"
  if ! /usr/bin/lockf -s -t 0 8; then
    echo "=== another launch is preparing this prefix ===" >> "$log" 2>&1 || true
    /usr/sbin/lsof -- "$prefix_lock" >> "$log" 2>&1 || true
    return 1
  fi
  for interrupted in "$STEAM_COMPAT_DATA_PATH"/pfx.replaced.*; do
    [ -e "$interrupted" ] || [ -L "$interrupted" ] || continue
    echo "=== interrupted prefix replacement needs recovery: $interrupted ===" >> "$log" 2>&1 || true
    show_alert "Prefix recovery required" "An interrupted prefix replacement may hold saved games. Do not delete this prefix. Check its bridgeplay-run.log for the recovery folder."
    exit 1
  done
  mkdir -p "$WINEPREFIX"
}

game_drive_record() {
  record="$STEAM_COMPAT_DATA_PATH/notproton-game-drive"
  [ -f "$record" ] && [ ! -L "$record" ] && cat "$record" 2>/dev/null
}

record_game_drive() {
  record="$STEAM_COMPAT_DATA_PATH/notproton-game-drive"
  [ "$(game_drive_record)" != "$1" ] && [ ! -L "$record" ] || return 0
  { printf '%s\n' "$1" > "$record.new" && mv -f "$record.new" "$record"; } 2>/dev/null \
    || rm -f "$record.new" 2>/dev/null || true
}

restart_for_drive() {
  # Wine only picks up a new drive when it starts.
  np_boot_fp=""
  without_lock_fds "$WINESERVER" -k >> "$log" 2>&1 || true
  without_lock_fds "$WINESERVER" -w >> "$log" 2>&1 || true
}

unmap_game_drive() {
  [ -L "$drive" ] && [ "$(readlink "$drive")" = "$(game_drive_record)" ] || return 0
  rm -f "$drive" || return 0
  rm -f "$STEAM_COMPAT_DATA_PATH/notproton-game-drive" 2>/dev/null || true
  echo "=== removed drive S:, the game is not in a Steam library ===" >> "$log" 2>&1 || true
  restart_for_drive
}

# Like Proton, the game's Steam library gets drive S: so the game does not run from Z:.
map_game_drive() {
  drive="$WINEPREFIX/dosdevices/s:"
  [ -d "$WINEPREFIX/dosdevices" ] && [ ! -L "$WINEPREFIX/dosdevices" ] || return 0
  library=""
  listed=""
  set -f
  old_ifs=$IFS
  IFS=:
  for path in $STEAM_COMPAT_LIBRARY_PATHS; do
    path=${path%/}
    [ -n "$path" ] || continue
    listed=1
    case "$STEAM_COMPAT_INSTALL_PATH/" in
      "$path"/*) if [ "${#path}" -gt "${#library}" ]; then library=$path; fi ;;
    esac
  done
  IFS=$old_ifs
  set +f
  # Steam sometimes passes no libraries on a quick relaunch. That says nothing about where
  # the game is, so S: stays as it is.
  if [ -z "$listed" ]; then
    echo "=== Steam passed no library paths, drive S: left as it is ===" >> "$log" 2>&1 || true
    return 0
  fi
  if [ -z "$library" ]; then
    unmap_game_drive
    return 0
  fi
  target=$library
  if real=$(cd -P -- "$library" 2>/dev/null && pwd) && [ "${real##*/}" = steamapps ]; then
    parent=${real%/*}
    if [ -n "$parent" ] && [ -w "$parent" ] \
      && [ "$(stat -f %d "$real")" = "$(stat -f %d "$parent")" ]; then
      target=$parent
    fi
  fi
  if [ -L "$drive" ]; then
    current=$(readlink "$drive") || return 0
    if [ "$current" = "$target" ]; then
      record_game_drive "$target"
      return 0
    fi
    if [ "$current" != "$(game_drive_record)" ]; then
      echo "=== drive S: already points to $current, left in place ===" >> "$log" 2>&1 || true
      return 0
    fi
    rm -f "$drive" || return 0
  elif [ -e "$drive" ]; then
    echo "=== drive S: is not a link, left in place ===" >> "$log" 2>&1 || true
    return 0
  fi
  if ln -s "$target" "$drive" 2>> "$log"; then
    record_game_drive "$target"
    echo "=== mapped drive S: to $target ===" >> "$log" 2>&1 || true
    restart_for_drive
  else
    echo "=== could not map drive S: to $target ===" >> "$log" 2>&1 || true
  fi
}

# Implementation of Proton's create_fonts_symlinks().
link_fonts() {
  [ -f "$WINEPREFIX/system.reg" ] || return 0
  fonts_dir="$WINEPREFIX/drive_c/windows/Fonts"
  mkdir -p "$fonts_dir" 2>> "$log" || return 0
  # A folder's times change with any entry added, removed or renamed in it.
  if [ "${np_stamps_ready:-0}" = 1 ]; then
    stamp_key "$(fonts_inputs)"
    if stamp_hit fonts; then
      echo "fonts: unchanged since the last good launch, links kept" >> "$log" 2>&1 || true
      return 0
    fi
  fi
  # Windows finds a font by name in any case, so on a case-sensitive volume a font that
  # Winetricks installed as Arial.TTF keeps the arial.ttf link out, and drops one made before.
  # -L -type f: fonts and links that reach one; a dangling link holds no name.
  fonts_present=$(find -L "$fonts_dir" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | sed 's|.*/||' | tr '[:upper:]' '[:lower:]')
  fonts_twice=$(printf '%s\n' "$fonts_present" | sort | uniq -d)
  for dir in "$np_support/fonts" "$CX_ROOT/share/wine/fonts"; do
    for src in "$dir"/*.ttf "$dir"/*.ttc; do
      [ -f "$src" ] || continue
      name=$(basename "$src")
      case "$app_id:$name" in
        1313860:arial.ttf|1506830:arial.ttf) src="$dir/alt/$name" ;;
      esac
      dst="$fonts_dir/$name"
      if [ -L "$dst" ]; then
        # Another font of this name in any case keeps the link out: beside a working link it
        # shows as the name twice, beside a dangling one (not counted) as the name at all.
        if [ -e "$dst" ]; then fonts_other=$fonts_twice; else fonts_other=$fonts_present; fi
        rm -f "$dst" || continue
        if [ -z "$fonts_other" ] \
          || ! printf '%s\n' "$fonts_other" | grep -qxF "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"; then
          ln -s "$src" "$dst" 2>> "$log" || true
        fi
      elif [ ! -e "$dst" ] \
        && ! printf '%s\n' "$fonts_present" | grep -qxF "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"; then
        ln -s "$src" "$dst" 2>> "$log" || true
      fi
    done
  done
  if [ "${np_stamps_ready:-0}" = 1 ]; then
    stamp_key "$(fonts_inputs)"
    stamp_put fonts
  fi
}

fonts_inputs() {
  printf '%s\n' "$app_id"
  stat -f '%N %d:%i:%Fm:%Fc' "$fonts_dir" "$np_support/fonts" "$np_support/fonts/alt" \
    "$CX_ROOT/share/wine/fonts" "$CX_ROOT/share/wine/fonts/alt" 2>/dev/null
}

# Lays out the profile, drives, settings and fonts of the prefix the launch will use.
set_up_prefix_contents() {
  mark "profile layout"
  if ! lay_out_proton_profile; then
    show_alert "Saved-game folders need attention" "Bridgeplay left the conflicting files in place. Open this prefix's bridgeplay-run.log for details before trying again."
    exit 1
  fi
  [ "$verb" != waitforexitandrun ] || echo "video: RetinaMode=${NOTPROTON_RETINA:-0}" >> "$log" 2>&1 || true
  mark "game drive"
  map_game_drive
  mark "prefix settings"
  warm_session_begin
  import_prefix_settings
  mark "fonts"
  link_fonts
  # A prefix that Wine built just now only has dosdevices from this point on.
  mark "game drive"
  map_game_drive
}

# Wine loads its own VC++ runtime over Microsoft's, which breaks some games
native_vc_runtime() {
  for name in concrt140 msvcp140 msvcp140_1 msvcp140_2 msvcp140_atomic_wait msvcp140_codecvt_ids \
    vcamp140 vccorlib140 vcomp140 vcruntime140 vcruntime140_1; do
    dll="$WINEPREFIX/drive_c/windows/system32/$name.dll"
    [ -f "$dll" ] || continue
    if [ "$(dd if="$dll" bs=1 skip=64 count=16 2>/dev/null)" != "Wine builtin DLL" ]; then
      printf '%s=n,b;' "$name"
    fi
  done
}

# Launch stamps. A step whose inputs (file identities, the engine, the prefix, this script) match
# what the last launch recorded is skipped. A last launch that did not end well, no outcome on
# record, or BRIDGEPLAY_FULL_LAUNCH=1 runs every step in full; full steps record again.
np_uid=$(id -u)
np_full_launch=0
[ "${NOTPROTON_FULL_LAUNCH:-0}" != 1 ] || np_full_launch=1
np_stamps=0
np_stamps_ready=0
np_stamp_text=""
np_stamp_base=""
stamp_file=""

# The prefix (dev:ino) and the engine files (dev:ino:size:mtime), from one stat. Engine files
# go by size and mtime: each launch links ntdll.so into the game's bundle, which changes its ctime.
launch_ids() {
  np_prefix_id=""
  np_engine_ids=""
  ids=$(stat -f '%d:%i %z:%Fm' "$WINEPREFIX" "$WINESERVER" "$WINELOADER" "$wine_unix/ntdll.so" 2>/dev/null) || true
  np_prefix_id=${ids%%' '*}
  case "$ids" in *"
"*) np_engine_ids=${ids#*"
"} ;; esac
  np_server_ids=${np_engine_ids%%"
"*}
}

stamps_load() {
  [ -n "$STEAM_COMPAT_DATA_PATH" ] && [ -n "$WINEPREFIX" ] || return 0
  stamp_file="$STEAM_COMPAT_DATA_PATH/bridgeplay-launch-stamps"
  launch_ids
  script_sum=$(cksum < "$0" 2>/dev/null) || script_sum=""
  np_stamp_base="$np_uid $np_build ${wine_unix##*/} $CX_ROOT
$script_sum
$np_prefix_id
$np_engine_ids"
  np_stamps_ready=1
  stamps_why=""
  last_code=""
  if [ -f "$STEAM_COMPAT_DATA_PATH/bridgeplay-last-launch" ]; then
    while IFS= read -r line; do
      case "$line" in code=*) last_code=${line#code=}; break ;; esac
    done < "$STEAM_COMPAT_DATA_PATH/bridgeplay-last-launch" 2>/dev/null || true
  fi
  if [ "$np_full_launch" = 1 ]; then
    stamps_why="BRIDGEPLAY_FULL_LAUNCH=1"
  elif [ "${np_rebuilt:-0}" = 1 ]; then
    stamps_why="the prefix was rebuilt"
  else
    case "$last_code" in
      ok|quit_early|stopped_from_steam) ;;
      '') stamps_why="no last launch on record" ;;
      *) stamps_why="the last launch ended $last_code" ;;
    esac
  fi
  if [ -z "$stamps_why" ] && own_note "$stamp_file"; then
    np_stamp_text=""
    while IFS= read -r line; do
      np_stamp_text="$np_stamp_text$line
"
    done < "$stamp_file" 2>/dev/null || true
    np_stamps=1
  fi
  if [ "$np_stamps" = 1 ]; then
    echo "launch stamps: steps whose inputs match the last launch are skipped" >> "$log" 2>&1 || true
  else
    echo "launch stamps: every step runs in full (${stamps_why:-nothing recorded yet})" >> "$log" 2>&1 || true
  fi
}

# Sets stamp_new to the checksum of this launch's base and $1.
stamp_key() {
  stamp_new=$(printf '%s\n%s' "$np_stamp_base" "$1" | cksum) || stamp_new=""
  case "$stamp_new" in *' '*) stamp_new="${stamp_new%% *}:${stamp_new#* }" ;; *) stamp_new="" ;; esac
}

# Succeeds when the stamp named $1 holds stamp_new, plus $2 when given.
stamp_hit() {
  [ "$np_stamps" = 1 ] && [ "${np_rebuilt:-0}" != 1 ] && [ -n "$stamp_new" ] || return 1
  case "
$np_stamp_text" in
    *"
$1 $stamp_new${2:+ $2}
"*) return 0 ;;
  esac
  return 1
}

# Records stamp_new (and $2) under the name $1; with no stamp_new it drops the name.
stamp_put() {
  [ "$np_stamps_ready" = 1 ] && [ -n "$stamp_file" ] || return 0
  kept_text=""
  while IFS= read -r line; do
    case "$line" in ''|"$1 "*) ;; *) kept_text="$kept_text$line
" ;; esac
  done <<STAMPS
$np_stamp_text
STAMPS
  [ -z "$stamp_new" ] || kept_text="$kept_text$1 $stamp_new${2:+ $2}
"
  np_stamp_text=$kept_text
  rm -f "$stamp_file.$$" 2>/dev/null || true
  if ! { (set -C; printf '%s' "$np_stamp_text" > "$stamp_file.$$") && mv -f "$stamp_file.$$" "$stamp_file"; } 2>/dev/null; then
    rm -f "$stamp_file.$$" 2>/dev/null || true
  fi
}

# After a helper that failed, the game runs every step in full.
stamps_clear() {
  np_stamps=0
  np_stamp_text=""
  [ -z "$stamp_file" ] || rm -f "$stamp_file" 2>/dev/null || true
}

# The warm Wine session. Steam runs the install-script helper ("run") just before the game, and
# each booted Wine: the game's first step killed the helper's session and booted another. Now
# the first Wine program of a launch starts the server with -p, so it outlives its last program
# by np_warm_seconds, and a helper that ends well leaves bridgeplay-warm-server. The game reuses
# that session when the note is under np_warm_reuse seconds old and names this user, engine,
# wineserver, prefix, WINEMSYNC and boot environment, and its server is still the one running;
# anything else kills it as before.
#
# Wine's system processes (services, winedevice with winebus, explorer) take the environment of
# the session's first program. So the helper boots its session with the game's: the variables
# boot_env_awk lists, as the game last had them (bridgeplay-boot-env), and the reuse needs the
# game's to be the same now. The helper's own program keeps the helper's environment.
np_warm=0
np_warm_seconds=30
np_warm_reuse=10
np_boot_fp=""
np_boot_sock=""
np_boot_client=""
np_mirror_file=""
case "$verb" in run|waitforexitandrun) [ "$np_full_launch" = 1 ] || np_warm=1 ;; esac

# The boot environment: every variable of these families as "R NAME=value", R being + for one a
# helper may copy (not the engine's paths, the SDL mappings built from files or DYLD_, and no
# backslash or newline in the value, which come out escaped) and - for the rest. With
# unset=<record>, the names a helper has that the record lacks.
boot_env_awk='
function boot(k) { return k ~ /^(SDL_|WINE|CX_|ROSETTA_|FEX_|DYLD_|D3DM_|DXMT_|DXVK_|VKD3D_|MVK_|MTL_|STAGING_|LC_)/ || k == "LANG" || k == "TZ" }
function kept(k) { return k ~ /^(WINEPREFIX|WINELOADER|WINESERVER|WINEDLLPATH|WINEMSYNC|CX_ROOT|CX_HOME|CX_APPLEGPTK_LIBD3DSHARED_PATH|SDL_GAMECONTROLLERCONFIG|SDL_GAMECONTROLLERCONFIG_FILE)$/ || k ~ /^DYLD_/ }
BEGIN {
  if (unset != "") {
    while ((getline l < unset) > 0) { n = l; sub(/=.*/, "", n); have[n] = 1 }
    for (k in ENVIRON) if (boot(k) && !kept(k) && !(k in have)) print k
    exit
  }
  for (k in ENVIRON) if (boot(k)) {
    v = ENVIRON[k]; copy = !kept(k) && v !~ /[\\\n]/
    gsub(/\\/, "\\\\", v); gsub(/\n/, "\\n", v)
    print (copy ? "+ " : "- ") k "=" v
  }
}'

# Runs "$@" with the boot environment of the game's last launch in place of the helper's.
# It closes the lock fds itself: callers must not put lock redirections on it (without_lock_fds).
boot_mirror() {
  if [ -z "$np_mirror_file" ]; then "$@" 5>&- 7>&- 8>&- 9>&-; return; fi
  while IFS= read -r line; do
    case "${line%%=*}" in ''|*[!A-Za-z0-9_]*|[0-9]*) continue ;; esac
    set -- "$line" "$@"
  done < "$np_mirror_file"
  # shellcheck disable=SC2013 # one variable name per line, which has no spaces
  for name in $(/usr/bin/awk -v unset="$np_mirror_file" "$boot_env_awk"); do
    set -- -u "$name" "$@"
  done
  /usr/bin/env "$@" 5>&- 7>&- 8>&- 9>&-
}

# The session's first Wine program boots its system processes, so only it gets boot_mirror:
# warm_session_begin sets np_boot_client=boot_client and the first use clears it.
# shellcheck disable=SC2329 # run through $np_boot_client
boot_client() {
  np_boot_client=""
  boot_mirror "$@"
}

# The environment this launch's session boots with: np_my_fp (its checksum), np_env_copy (the
# lines a helper may copy) and np_env_lens ("len=NAME length" lines, to name what differs).
boot_env_scan() {
  listed=$(boot_mirror /usr/bin/awk "$boot_env_awk" | LC_ALL=C sort) || listed=""
  all=""
  np_env_copy=""
  np_env_lens=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    entry=${line#? }
    all="$all$entry
"
    [ "${line%% *}" != + ] || np_env_copy="$np_env_copy$entry
"
    np_env_lens="${np_env_lens}len=${entry%%=*} ${#entry}
"
  done <<LISTED
$listed
LISTED
  np_my_fp=$(printf '%s' "$all" | cksum) || np_my_fp=""
  np_my_fp="${np_my_fp%% *}:${np_my_fp#* }"
}

# A note this user wrote, not a link, up to 64 KiB.
own_note() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  note_stat=$(stat -f '%u %z' "$1" 2>/dev/null) || return 1
  [ "${note_stat%% *}" = "$np_uid" ] && [ "${note_stat#* }" -le 65536 ]
}

warm_identity() {
  printf 'version=1\nuid=%s\nbuild=%s\narch=%s\nserver=%s\nprefix=%s\nmsync=%s\nenv=%s\n' \
    "$np_uid" "$np_build" "${wine_unix##*/}" "$np_server_ids" "$np_prefix_id" "$WINEMSYNC" "$np_my_fp"
}

# Where Wine keeps this prefix's server: /tmp/.wine-<uid>/server-<dev>-<inode>, in hex.
warm_server_dir() {
  printf '/tmp/.wine-%s/server-%x-%x' "$np_uid" "${np_prefix_id%%:*}" "${np_prefix_id#*:}"
}

# The running server: its socket, which each new server makes afresh. The folders and socket are
# this user's and no links, as for prefix_server_dir.
warm_server_id() {
  case "$np_prefix_id" in *[!0-9:]*|''|:*|*:) return 1 ;; esac
  server_dir=$(warm_server_dir) || return 1
  server_ids=$(stat -f '%Sp %u %d:%i:%B' "${server_dir%/*}" "$server_dir" "$server_dir/socket" 2>/dev/null) \
    || return 1
  # shellcheck disable=SC2086 # three lines of three words without spaces
  set -- $server_ids
  [ "$#" = 9 ] && [ "$2" = "$np_uid" ] && [ "$5" = "$np_uid" ] && [ "$8" = "$np_uid" ] || return 1
  # The first letter of each mode: two folders, then a socket.
  [ "${1%"${1#?}"}${4%"${4#?}"}${7%"${7#?}"}" = dds ] || return 1
  printf '%s' "$9"
}

# The game writes the boot environment its own session would get, for the next helper to copy.
boot_env_record() {
  record="$STEAM_COMPAT_DATA_PATH/bridgeplay-boot-env"
  was=""
  if [ -f "$record" ]; then
    while IFS= read -r line; do
      was="$was$line
"
    done < "$record" 2>/dev/null || true
  fi
  [ "$was" != "$np_env_copy" ] || return 0
  rm -f "$record.$$" 2>/dev/null || true
  { (umask 077; set -C; printf '%s' "$np_env_copy" > "$record.$$") && mv -f "$record.$$" "$record"; } 2>/dev/null \
    || rm -f "$record.$$" 2>/dev/null || true
}

# Decides at the launch's first kill whether the session the helper left up is reused.
warm_session_decide() {
  np_boot_fp=""
  np_mirror_file=""
  note="$STEAM_COMPAT_DATA_PATH/bridgeplay-warm-server"
  if [ "$np_warm" != 1 ]; then
    rm -f "$note" 2>/dev/null || true
    return 1
  fi
  if [ "$verb" != waitforexitandrun ] && own_note "$STEAM_COMPAT_DATA_PATH/bridgeplay-boot-env"; then
    np_mirror_file="$STEAM_COMPAT_DATA_PATH/bridgeplay-boot-env"
  fi
  boot_env_scan
  [ "$verb" != waitforexitandrun ] || boot_env_record
  own_note "$note" || { rm -f "$note" 2>/dev/null || true; return 1; }
  left=""
  left_lens=""
  ended=""
  sock=""
  while IFS= read -r line; do
    case "$line" in
      ended=*) ended=${line#ended=} ;;
      sock=*) sock=${line#sock=} ;;
      len=*) left_lens="$left_lens$line
" ;;
      *) left="$left$line
" ;;
    esac
  done < "$note" 2>/dev/null || true
  rm -f "$note" 2>/dev/null || true
  case "$ended" in ''|*[!0-9]*) return 1 ;; esac
  np_now_ms
  age=$((np_ms / 1000 - ended))
  why=""
  if [ "$age" -lt 0 ] || [ "$age" -gt "$np_warm_reuse" ]; then
    why="it is ${age}s old"
  elif [ "$left" != "$(warm_identity)
" ]; then
    why="the engine, prefix, WINEMSYNC or boot environment differs"
    differs=$(printf '%s%s' "$left_lens" "$np_env_lens" | LC_ALL=C sort | uniq -u | sed 's/^len=//;s/ .*//' \
      | LC_ALL=C sort -u | tr '\n' ' ') || differs=""
    [ -z "$differs" ] || why="$why (${differs% })"
  elif [ -z "$sock" ] || [ "$sock" != "$(warm_server_id)" ]; then
    why="its Wine server is gone or was replaced"
  fi
  if [ -n "$why" ]; then
    echo "warm start: not reusing the helper's Wine session, $why" >> "$log" 2>&1 || true
    return 1
  fi
  np_boot_fp=$np_my_fp
  np_boot_sock=$sock
  echo "warm start: reusing the Wine session the helper left ${age}s ago" >> "$log" 2>&1 || true
}

# Before the launch's first Wine program: starts the server with -p unless one is up. Its first
# program, run through boot_client, then boots Wine's system processes.
warm_session_begin() {
  np_boot_client=""
  [ "$np_warm" = 1 ] || return 0
  rc=0
  boot_mirror "$WINESERVER" -p"$np_warm_seconds" < /dev/null >> "$log" 2>&1 || rc=$?
  case "$rc" in
    0)
      np_boot_fp=$np_my_fp
      np_boot_sock=$(warm_server_id) || np_boot_sock=""
      np_boot_client=boot_client
      echo "warm start: Wine server started, it stays up ${np_warm_seconds}s after its last program" >> "$log" 2>&1 || true ;;
    2)
      [ -n "$np_boot_fp" ] \
        || echo "warm start: a Wine server this launch did not start is up, it is not left for the game" >> "$log" 2>&1 || true ;;
    *)
      np_boot_fp=""
      echo "warm start: the Wine server did not start (status $rc), Wine starts its own" >> "$log" 2>&1 || true ;;
  esac
}

# A helper that ended well leaves its session to the game; any other end kills one it started.
warm_session_end() {
  note="$STEAM_COMPAT_DATA_PATH/bridgeplay-warm-server"
  [ -n "$np_boot_fp" ] || return 0
  if [ "$1" = 0 ] && [ "$np_boot_fp" = "$np_my_fp" ] && [ -n "$np_boot_sock" ] \
    && [ "$np_boot_sock" = "$(warm_server_id)" ]; then
    np_now_ms
    rm -f "$note.$$" 2>/dev/null || true
    if { (umask 077; set -C; { warm_identity; printf '%ssock=%s\nended=%s\n' "$np_env_lens" "$np_boot_sock" \
      "$((np_ms / 1000))"; } > "$note.$$") && mv -f "$note.$$" "$note"; } 2>/dev/null; then
      echo "warm start: Wine session left up for the game" >> "$log" 2>&1 || true
      return 0
    fi
    rm -f "$note.$$" 2>/dev/null || true
  fi
  without_lock_fds "$WINESERVER" -k >> "$log" 2>&1 || true
}

if [ -n "$STEAM_COMPAT_DATA_PATH" ]; then
  mark "anti-cheat check"
  kernel_anticheat_notice
  export WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
  mark "prefix lock"
  prepare_prefix_directory
  resolve_msync
  export WINEMSYNC="${WINEMSYNC:-0}"
  printf '%s' "$WINEMSYNC" \
    > "$STEAM_COMPAT_DATA_PATH/notproton-msync" 2>/dev/null || true
  mark "prefix build check"
  note_other_build
  mark "prefix arch check"
  refuse_foreign_prefix
  prefix_was_new=0
  [ -f "$WINEPREFIX/system.reg" ] || prefix_was_new=1
  claim_prefix
  find_client_root "$STEAM_COMPAT_CLIENT_INSTALL_PATH"
  note_prefix_volume
  note_other_prefixes
  mark "prefix switch check"
  offer_switch_rebuild
  echo "sync: WINEMSYNC=$WINEMSYNC from $msync_from" >> "$log" 2>&1 || true
  if [ "${wine_unix##*/}" = aarch64-unix ]; then
    echo "fex: FEX_X87REDUCEDPRECISION=$FEX_X87REDUCEDPRECISION from $fex_from" >> "$log" 2>&1 || true
  else
    echo "avx: ROSETTA_ADVERTISE_AVX=$ROSETTA_ADVERTISE_AVX from $avx_from" >> "$log" 2>&1 || true
  fi
  stamps_load
  warm_session_decide || without_lock_fds "$WINESERVER" -k >> "$log" 2>&1 || true
  if [ "$prefix_was_new" = 1 ]; then launch_progress setup; else launch_progress prepare; fi
  mark "prefix seed"
  seed_prefix_from_template
  set_up_prefix_contents
  mark "prefix check"
  refuse_broken_prefix
  if [ "${broken_rebuilt:-0}" = 1 ]; then
    launch_step prepare
    set_up_prefix_contents
    mark "prefix check"
    refuse_broken_prefix
  fi
fi
low_power_notice
launch_step prepare

mark "graphics backend"
select_backend "$1"
activate_backend || true
record_backend || true
stage_rockstar_shim || true
fex_graphics_notice "$1" || true
# An engine without lib/notproton-backends (CrossOver) picks its graphics itself, from
# CX_GRAPHICS_BACKEND, so the log names that choice, not the dxmt-builtin placeholder.
if [ "$backend" = dxmt-builtin ]; then
  engine_backend=$(printf '%s' "${CX_GRAPHICS_BACKEND:-}" | tr '[:upper:]' '[:lower:]')
  case "$engine_backend" in
    d3dmetal|dxmt|dxvk|wined3d) graphics_log "backend=$engine_backend (CX_GRAPHICS_BACKEND, applied by the engine)" ;;
    *) graphics_log "backend=engine-default (the engine picks its own graphics, CX_GRAPHICS_BACKEND is not set)" ;;
  esac
else
  graphics_log "backend=$backend ($backend_from)"
fi
compose_dll_overrides
[ -z "$backend_overrides" ] || graphics_log "backend overrides $backend_overrides"

bridge_src="$np_support/bridge"
prefix_steam="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
verify_runner() {
  if [ ! -d "$bridge_src/wine/$np_build" ]; then
    echo "=== no patched ntdll for build $np_build in the bridge, set it up in Bridgeplay ===" >> "$log" 2>&1 || true
    return
  fi
  runner_warned=0
  if [ "${np_stamps_ready:-0}" = 1 ]; then
    stamp_key "$(runner_inputs)"
    if stamp_hit runner; then
      echo "runner check: unchanged since the last good launch" >> "$log" 2>&1 || true
      return
    fi
  fi
  for arch in x86_64-windows i386-windows aarch64-windows; do
    staged="$bridge_src/wine/$np_build/$arch/ntdll.dll"
    live="$CX_ROOT/lib/wine/$arch/ntdll.dll"
    [ -f "$staged" ] || continue
    if [ ! -f "$live" ]; then
      runner_warned=1
      echo "=== runner has no $arch ntdll, set up the runner in Bridgeplay ===" >> "$log" 2>&1 || true
    elif ! cmp -s "$staged" "$live"; then
      runner_warned=1
      echo "=== runner $arch ntdll is not the patched copy, set up the runner in Bridgeplay ===" >> "$log" 2>&1 || true
    fi
  done
  for arch in i386-windows x86_64-windows "${wine_unix##*/}"; do
    case "$arch" in
      *-unix) name="lsteamclient.so" ;;
      *) name="lsteamclient.dll" ;;
    esac
    [ -f "$CX_ROOT/lib/wine/$arch/$name" ] && continue
    runner_warned=1
    echo "=== runner is missing $arch/$name, set up the runner in Bridgeplay ===" >> "$log" 2>&1 || true
  done
  [ "$runner_warned" = 1 ] || [ "${np_stamps_ready:-0}" != 1 ] || stamp_put runner
}

runner_inputs() {
  for arch in x86_64-windows i386-windows aarch64-windows; do
    stat -f '%N %d:%i:%z:%Fm:%Fc' "$bridge_src/wine/$np_build/$arch/ntdll.dll" \
      "$CX_ROOT/lib/wine/$arch/ntdll.dll" 2>/dev/null || echo "$arch ntdll missing"
  done
  stat -f '%N %d:%i:%z:%Fm:%Fc' "$CX_ROOT/lib/wine/i386-windows/lsteamclient.dll" \
    "$CX_ROOT/lib/wine/x86_64-windows/lsteamclient.dll" "$wine_unix/lsteamclient.so" 2>/dev/null \
    || echo "lsteamclient missing"
}
install_lsteamclient_trigger() {
  src="$bridge_src/i386-windows/lsteamclient.dll"
  dst="$WINEPREFIX/drive_c/windows/syswow64/lsteamclient.dll"
  [ -f "$src" ] && [ -d "$WINEPREFIX/drive_c/windows/syswow64" ] || return 0
  cmp -s "$src" "$dst" && return 0
  if place_bridge_file i386-windows/lsteamclient.dll "$dst"; then
    echo "=== installed syswow64 lsteamclient trigger ===" >> "$log" 2>&1 || true
  else
    echo "=== could not copy i386-windows/lsteamclient.dll to $dst ===" >> "$log" 2>&1 || true
    return 1
  fi
}

# A builtin Wine only finds through a placeholder in the prefix, and prefixes made
# before the runner carried it have none. DXMT's dxgi imports winemetal, so without
# it every D3D11 game fails to start in such a prefix.
install_runner_builtins() {
  for pair in x86_64-windows:system32 i386-windows:syswow64; do
    arch=${pair%%:*}
    dir="$WINEPREFIX/drive_c/windows/${pair##*:}"
    [ -d "$dir" ] || continue
    name=winemetal.dll
    src="$CX_ROOT/lib/wine/$arch/$name"
    [ -f "$src" ] || continue
    cmp -s "$src" "$dir/$name" && continue
    if cp -f "$src" "$dir/$name"; then
      echo "=== installed $arch/$name into the prefix ===" >> "$log" 2>&1 || true
    else
      echo "=== could not install $arch/$name into the prefix ===" >> "$log" 2>&1 || true
    fi
  done
}

# A fix to match Proton
install_legacy_steam_dll() {
  src="$bridge_src/legacycompat/Steam.dll"
  dst="$WINEPREFIX/drive_c/windows/syswow64/Steam.dll"
  [ -f "$src" ] && [ -d "$WINEPREFIX/drive_c/windows/syswow64" ] || return 0
  cmp -s "$src" "$dst" && return 0
  if place_bridge_file legacycompat/Steam.dll "$dst"; then
    echo "=== installed legacy Steam.dll ===" >> "$log" 2>&1 || true
  else
    echo "=== could not copy legacycompat/Steam.dll to $dst ===" >> "$log" 2>&1 || true
  fi
}

# Steam runs a Windows game's installscript.vdf by invoking the standalone
# evaluator through the compat tool, the same way the linux client does, but
# the binaries are missing on macOS, so...
install_legacycompat() {
  src="$bridge_src/legacycompat"
  dst="$STEAM_COMPAT_CLIENT_INSTALL_PATH/legacycompat"
  [ -d "$src" ] && [ -n "$STEAM_COMPAT_CLIENT_INSTALL_PATH" ] || return 0
  mkdir -p "$dst" || return 0
  for f in "$src"/*; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    cmp -s "$f" "$dst/$b" && continue
    if cp -c -f "$f" "$dst/$b" 2>> "$log"; then
      echo "=== installed legacycompat/$b ===" >> "$log" 2>&1 || true
    else
      echo "=== could not copy legacycompat/$b to $dst/$b ===" >> "$log" 2>&1 || true
    fi
  done
}

# Steam on Linux symlinks this for every compat tool launch. Is needed for some legacy games.
link_legacy_steam_dll() {
  src="$STEAM_COMPAT_CLIENT_INSTALL_PATH/legacycompat/Steam.dll"
  [ -n "$STEAM_COMPAT_INSTALL_PATH" ] && [ -f "$src" ] || return 0
  dst="$(dirname "$STEAM_COMPAT_INSTALL_PATH")/Steam.dll"
  [ -L "$dst" ] || [ ! -e "$dst" ] || return 0
  [ "$(readlink "$dst" 2>/dev/null)" = "$src" ] && return 0
  if ln -sfn "$src" "$dst" 2>> "$log"; then
    chflags -h hidden "$dst" 2>/dev/null || true
    echo "=== linked legacy Steam.dll at $dst ===" >> "$log" 2>&1 || true
  else
    echo "=== could not link legacy Steam.dll at $dst ===" >> "$log" 2>&1 || true
  fi
}

bridge_files="steamclient64.dll steamclient.dll tier0_s64.dll vstdlib_s64.dll tier0_s.dll vstdlib_s.dll"
bridge_files="$bridge_files lsteamclient.dll lsteamclient.so steam.exe"
# A clone cannot cross drives, so a prefix on another drive clones from a copy of the
# bridge kept beside that drive's templates.
bridge_origin() {
  origin="$bridge_src/$1"
  [ -n "$bridge_cache" ] || return 0
  cached="$bridge_cache/$1"
  for d in "${bridge_cache%/*}" "$bridge_cache" "${cached%/*}"; do
    [ ! -L "$d" ] || return 0
  done
  mkdir -p "${cached%/*}" 2>/dev/null || return 0
  if ! cmp -s "$origin" "$cached"; then
    if ! { cp -p "$origin" "$cached.$$" && mv -f "$cached.$$" "$cached"; } 2>/dev/null; then
      rm -f "$cached.$$"
      return 0
    fi
  fi
  origin="$cached"
}
place_bridge_file() {
  bridge_origin "$1"
  cp -c -fp "$origin" "$2" 2>/dev/null || cp -fp "$bridge_src/$1" "$2" 2>> "$log"
}
bridge_inputs() {
  printf '%s\n' "$bridge_cache"
  for f in $bridge_files; do
    src="$bridge_src/$f"
    [ "$f" != lsteamclient.so ] || src="$bridge_src/${wine_unix##*/}/$f"
    stat -f '%N %d:%i:%z:%Fm:%Fc' "$src" "$prefix_steam/$f" 2>/dev/null || echo "$f missing"
  done
}
if [ -d "$bridge_src" ] && [ -n "$WINEPREFIX" ]; then
  mark "bridge staging"
  mkdir -p "$prefix_steam"
  bridge_cache=""
  if [ -n "$STEAM_COMPAT_DATA_PATH" ] && ! same_volume "$bridge_src" "$STEAM_COMPAT_DATA_PATH" \
    && volume_clones "$STEAM_COMPAT_DATA_PATH"; then
    bridge_cache="$(dirname "$STEAM_COMPAT_DATA_PATH")/notproton-template/bridge"
  fi
  bridge_matches=1
  bridge_stamped=0
  if [ "${np_stamps_ready:-0}" = 1 ]; then
    stamp_key "$(bridge_inputs)"
    ! stamp_hit bridge || bridge_stamped=1
  fi
  for f in $bridge_files; do
    [ "$bridge_stamped" = 0 ] || break
    src="$bridge_src/$f"
    if [ "$f" = lsteamclient.so ]; then
      src="$bridge_src/${wine_unix##*/}/$f"
    fi
    if ! cmp -s "$src" "$prefix_steam/$f"; then
      bridge_matches=0
      break
    fi
  done
  if [ "$bridge_stamped" = 1 ]; then
    echo "=== bridge already staged (unchanged since the last good launch) ===" >> "$log" 2>&1 || true
  elif [ "$bridge_matches" -eq 1 ]; then
    echo "=== bridge already staged ===" >> "$log" 2>&1 || true
  else
    unstaged=0
    for f in $bridge_files; do
      rel="$f"
      if [ "$f" = lsteamclient.so ]; then
        rel="${wine_unix##*/}/$f"
      fi
      src="$bridge_src/$rel"
      if [ ! -f "$src" ]; then
        echo "=== bridge missing $f ===" >> "$log" 2>&1 || true
        continue
      fi
      cmp -s "$src" "$prefix_steam/$f" && continue
      if ! place_bridge_file "$rel" "$prefix_steam/$f"; then
        echo "=== could not copy $rel to $prefix_steam/$f ===" >> "$log" 2>&1 || true
        unstaged=1
      fi
    done
    if [ "$unstaged" -eq 1 ]; then
      show_alert "Steam files could not be copied" "Bridgeplay could not copy a file into this game's prefix. Open this prefix's bridgeplay-run.log for details."
      exit 1
    fi
  fi
  if [ "$bridge_stamped" = 0 ] && [ "${np_stamps_ready:-0}" = 1 ]; then
    stamp_key "$(bridge_inputs)"
    stamp_put bridge
  fi
  for f in "$prefix_steam"/*.dll "$prefix_steam"/*.so "$prefix_steam"/*.exe; do
    [ -f "$f" ] || continue
    case " $bridge_files " in
      *" ${f##*/} "*) ;;
      *) rm -f "$f" && echo "=== pruned stale ${f##*/} ===" >> "$log" 2>&1 ;;
    esac
  done
  verify_runner
  if ! install_lsteamclient_trigger; then
    show_alert "Steam files could not be copied" "Bridgeplay could not copy a file into this game's prefix. Open this prefix's bridgeplay-run.log for details."
    exit 1
  fi
  install_legacy_steam_dll
  install_runner_builtins
  export WINEDLLPATH="$prefix_steam:$WINEDLLPATH"
  # If the same DLL appears twice in WINEDLLOVERRIDES, the last entry wins.
  vc_overrides=$(native_vc_runtime)
  export WINEDLLOVERRIDES="${vc_overrides}${WINEDLLOVERRIDES:+$WINEDLLOVERRIDES;}steamclient=n;steamclient64=n;lsteamclient=b"
  native_client="$STEAM_COMPAT_CLIENT_INSTALL_PATH"
  if [ -z "$native_client" ]; then
    native_client="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$native_client"
  fi
  install_legacycompat
  link_legacy_steam_dll
  echo "=== bridge staged into $prefix_steam ===" >> "$log" 2>&1 || true
  echo "WINEDLLPATH=$WINEDLLPATH" >> "$log" 2>&1 || true
  echo "WINEDLLOVERRIDES=$WINEDLLOVERRIDES" >> "$log" 2>&1 || true
  echo "STEAM_COMPAT_CLIENT_INSTALL_PATH=$STEAM_COMPAT_CLIENT_INSTALL_PATH" >> "$log" 2>&1 || true
fi

export WINEDEBUG="${WINEDEBUG:-err+all,fixme-all}"
exec 8>&-
# Helpers report their own status. A game launch can still stop while its launcher bundle is
# built, so it keeps the abort report until the game starts.
[ "$verb" = waitforexitandrun ] || trap - EXIT
mark "launcher bundle"
printf 'launch_args=%s\n' "$launch_args" >> "$log" 2>&1 || true
printf '=== launching (%s): %s %s ===\n' "$verb" "$WINELOADER" "$*" >> "$log" 2>&1 || true

target="$1"
# A game can arrive as a URL with no install path to match, so the verb has to decide the route.
case "$verb" in
  waitforexitandrun) foreground=1 ;;
  *) foreground=0 ;;
esac

shim_exe="C:\\Program Files (x86)\\Steam\\steam.exe"

if [ "$foreground" = 0 ]; then
  status=0  # set -e would exit before the status is read
  case "$verb" in
    # runinprefix is the one verb the Linux client keeps on the raw loader.
    runinprefix)
      echo "=== running helper on raw loader: $* ===" >> "$log" 2>&1 || true
      "$WINELOADER" "$@" >> "$log" 2>&1 || status=$?
      ;;
    *)
      # A helper target can be a URL, which steam.exe resolves.
      echo "=== running helper through the shim: $* ===" >> "$log" 2>&1 || true
      "$WINELOADER" "$shim_exe" "$@" >> "$log" 2>&1 || status=$?
      ;;
  esac
  [ "${np_warm:-0}" != 1 ] || warm_session_end "$status"
  [ "$status" = 0 ] || [ "${np_stamps_ready:-0}" != 1 ] || stamps_clear
  echo "=== helper exited status=$status ===" >> "$log" 2>&1 || true
  exit $status
fi

# Fixes CrossOver window focus issues
steam_root="$(dirname "$(dirname "$(dirname "$STEAM_COMPAT_DATA_PATH")")")"
manifest="$steam_root/steamapps/appmanifest_$app_id.acf"
find_client_root "$STEAM_COMPAT_CLIENT_INSTALL_PATH"
# Icon stuff
read_app_meta
game_name="$meta_name"
if [ -z "$game_name" ] && [ -f "$manifest" ]; then
  game_name=$(sed -n 's/.*"name"[[:space:]]*"\(.*\)".*/\1/p' "$manifest" | head -1)
fi
[ -z "$game_name" ] && game_name=$(basename "$STEAM_COMPAT_INSTALL_PATH")
[ -z "$game_name" ] && game_name="Steam Game"
# shellcheck disable=SC1003 # the pair deletes a literal backslash, not a quote
bundle_name=$(printf '%s' "$game_name" | tr -d '/:"`$\\')
bundle_name=${bundle_name#"${bundle_name%%[!.]*}"}
[ -n "$bundle_name" ] || bundle_name="Steam Game"
game_name_xml=$(printf '%s' "$game_name" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
loader_root="$np_support/launchers/$app_id"
mkdir -p "$loader_root"
loader_app="$loader_root/$bundle_name.app"
find "$loader_root" -maxdepth 1 -name '.build.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
loader_work=$(mktemp -d "$loader_root/.build.XXXXXX")
loader_stage="$loader_work/new/$bundle_name.app"
loader_contents="$loader_stage/Contents"
loader_macos="$loader_contents/MacOS"
loader_res="$loader_contents/Resources"
mkdir -p "$loader_macos" "$loader_res"

icon_fetch_bg=1
icon_arg=""
icon_root="$loader_root"
if resolve_icon && cp -f "$icon_cache" "$loader_res/game.icns"; then
  icon_arg="  <key>CFBundleIconFile</key><string>game</string>"
fi
[ -n "$icon_arg" ] || echo "no icon resolved, launching without one" >> "$log" 2>&1 || true

uielement_arg=""
if [ "${NOTPROTON_HIDE_LAUNCHER_TILE:-0}" = "1" ]; then
  uielement_arg="  <key>LSUIElement</key><true/>"
  echo "launcher tile hidden by BRIDGEPLAY_HIDE_LAUNCHER_TILE" >> "$log" 2>&1 || true
fi
# macOS turns Game Mode on for a games-category app in full screen; LSSupportsGameMode=false opts out.
gamemode_arg=""
if [ "${NOTPROTON_GAME_MODE:-1}" = "0" ]; then
  gamemode_arg="  <key>LSSupportsGameMode</key><false/>"
  echo "Game Mode off by BRIDGEPLAY_GAME_MODE=0" >> "$log" 2>&1 || true
fi
cat > "$loader_contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$game_name_xml</string>
  <key>CFBundleDisplayName</key><string>$game_name_xml</string>
  <key>CFBundleIdentifier</key><string>com.notproton.launcher.$app_id</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>This game would like to access your microphone.</string>
  <key>NSCameraUsageDescription</key><string>This game would like to access your camera.</string>
  <key>NSLocalNetworkUsageDescription</key><string>This game would like to access devices on your local network.</string>
$uielement_arg
$gamemode_arg
$icon_arg
</dict>
</plist>
PLIST

# Launch stamps: a bundle the last good launch installed, with every input the same and its files
# untouched, is used as it is. Its Info.plist and icon are compared with the ones made above.
bundle_stamp="$loader_root/.bridgeplay-bundle-stamp"
bundle_engine_loader=$WINELOADER
bundle_inputs() {
  printf '%s\n' "$np_stamp_base" "$loader_app" "$app_id ${SteamGameId:-}" "$np_support" "$bundle_engine_loader"
  ls -a "$wine_unix" "${wine_unix%/*}" 2>/dev/null || true
  stat -f '%N %d:%i:%z:%Fm' "$bundle_engine_loader" "$wine_unix/ntdll.so" "${wine_unix%/*/*/*}/share/wine" 2>/dev/null || true
  [ ! -d "$loader_app" ] || find "$loader_app" -exec stat -f '%N %d:%i:%z:%Fm:%Lp' {} + 2>/dev/null | LC_ALL=C sort || true
}
bundle_reusable() {
  [ "${np_stamps:-0}" = 1 ] && own_note "$bundle_stamp" || return 1
  [ -d "$loader_app" ] && [ ! -L "$loader_app" ] || return 1
  for b in "$loader_root"/*.app "$loader_root"/.[!.]*.app; do
    [ -e "$b" ] || [ -L "$b" ] || continue
    [ "$b" = "$loader_app" ] || return 1
  done
  saved=$(cat "$bundle_stamp" 2>/dev/null) || return 1
  stamp_key "$(bundle_inputs)"
  [ -n "$stamp_new" ] && [ "$(printf '%s\n' "$saved" | sed -n 's/^key=//p')" = "$stamp_new" ] || return 1
  bundle_loader=$(printf '%s\n' "$saved" | sed -n 's/^loader=//p')
  bundle_hosts=$(printf '%s\n' "$saved" | sed -n 's/^hosts=//p')
  bundle_registered=$(printf '%s\n' "$saved" | sed -n 's/^registered=//p')
  case "$bundle_hosts" in 0|1) ;; *) return 1 ;; esac
  [ "$bundle_loader" = "$loader_app/Contents/MacOS/wine" ] || [ "$bundle_loader" = "$bundle_engine_loader" ] || return 1
  [ -x "$loader_app/Contents/MacOS/wine" ] && [ -x "$loader_app/Contents/MacOS/launcher" ] || return 1
  [ "$bundle_hosts" = 0 ] || [ "$loader_app/Contents/MacOS/ntdll.so" -ef "$wine_unix/ntdll.so" ] || return 1
  cmp -s "$loader_contents/Info.plist" "$loader_app/Contents/Info.plist" || return 1
  if [ -f "$loader_res/game.icns" ]; then
    cmp -s "$loader_res/game.icns" "$loader_app/Contents/Resources/game.icns" || return 1
  else
    [ ! -e "$loader_app/Contents/Resources/game.icns" ] || return 1
  fi
}
bundle_record() {
  stamp_key "$(bundle_inputs)"
  rm -f "$bundle_stamp.$$" 2>/dev/null || true
  [ -n "$stamp_new" ] || return 0
  { (umask 077; set -C; printf 'key=%s\nloader=%s\nhosts=%s\nregistered=%s\n' "$stamp_new" "$WINELOADER" \
      "$loader_hosts_ntdll" "$1" > "$bundle_stamp.$$") && mv -f "$bundle_stamp.$$" "$bundle_stamp"; } 2>/dev/null \
    || rm -f "$bundle_stamp.$$" 2>/dev/null || true
}
bundle_fast=0
bundle_registered=0
[ "${np_stamps_ready:-0}" != 1 ] || ! bundle_reusable || bundle_fast=1
[ "$bundle_fast" = 1 ] || rm -f "$bundle_stamp" 2>/dev/null || true

# macOS Game Mode reads the Info.plist of the bundle holding a process's executable. Wine starts
# every child process from "<folder of ntdll.so>/wine", so the bundle gets its own APFS clone of
# the loader and a hard link of ntdll.so (dyld matches the unix libraries' @rpath/ntdll.so to it
# by inode), plus the folders ntdll looks for next to itself and two levels up. A hard-linked
# loader shared its inode with the engine's and with ntdll's winetemp links, so the path macOS
# saw was whichever name was used last.
stage_loader() {
  loader_hosts_ntdll=0
  for f in "$wine_unix"/*; do
    [ -e "$f" ] || continue
    base=${f##*/}
    case "$base" in
      wine|wine.app) continue ;;
    esac
    ln -sfn "$f" "$loader_macos/$base"
  done
  wine_root=${wine_unix%/*/*/*}
  if [ "$WINELOADER" = "$wine_unix/wine" ] && [ -f "$wine_unix/ntdll.so" ] && [ -d "$wine_root/share/wine" ] &&
     ln "$wine_unix/ntdll.so" "$loader_macos/.ntdll.so" 2>/dev/null &&
     { cp -c "$WINELOADER" "$loader_macos/wine" 2>/dev/null || cp -p "$WINELOADER" "$loader_macos/wine"; } &&
     mv -f "$loader_macos/.ntdll.so" "$loader_macos/ntdll.so"; then
    for d in "${wine_unix%/*}"/*-unix "${wine_unix%/*}"/*-windows; do
      [ ! -d "$d" ] || ln -sfn "$d" "$loader_macos/${d##*/}"
    done
    ln -sfn "$wine_root/share" "$loader_stage/share"
    ln -sfn "$wine_root/bin" "$loader_stage/bin"
    loader_hosts_ntdll=1
    # aned (the Neural Engine daemon behind MetalFX upscaling) refuses to compile models for a
    # process whose code identity is a file path, which an unsigned loader has. The bundle's own
    # copy is signed ad hoc under the bundle's identifier; ad hoc signatures are deterministic, so
    # the bundle still compares unchanged. A signed loader keeps its signature and entitlements.
    if ! /usr/bin/codesign -d "$loader_macos/wine" >/dev/null 2>&1; then
      /usr/bin/codesign -s - -f -i "com.notproton.launcher.$app_id" "$loader_macos/wine" >/dev/null 2>&1 ||
        echo "loader could not be signed, MetalFX upscaling may fail" >> "$log" 2>&1 || true
    fi
  else
    rm -f "$loader_macos/.ntdll.so" "$loader_macos/wine"
    ln "$WINELOADER" "$loader_macos/wine" 2>/dev/null || cp "$WINELOADER" "$loader_macos/wine"
  fi
}
[ "$bundle_fast" = 1 ] || stage_loader
original_loader=$WINELOADER
if [ -x "$loader_macos/wine" ]; then
  WINELOADER="$loader_app/Contents/MacOS/wine"
  # A loader with com.apple.developer.* entitlements (CrossOver 27's, backed by a
  # provisioning profile in its own wine.app) is killed when run from the game's bundle,
  # so it runs where it is.
  if /usr/bin/codesign -d --entitlements - "$loader_macos/wine" 2>/dev/null | grep -q 'com\.apple\.developer\.'; then
    WINELOADER=$original_loader
    loader_hosts_ntdll=0
    echo "loader needs its own wine.app; running the engine's own loader" >> "$log" 2>&1 || true
  elif [ "$loader_hosts_ntdll" = 1 ]; then
    echo "loader and ntdll staged in bundle for game mode" >> "$log" 2>&1 || true
  else
    echo "loader staged in bundle for game mode" >> "$log" 2>&1 || true
  fi
elif [ "$bundle_fast" = 1 ]; then
  WINELOADER=$bundle_loader
  loader_hosts_ntdll=$bundle_hosts
  echo "loader in the bundle unchanged since the last good launch" >> "$log" 2>&1 || true
else
  echo "loader staging failed, game mode unavailable" >> "$log" 2>&1 || true
fi

cat > "$loader_macos/launcher" <<LAUNCHER
#!/bin/sh
export WINELOADER="$WINELOADER"
wine_log="$loader_root/bridgeplay-wine.log"
exec > "\$wine_log" 2>&1
shim="$np_support/overlay-shim.dylib"
# Off as np-native's is_off reads it: unset, 0, off, false or no, in any case
wants() { case "\$1" in ''|0|[Oo][Ff][Ff]|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]) return 1 ;; esac; }
if [ -n "\$STEAM_DYLD_INSERT_LIBRARIES" ]; then
  if [ -f "\$shim" ]; then
    export DYLD_INSERT_LIBRARIES="\$shim:\$STEAM_DYLD_INSERT_LIBRARIES"
    export NOTPROTON_OVERLAY_SHIM="\$shim"
  else
    export DYLD_INSERT_LIBRARIES="\$STEAM_DYLD_INSERT_LIBRARIES"
  fi
elif [ -f "\$shim" ] && { wants "\$NOTPROTON_FRAMEGEN" || wants "\$NOTPROTON_PERF_OVERLAY" ||
  { wants "\$NOTPROTON_FPS_LIMIT" && [ "\$NOTPROTON_FPS_LIMIT_OFF" != 1 ]; } || wants "\$NOTPROTON_SCALING_FILTER" ||
  wants "\$NOTPROTON_BENCH" || [ "\$NOTPROTON_SUSTAINED" = 1 ]; }; then
  # Frame generation, the performance overlay, the frame rate limit, the scaling filter,
  # frame-time capture and Cool and steady live in the shim, so it loads without the Steam overlay too.
  export DYLD_INSERT_LIBRARIES="\$shim"
  export NOTPROTON_OVERLAY_SHIM="\$shim"
fi
[ -n "\$NOTPROTON_GAME_CWD" ] && cd "\$NOTPROTON_GAME_CWD"
"$WINELOADER" "\$@"
exit \$?
LAUNCHER
chmod +x "$loader_macos/launcher"

bundle_listing() {
  (cd "$1" && find . | LC_ALL=C sort | while IFS= read -r p; do
    if [ -L "$p" ]; then
      printf 'l %s %s\n' "$p" "$(readlink "$p")"
    elif [ -d "$p" ]; then
      printf 'd %s\n' "$p"
    else
      printf 'f %s %s %s\n' "$p" "$(stat -f %Lp "$p")" "$(cksum < "$p")"
    fi
  done)
}
install_bundle() (
  if [ "${bundle_fast:-0}" = 1 ]; then
    rm -rf "$loader_work" || true
    echo "launcher bundle unchanged since the last good launch" >> "$log" 2>&1 || true
    exit 0
  fi
  exec 7>> "$loader_root/.lock"
  /usr/bin/lockf -s -t 30 7 || exit 1
  same=""
  for b in "$loader_root"/*.app; do
    # The same ntdll.so file too: an engine reinstalled with equal bytes has new inodes, and a
    # bundle still linked to the old one would load two ntdlls.
    if [ "$b" = "$loader_app" ] && [ -d "$b" ] && [ ! -L "$b" ] &&
       [ "$(bundle_listing "$b")" = "$(bundle_listing "$loader_stage")" ] &&
       { [ ! -e "$loader_stage/Contents/MacOS/ntdll.so" ] ||
         [ "$b/Contents/MacOS/ntdll.so" -ef "$loader_stage/Contents/MacOS/ntdll.so" ]; }; then
      same=1
    fi
  done
  if [ -n "$same" ]; then
    for b in "$loader_root"/*.app "$loader_root"/.[!.]*.app; do
      if [ "$b" != "$loader_app" ]; then rm -rf "$b" || true; fi
    done
    echo "launcher bundle unchanged" >> "$log" 2>&1 || true
  else
    stage_identity=$(stat -f '%d:%i' "$loader_stage") || exit 1
    loader_backup=$(mktemp -d "$loader_root/.backup.XXXXXX") || exit 1
    finish_bundle() {
      result=$?
      trap - EXIT
      trap '' HUP INT TERM
      installed_identity=$(stat -f '%d:%i' "$loader_app" 2>/dev/null) || installed_identity=""
      if [ "$installed_identity" != "$stage_identity" ]; then
        for saved in "$loader_backup"/* "$loader_backup"/.[!.]*; do
          [ -e "$saved" ] || [ -L "$saved" ] || continue
          mv "$saved" "$loader_root/${saved##*/}" || result=1
        done
        rmdir "$loader_backup" 2>/dev/null || result=1
      else
        rm -rf "$loader_backup" || true
      fi
      rm -rf "$loader_work" || true
      exit "$result"
    }
    trap 'finish_bundle' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for b in "$loader_root"/*.app "$loader_root"/.[!.]*.app "$loader_app"; do
      if [ -e "$b" ] || [ -L "$b" ]; then
        mv "$b" "$loader_backup/${b##*/}" || exit 1
      fi
    done
    mv "$loader_stage" "$loader_app" || exit 1
    echo "launcher bundle updated" >> "$log" 2>&1 || true
    finish_bundle
  fi
  rm -rf "$loader_work" || true
)
install_bundle
[ "$bundle_fast" = 1 ] || [ "${np_stamps_ready:-0}" != 1 ] || bundle_record 0

# CrossOver's ntdll (CW HACK 22144) starts each process from a hard link to the loader in
# winetemp-<inode>-<size>-<mtime s>-<mtime ns>/<exe>, outside the bundle, when WINEDLLPATH is
# set. When it can't write that folder it starts the loader itself, so the folder for the
# bundle's own loader is made read-only and empty.
block_loader_links() {
  bl_tmp=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) && [ -n "$bl_tmp" ] || return 0
  bl_stamp=$(stat -f '%i-%z-%m' "$1" 2>/dev/null) && bl_ns=$(stat -f '%.9Fm' "$1" 2>/dev/null) || return 0
  bl_ns=$(printf '%s' "${bl_ns##*.}" | sed 's/^0*//')
  bl_dir="${bl_tmp%/}/winetemp-$bl_stamp-${bl_ns:-0}"
  [ ! -L "$bl_dir" ] || return 0
  if [ -d "$bl_dir" ]; then
    chmod 700 "$bl_dir" && rm -f "$bl_dir"/* "$bl_dir"/.[!.]* 2>/dev/null
  fi
  if mkdir -p "$bl_dir" && chmod 500 "$bl_dir"; then
    echo "loader links blocked in $bl_dir" >> "$log" 2>&1 || true
  fi
}
if [ "$loader_hosts_ntdll" = 1 ] && [ "$WINELOADER" = "$loader_app/Contents/MacOS/wine" ]; then
  block_loader_links "$WINELOADER"
fi

kill_wine_prefix() {
  "$WINESERVER" -k >> "$log" 2>&1 || true
  "$WINESERVER" -w >> "$log" 2>&1 || true
  if command -v lsof >/dev/null 2>&1 && server_dir=$(prefix_server_dir); then
    if [ -d "$server_dir" ]; then
      survivors=$(lsof -t +D "$server_dir" 2>/dev/null | sort -u)
      if [ -n "$survivors" ]; then
        echo "=== sweeping prefix stragglers: $survivors ===" >> "$log" 2>&1 || true
        # shellcheck disable=SC2086 # survivors is a list of pids and has to split
        kill -9 $survivors 2>/dev/null || true
      fi
    fi
  fi
}

# Steam's "Exit Game" and the client shutting the game down both send a
# termination signal to this run script, this handles it
# shellcheck disable=SC2329 # the trap below invokes this
terminate() {
  np_terminated=1
  echo "=== termination signal received, killing wine prefix ===" >> "$log" 2>&1 || true
  kill_wine_prefix
  [ -n "$open_pid" ] && kill "$open_pid" 2>/dev/null || true
}
trap terminate TERM INT HUP

game_cwd="$(pwd)"
if [ -n "$gamefix_args" ]; then
  # shellcheck disable=SC2086 # ARGS tokens hold no spaces or glob characters and have to split
  set -- "$@" $gamefix_args
  echo "gamefix: game arguments are now: $*" >> "$log" 2>&1 || true
fi
if [ -n "$STEAM_DYLD_INSERT_LIBRARIES" ]; then
  echo "=== overlay injected from $STEAM_DYLD_INSERT_LIBRARIES ===" >> "$log" 2>&1 || true
else
  echo "=== client staged no overlay renderer, overlay disabled ===" >> "$log" 2>&1 || true
fi
set -- --args "$shim_exe" "$@"
for name in $(env | LC_ALL=C sed -nE 's/^(CX_APPLEGPTK_LIBD3DSHARED_PATH|SDL_GAMECONTROLLERCONFIG(_FILE)?|SDL_JOYSTICK_MFI|WINE_LARGE_ADDRESS_AWARE|WINE_CPU_TOPOLOGY|CX_FWD_COMPAT_GL_CTX|Steam[A-Za-z0-9]*|(CX_GRAPHICS|D3DM_|DXMT_|DXVK_|FEX_|MVK_|VKD3D_|STAGING_|MTL_|ROSETTA_)[A-Z0-9_]*|NOTPROTON_FRAMEGEN(_[A-Z]+)?|NOTPROTON_PERF_OVERLAY|NOTPROTON_BENCH|NOTPROTON_FPS_LIMIT(_OFF)?|NOTPROTON_SCALING_FILTER|NOTPROTON_SUSTAINED|NOTPROTON_QUICK_SETTINGS|NOTPROTON_NGX_SIGNER|NOTPROTON_NVAPI_DRIVER|NOTPROTON_DRIVER_VERSION|NOTPROTON_STDOUT_NULL|NOTPROTON_VSYNC|NOTPROTON_HIDE_WINE_EXPORTS|NOTPROTON_ROCKSTAR_DXGI|CX_ACTIVE_GRAPHICS_BACKEND)=.*/\1/p'); do
  eval "value=\$$name"
  # shellcheck disable=SC2154 # eval assigns value on the line above
  set -- --env "$name=$value" "$@"
done

# Anything this script does not know by name. A launch option NOTPROTON_ENV_FOO=bar gives
# the game FOO=bar, which is the only per-game way to set one, and Wine and the graphics
# layers take far more than the prefixes above.
np_env_passed=$(env | LC_ALL=C sed -nE 's/^NOTPROTON_ENV_([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' \
  | LC_ALL=C sort)
for name in $np_env_passed; do
  case "$name" in
    (DYLD_* | PATH | HOME | CX_ROOT | CX_HOME | STEAM_COMPAT_* | STEAM_DYLD_INSERT_LIBRARIES | \
     WINEPREFIX | WINELOADER | WINESERVER | WINEDLLPATH | WINEDLLOVERRIDES | WINEMSYNC | NOTPROTON_* | \
     BRIDGEPLAY_*)
      echo "=== NOTPROTON_ENV_$name would replace a setting this launch sets itself, ignored ===" \
        >> "$log" 2>&1 || true
      continue ;;
  esac
  eval "value=\$NOTPROTON_ENV_$name"
  set -- --env "$name=$value" "$@"
  echo "=== NOTPROTON_ENV_$name sets $name ===" >> "$log" 2>&1 || true
done
set -- \
  --env CX_ROOT="$CX_ROOT" \
  --env CX_HOME="$CX_HOME" \
  --env WINESERVER="$WINESERVER" \
  --env WINEDLLPATH="$WINEDLLPATH" \
  --env WINEDLLOVERRIDES="$WINEDLLOVERRIDES" \
  --env WINEMSYNC="$WINEMSYNC" \
  --env WINEPREFIX="$WINEPREFIX" \
  --env WINEDEBUG="$WINEDEBUG" \
  --env PATH="$PATH" \
  --env STEAM_COMPAT_DATA_PATH="$STEAM_COMPAT_DATA_PATH" \
  --env STEAM_COMPAT_INSTALL_PATH="$STEAM_COMPAT_INSTALL_PATH" \
  --env STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_COMPAT_CLIENT_INSTALL_PATH" \
  --env STEAM_COMPAT_APP_ID="$STEAM_COMPAT_APP_ID" \
  --env STEAM_DYLD_INSERT_LIBRARIES="$STEAM_DYLD_INSERT_LIBRARIES" \
  --env NOTPROTON_GAME_CWD="$game_cwd" "$@"
lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A"
lsregister="$lsregister/Frameworks/LaunchServices.framework/Support/lsregister"
if [ "$bundle_fast" = 1 ] && [ "$bundle_registered" = 1 ]; then
  echo "launcher bundle registered with Launch Services by the last good launch" >> "$log" 2>&1 || true
elif [ -x "$lsregister" ] && "$lsregister" -f "$loader_app" >> "$log" 2>&1; then
  [ "${np_stamps_ready:-0}" != 1 ] || bundle_record 1
fi
trap - EXIT
mark "game start"
np_started=$np_ms
np_terminated=0
launch_step start
if [ "${NOTPROTON_LAUNCH_SERVICES:-0}" = "1" ]; then
  open -n -W -a "$loader_app" "$@" >> "$log" 2>&1 5>&- &
else
  # A bundle started by `open` is its own TCC responsible process, so every game
  # needed a separate Input Monitoring grant before controllers worked. Started
  # from here it stays attributed to Steam, which already holds that grant, and
  # macOS still takes the Dock name and icon from the enclosing bundle. env -i
  # with the same --env list keeps the environment `open` would have given it.
  count=$#
  i=0
  mode=vars
  while [ "$i" -lt "$count" ]; do
    arg=$1
    shift
    i=$((i + 1))
    case "$mode:$arg" in
      vars:--env)
        set -- "$@" "$1"
        shift
        i=$((i + 1))
        ;;
      vars:--args)
        mode=args
        set -- "$@" "$loader_app/Contents/MacOS/launcher"
        ;;
      args:*) set -- "$@" "$arg" ;;
    esac
  done
  echo "launching bundle directly so input permission stays with Steam" >> "$log" 2>&1 || true
  env -i HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" SHELL="$SHELL" TMPDIR="$TMPDIR" \
    __CF_USER_TEXT_ENCODING="$__CF_USER_TEXT_ENCODING" "$@" >> "$log" 2>&1 5>&- &
fi
open_pid=$!
/usr/bin/caffeinate -d -i -w "$open_pid" >> "$log" 2>&1 5>&- &
status=0
wait "$open_pid" || status=$?
# Before the step file tells it to quit: a panel still up saw no window.
np_watched=0
[ -z "${np_panel_pid:-}" ] || ! process_running "$np_panel_pid" || np_watched=1
launch_step ended
np_now_ms
np_ended=$np_ms
np_ran=$(((np_ended - np_started) / 1000))
echo "=== game exited status=$status, killing wine prefix ===" >> "$log" 2>&1 || true
kill_wine_prefix
wine_log="$loader_root/bridgeplay-wine.log"
[ -z "$STEAM_COMPAT_DATA_PATH" ] \
  || record_session "$wine_log" "$np_ran" "$np_terminated" "$status"
# After the teardown, so reading a long Wine log never holds the prefix up.
exit_summary "$status" "$np_ran" "$np_terminated" "$wine_log" >> "$log" 2>&1 || true
np_window=-
launch_times "$np_started" "$np_ended" "$wine_log" "$np_watched" >> "$log" 2>&1 || true
outcome=$(exit_outcome "$status" "$np_ran" "$np_terminated" "$wine_log") || outcome="exit_code unknown"
write_last_launch "${outcome%% *}" "$status" "$np_ran" "${outcome#* }" "$np_window"
launch_ended "${outcome%% *}" "$np_window"
echo "=== wine prefix killed, session ending ===" >> "$log" 2>&1 || true
exit $status
