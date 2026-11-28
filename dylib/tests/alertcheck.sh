#!/bin/sh
# alertcheck: the run script's alerts in the player's language (alert_language, alert_text,
# show_alert, notify_user in compat_run.sh) and the table dylib/alert_strings.py builds from
# the app's catalogue. Every English string an alert uses must have it, ru and zh-Hans.
# shellcheck disable=SC2034 # the functions under test read np_tool_dir and verb
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CATALOG="$ROOT/app/Sources/BridgeplayApp/Resources/Localization/Localizable.xcstrings"
[ -f "$SRC" ] || { echo "==> alertcheck: $SRC not present, skipped"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "==> alertcheck: python3 not present, skipped"; exit 0; }

extract() { sed -n "/^$1() {\$/,/^}\$/p" "$SRC"; }
functions=""
for name in alert_language alert_text alert_join alert_safe show_alert notify_user launch_step; do
	body=$(extract "$name")
	[ -n "$body" ] || { echo "FAIL: $name not found in $SRC"; exit 1; }
	functions="$functions
$body"
done
eval "$functions"

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
mkdir "$work/tool"
python3 "$ROOT/dylib/alert_strings.py" --table "$CATALOG" "$work/tool/bridgeplay-alerts.tsv"

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

echo "== every alert string is translated =="
if python3 - "$SRC" "$work/tool/bridgeplay-alerts.tsv" <<'PY'; then ok "all alert strings in it, ru, zh-Hans"; else fails=$((fails + 1)); fi
import re, sys
src = open(sys.argv[1], encoding="ascii").read()
have = {}
for line in open(sys.argv[2], encoding="utf-8"):
    lang, key, _ = line.rstrip("\n").split("\t")
    have.setdefault(key, set()).add(lang)

def literals(text, at):
    # Double-quoted words after a call, up to the first one that is not a plain literal.
    out = []
    while True:
        while text[at:at + 1] == " " or text[at:at + 2] == "\\\n":
            at += 2 if text[at] == "\\" else 1
            while text[at:at + 1] == " ":
                at += 1
        if text[at:at + 1] != '"':
            return out
        end = at + 1
        while text[end] != '"':
            end += 2 if text[end] == "\\" else 1
        word = text[at + 1:end]
        if "$" in word or "\\" in word:
            return out
        out.append(word)
        at = end + 1

used = set()
for m in re.finditer(r"\b(?:show_alert|notify_user|rebuild_prefix|alert_text) (?=\")", src):
    used.update(literals(src, m.end()))
used.update(re.findall(r'^\s*fex_(?:title|body)="([^"$]*)"$', src, re.M))
used -= {"", "$1", "$2"}
missing = [f"{key!r}: {', '.join(sorted({'it', 'ru', 'zh-Hans'} - have.get(key, set())))}"
           for key in sorted(used) if have.get(key, set()) != {"it", "ru", "zh-Hans"}]
if len(used) < 40:
    missing.append(f"only {len(used)} alert strings found, the scan is broken")
print(f"  ok    {len(used)} alert strings found")
for item in missing:
    print(f"  FAIL  no translation: {item}")
sys.exit(1 if missing else 0)
PY

echo "== the Steam start notification is a catalogue key =="
if python3 - "$ROOT/dylib/feats/breaker.c" "$CATALOG" <<'PY'; then ok "breaker.c's notification is translated in the app"; else fails=$((fails + 1)); fi
import json, re, sys
c = open(sys.argv[1], encoding="utf-8").read()
strings = json.load(open(sys.argv[2], encoding="utf-8"))["strings"]
args = re.search(r'static void notify_trip\(void\) \{\s*notify\((.*?)\);', c, re.S)
words = [re.sub(r'"\s*"', "", w) for w in re.findall(r'"(?:[^"\\]|\\.)*"(?:\s*"(?:[^"\\]|\\.)*")*', args[1])] if args else []
words = [w[1:-1] for w in words]
bad = [w for w in words if not all(strings.get(w, {}).get("localizations", {}).get(l, {}).get("stringUnit", {}).get("state") == "translated" for l in ("it", "ru", "zh-Hans"))]
if len(words) != 2 or bad:
    print(f"  FAIL  notify_trip's subtitle and body are not translated catalogue keys: {bad or words}")
    sys.exit(1)
PY

# lang_case <app languages> <Mac languages>: the language picked, "-" for no setting.
defaults() {
	case "$2" in
	com.bridgeplay.Bridgeplay) [ "$app_langs" != - ] || return 1; langs=$app_langs ;;
	*) [ "$mac_langs" != - ] || return 1; langs=$mac_langs ;;
	esac
	printf '(\n'
	for l in $langs; do printf '    "%s",\n' "$l"; done
	printf ')\n'
}
lang_case() { (app_langs=$1 mac_langs=$2 np_alert_lang="" && alert_language && printf '%s' "$np_alert_lang"); }

echo "== language =="
is "English Mac" en "$(lang_case - "en-US id-ID")"
is "Russian Mac" ru "$(lang_case - "ru-RU en-US")"
is "first language the alerts have" it "$(lang_case - "id-ID it-IT ru-RU")"
is "Traditional Chinese is not Simplified" ru "$(lang_case - "zh-Hant-TW ru-RU")"
is "Simplified Chinese" zh-Hans "$(lang_case - "zh-Hans-CN en-US")"
is "Bridgeplay's own language wins" it "$(lang_case "it" "ru-RU")"
is "an app language the alerts lack falls back to the Mac's" ru "$(lang_case "ja" "ru-RU")"
is "no language the alerts have" en "$(lang_case - "id-ID ja-JP")"
is "no defaults at all" en "$(lang_case - -)"

echo "== text =="
np_tool_dir="$work/tool"
t() { (np_alert_lang=$1 && shift && alert_text "$@"); }
is "English fills the args" "exfat has no symbolic links. Move the game to an APFS library." \
	"$(t en "{1} has no symbolic links. Move the game to an APFS library." exfat)"
is "Russian" "Rosetta 2 не установлена" "$(t ru "Rosetta 2 is not installed")"
is "Chinese, two args in order" "Rosetta 游戏容器需重建后才能用于 FEX。" \
	"$(t zh-Hans "A {1} prefix must be rebuilt for {2}." Rosetta FEX)"
is "Italian" "CrossOver 25, tramite Rosetta" "$(t it "{1}, running through {2}" "CrossOver 25" Rosetta)"
is "an arg is never read as a placeholder" "Check bridgeplay-run.log at /a/{2}/b." "$(t en "Check bridgeplay-run.log at {1}." "/a/{2}/b" x)"
is "a missing arg is empty" "Check bridgeplay-run.log at ." "$(t en "Check bridgeplay-run.log at {1}.")"
is "a string not in the table stays English" "Not in the table {1}" "$(t ru "Not in the table {1}" "{1}")"
is "already translated text passes through" "Rosetta 2 не установлена" "$(t ru "Rosetta 2 не установлена")"
is "Chinese sentences join without a space" "甲。乙。" "$(np_alert_lang=zh-Hans && alert_join "甲。" "乙。")"
is "others with one" "A. B." "$(np_alert_lang=ru && alert_join "A." "B.")"
is "an empty first sentence adds no space" "B." "$(alert_join "" "B.")"
np_tool_dir="$work/nowhere"
is "no table: English" "Rosetta 2 is not installed" "$(t ru "Rosetta 2 is not installed")"
np_tool_dir="$work/tool"

echo "== dialogs and notifications =="
# shellcheck disable=SC2034 # read by show_alert
verb=waitforexitandrun
# shellcheck disable=SC2329 # show_alert runs this in place of the dialog
osascript() { cat > /dev/null; shift; printf '%s\n' "$@" > "$work/osascript"; }
(np_alert_lang=ru && show_alert "This library can't hold the prefix" "{1} has no symbolic links. Move the game to an APFS library." exfat)
is "show_alert passes the Russian title and message" "Эта библиотека не может хранить префикс
В exfat нет символических ссылок. Переместите игру в библиотеку на APFS." \
	"$(cat "$work/osascript")"
(verb=run && np_alert_lang=ru && : > "$work/osascript" && show_alert "a" "b")
is "no dialog for Steam's run helpers" "" "$(cat "$work/osascript")"
# shellcheck disable=SC2329 # notify_user runs this in place of LaunchServices
open() { printf '%s\n' "$@" > "$work/open"; }
(np_alert_lang=zh-Hans && notify_user "New prefix for this game" "The old one is still in {1}, with any saves or sign-ins only it had." '/Vol/"x"/42' && wait)
is "notify_user hands the app Chinese text, quotes taken out" "-n
-g
-b
com.bridgeplay.Bridgeplay
--args
--notify
Bridgeplay
此游戏使用新的游戏容器
旧的仍在 /Vol/x/42，只存于其中的存档或登录信息也在那里。" "$(cat "$work/open")"

if [ "$fails" -gt 0 ]; then
	echo "==> alertcheck: $fails failure(s)"
	exit 1
fi
echo "==> alertcheck: alerts follow the player's language, every alert string translated"
