#!/bin/sh
# The G1 acceptance kit: test-key Bridgeplay clients, local stable and beta feeds in any F0 shape,
# and a local server Sparkle accepts. The run sheet is docs/G1.md.
#
#   sh scripts/g1-kit.sh <command> [args]     # G1_KIT=<dir> (default out/g1-kit), G1_PORT (8765)
#
# Safe by construction:
#   - a throwaway Ed25519 key made in the kit folder, never the keychain; its public half is
#     written into the test bundles only, never into app/Info.plist;
#   - the test client is dev.bridgeplay.g1kit, not com.bridgeplay.Bridgeplay, so its defaults are
#     its own (~/Library/Preferences/dev.bridgeplay.g1kit.plist; cfprefsd ignores the sandbox);
#   - its executable is a wrapper that sets CFFIXED_USER_HOME to ~/.bridgeplay-g1kit, so its
#     support folder, logs and caches live there, not in the real Bridgeplay's folders (Sparkle's
#     relaunch goes through the wrapper too);
#   - reset sets steamAppPath to a missing Steam.app and pauses the Steam patch keeper, so the
#     client never reads or patches /Applications/Steam.app;
#   - the client is installed in the kit folder, never /Applications, and the feeds are served on
#     127.0.0.1 only.

set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
kit=${G1_KIT:-$repo/out/g1-kit}
port=${G1_PORT:-8765}
base_url=http://127.0.0.1:$port
bundle_id=dev.bridgeplay.g1kit
sandbox_name=.bridgeplay-g1kit
sandbox=$HOME/$sandbox_name
installed=$kit/Applications/Bridgeplay.app
sparkle=${SPARKLE_BIN:-$repo/app/.build/artifacts/sparkle/Sparkle/bin}
ns=https://bridgeplay.dev/ns/appcast/1

die() { echo "==> g1-kit: $*" >&2; exit 1; }
say() { echo "==> $*"; }

usage() {
	cat <<'EOF'
usage: sh scripts/g1-kit.sh <command>

  client [--ref REF]           build a test client from the working tree (name "head") or from
                               REF, e.g. v0.7.63 (name "REF"); makes the throwaway key once
  app LABEL BUILD [--client N] stamp a test app: kit/apps/BUILD, zipped and signed in kit/www;
                               a LABEL with -beta.N is a beta build
  feed stable|beta [--unsigned] [--no-catchup] [--github] ITEM...
                               write kit/www/<stable|beta>.xml, items in the order given.
                               ITEM is BUILD, BUILD@CHANNEL (beta, beta-critical) or, for a
                               stable item, BUILD=LIST (its containsBetas, e.g. 82,84 or 81-85);
                               a stable item without =LIST gets an empty element. --no-catchup
                               leaves the element out, --unsigned leaves the feed signature out,
                               --github writes kit/github-<feed>.xml with release URLs instead
  serve [--slow SECONDS]       serve kit/www on 127.0.0.1:$G1_PORT, logging to kit/server.log;
                               --slow holds each zip that long before sending it (X-8)
  scenario NAME                set up a run-sheet row: apps, feeds, a fresh sandbox, the start
                               build installed. NAME: beta-off X-1 X-2 X-3 X-4 X-5 X-5c X-6 X-8
                               R2-pending R2-resumable R2-optin X-10 X-23 old-client
  reset                        empty the sandbox (~/.bridgeplay-g1kit) and the client's defaults,
                               then write the safety defaults and the local beta feed override
  clean                        remove the client's defaults, sandbox and caches
  install BUILD                put kit/apps/BUILD at kit/Applications/Bridgeplay.app
  launch | quit | kill         open the installed client, quit it, or kill -9 it
  defaults ARGS...             run `defaults ARGS` on the client's domain, dev.bridgeplay.g1kit, e.g.
                               defaults write BetaUpdatesUI -bool true
  status                       installed build, defaults, update-check lines, served requests
  setup-parse [REF]            parse kit/github-stable.xml with the native installer's parser
                               from the working tree (or REF)
EOF
}

# --- helpers ---------------------------------------------------------------------------------

plist() { /usr/libexec/PlistBuddy "$@"; }

# Runs a command as the client sees its home. defaults still uses the real home (cfprefsd).
in_sandbox() { CFFIXED_USER_HOME=$sandbox "$@"; }

need_sparkle() {
	[ -x "$sparkle/sign_update" ] || die "no Sparkle tools at $sparkle; swift build --package-path app, or set SPARKLE_BIN"
}

key_file=$kit/key/ed25519.key
pub_file=$kit/key/ed25519.pub

make_key() {
	[ -s "$key_file" ] && [ -s "$pub_file" ] && return 0
	mkdir -p "$kit/key"
	chmod 700 "$kit/key"
	(umask 077 && head -c 32 /dev/urandom | base64 >"$key_file")
	# Sparkle's key file is the base64 Ed25519 seed; CryptoKit gives its public half.
	xcrun swift -e 'import CryptoKit
import Foundation
let text = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))!
print(try! Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())' \
		"$key_file" >"$pub_file"
	[ "$(wc -c <"$pub_file")" -gt 40 ] || die "could not derive the public key"
	say "made the throwaway key in $kit/key"
}

is_running() { pgrep -f "$installed/Contents/MacOS/" >/dev/null 2>&1; }

# --- client: build the app's Swift package at a ref -------------------------------------------

# head_source: the tree id of app/ as it is in the working tree, uncommitted and untracked files
# included. Built in a copy of the index, so the real one is untouched.
head_source() {
	mkdir -p "$kit/run"
	_idx=$kit/run/source-index
	cp "$(git -C "$repo" rev-parse --path-format=absolute --git-path index)" "$_idx"
	GIT_INDEX_FILE=$_idx git -C "$repo" add -A -- app || die "can't read the working tree of app/"
	GIT_INDEX_FILE=$_idx git -C "$repo" write-tree
}

cmd_client() {
	ref=""
	while [ $# -gt 0 ]; do
		case $1 in
			--ref) ref=${2:?--ref needs a ref}; shift 2 ;;
			*) die "client: unknown argument $1" ;;
		esac
	done
	make_key
	if [ -z "$ref" ]; then
		name="head"
		pkg=$repo/app
		source=$(head_source)
	else
		name=$(printf '%s' "$ref" | tr -c 'A-Za-z0-9._-\n' '_')
		src=$kit/src/$name
		if [ ! -f "$src/app/Package.swift" ]; then
			git -C "$repo" rev-parse --verify --quiet "$ref^{commit}" >/dev/null || die "no commit $ref"
			rm -rf "$src" && mkdir -p "$src"
			git -C "$repo" archive "$ref" app | tar -x -C "$src"
		fi
		pkg=$src/app
	fi
	say "building $name (swift build -c release in $pkg)"
	swift build --package-path "$pkg" -c release
	bin=$(swift build --package-path "$pkg" -c release --show-bin-path)
	t=$kit/clients/$name/Bridgeplay.app
	rm -rf "$t"
	mkdir -p "$t/Contents/MacOS" "$t/Contents/Resources" "$t/Contents/Frameworks"
	cp "$pkg/Info.plist" "$t/Contents/Info.plist"
	cp "$bin/BridgeplayApp" "$t/Contents/MacOS/BridgeplayApp.bin"
	install_name_tool -add_rpath @executable_path/../Frameworks "$t/Contents/MacOS/BridgeplayApp.bin" 2>/dev/null || true
	ditto "$bin/Sparkle.framework" "$t/Contents/Frameworks/Sparkle.framework"
	for b in "$bin"/BridgeplayApp_*.bundle; do
		cp -R "$b" "$t/Contents/Resources/"
	done
	cp -R "$t/Contents/Resources/BridgeplayApp_BridgeplayApp.bundle/Contents/Resources/"*.lproj "$t/Contents/Resources/" 2>/dev/null || true
	# The client's own home, for every launch, Sparkle's relaunch included.
	cat >"$t/Contents/MacOS/BridgeplayApp" <<EOF
#!/bin/sh
# g1-kit test client: its own home, so the real Bridgeplay's data is never read or written.
CFFIXED_USER_HOME="\$HOME/$sandbox_name"
export CFFIXED_USER_HOME
mkdir -p "\$CFFIXED_USER_HOME/Library/Application Support/bridgeplay"
exec "\$(dirname "\$0")/BridgeplayApp.bin" "\$@"
EOF
	chmod 755 "$t/Contents/MacOS/BridgeplayApp"
	git -C "$repo" rev-parse --short "${ref:-HEAD}" >"$kit/clients/$name/commit"
	[ -n "$ref" ] || echo "$source" >"$kit/clients/head/source"
	say "client $name: $t"
}

# --- app: stamp a version, build and channel, sign and zip ------------------------------------

cmd_app() {
	[ $# -ge 2 ] || die "usage: app LABEL BUILD [--client NAME]"
	label=$1 build=$2
	shift 2
	client="head"
	while [ $# -gt 0 ]; do
		case $1 in
			--client) client=${2:?}; shift 2 ;;
			*) die "app: unknown argument $1" ;;
		esac
	done
	case $build in '' | *[!0-9]*) die "build $build is not a number" ;; esac
	case $label in *-beta.*) channel=beta ;; *) channel=stable ;; esac
	t=$kit/clients/$client/Bridgeplay.app
	[ -d "$t" ] || die "no client $client; run: sh scripts/g1-kit.sh client${client#head}"
	need_sparkle
	make_key
	a=$kit/apps/$build
	rm -rf "$a" && mkdir -p "$a"
	ditto "$t" "$a/Bridgeplay.app"
	p=$a/Bridgeplay.app/Contents/Info.plist
	plist -c "Set :CFBundleIdentifier $bundle_id" \
		-c "Set :CFBundleShortVersionString $label" \
		-c "Set :CFBundleVersion $build" \
		-c "Set :NotProtonVersion 0.0.1" \
		-c "Set :SUFeedURL $base_url/stable.xml" \
		-c "Set :SUPublicEDKey $(cat "$pub_file")" \
		-c "Set :SUScheduledCheckInterval 3600" "$p"
	# 0.7.63 has no BridgeplayChannel key; an old client is always stable.
	if plist -c 'Print :BridgeplayChannel' "$p" >/dev/null 2>&1; then
		plist -c "Set :BridgeplayChannel $channel" "$p"
	elif [ "$channel" = beta ]; then
		die "client $client has no BridgeplayChannel, so it cannot be a beta"
	fi
	codesign --force --sign - "$a/Bridgeplay.app/Contents/MacOS/BridgeplayApp.bin" 2>/dev/null
	codesign --force --sign - "$a/Bridgeplay.app" 2>/dev/null
	codesign --verify --strict "$a/Bridgeplay.app" || die "the stamped app does not verify"
	mkdir -p "$kit/www/$build"
	rm -f "$kit/www/$build/Bridgeplay.zip"
	ditto -c -k --sequesterRsrc --keepParent "$a/Bridgeplay.app" "$kit/www/$build/Bridgeplay.zip"
	printf 'label=%s\nchannel=%s\nclient=%s\n' "$label" "$channel" "$client" >"$a/info"
	"$sparkle/sign_update" --ed-key-file "$key_file" "$kit/www/$build/Bridgeplay.zip" >"$a/enclosure"
	say "app $label ($build, $channel, client $client)"
}

app_field() { sed -n "s/^$2=//p" "$kit/apps/$1/info"; }

# --- feed ------------------------------------------------------------------------------------

cmd_feed() {
	[ $# -ge 1 ] || die "usage: feed stable|beta [--unsigned] [--no-catchup] [--github] ITEM..."
	name=$1
	shift
	case $name in stable | beta) ;; *) die "feed: stable or beta, not $name" ;; esac
	signed=1 catchup=1 github=0
	while [ $# -gt 0 ]; do
		case $1 in
			--unsigned) signed=0 ;;
			--no-catchup) catchup=0 ;;
			--github) github=1 ;;
			-*) die "feed: unknown option $1" ;;
			*) break ;;
		esac
		shift
	done
	need_sparkle
	mkdir -p "$kit/www"
	if [ "$github" -eq 1 ]; then out=$kit/github-$name.xml; else out=$kit/www/$name.xml; fi
	tmp=$out.tmp
	{
		echo '<?xml version="1.0" standalone="yes"?>'
		echo "<rss xmlns:bridgeplay=\"$ns\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\" version=\"2.0\">"
		echo '    <channel>'
		echo '        <title>Bridgeplay</title>'
	} >"$tmp"
	for spec in "$@"; do
		build=${spec%%[@=]*}
		[ -f "$kit/apps/$build/info" ] || die "no app $build; run: sh scripts/g1-kit.sh app LABEL $build"
		label=$(app_field "$build" label)
		channel=""
		list=""
		haslist=0
		case $spec in
			*@*) channel=${spec#*@} ;;
			*=*) list=${spec#*=}; haslist=1 ;;
		esac
		case $channel in '' | beta | beta-critical) ;; *) die "$spec: the channel is beta or beta-critical" ;; esac
		[ -z "$channel" ] && [ "$(app_field "$build" channel)" = beta ] && channel=beta
		if [ -n "$channel" ] && [ "$haslist" -eq 1 ]; then die "$spec: a channel item has no containsBetas"; fi
		if [ "$github" -eq 1 ]; then
			url=https://github.com/raymondchins/Bridgeplay/releases/download/v$label/Bridgeplay.zip
		else
			url=$base_url/$build/Bridgeplay.zip
		fi
		{
			echo '        <item>'
			echo "            <title>$label</title>"
			echo "            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>"
			echo "            <description><![CDATA[<ul><li>g1-kit test build $label ($build)</li></ul>]]></description>"
			[ -n "$channel" ] && echo "            <sparkle:channel>$channel</sparkle:channel>"
			echo "            <sparkle:version>$build</sparkle:version>"
			echo "            <sparkle:shortVersionString>$label</sparkle:shortVersionString>"
			echo '            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>'
			[ -z "$channel" ] && [ "$catchup" -eq 1 ] && echo "            <bridgeplay:containsBetas>$list</bridgeplay:containsBetas>"
			echo '            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>'
			echo "            <enclosure url=\"$url\" $(cat "$kit/apps/$build/enclosure") type=\"application/octet-stream\"/>"
			echo '        </item>'
		} >>"$tmp"
	done
	{
		echo '    </channel>'
		echo '</rss>'
	} >>"$tmp"
	xmllint --noout "$tmp" || die "the $name feed is not well-formed"
	mv "$tmp" "$out"
	# Signed after its last edit (F0.5).
	if [ "$signed" -eq 1 ]; then "$sparkle/sign_update" --ed-key-file "$key_file" "$out" >/dev/null; fi
	say "$name feed ($([ "$signed" -eq 1 ] && echo signed || echo unsigned)$([ "$catchup" -eq 1 ] || echo ', no catch-up element')): ${*:-no items} -> $out"
}

# --- serve -----------------------------------------------------------------------------------

cmd_serve() {
	slow=0
	while [ $# -gt 0 ]; do
		case $1 in
			--slow) slow=${2:?}; shift 2 ;;
			*) die "serve: unknown argument $1" ;;
		esac
	done
	[ -d "$kit/www" ] || die "no feeds yet; run a scenario or feed first"
	mkdir -p "$kit/run"
	cat >"$kit/run/serve.py" <<'EOF'
import http.server, sys, time, functools
root, port, slow, log = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.endswith(".zip") and slow > 0:
            time.sleep(slow)
        super().do_GET()
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()
    def log_message(self, fmt, *args):
        line = "%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args)
        with open(log, "a") as f:
            f.write(line)
        sys.stderr.write(line)
server = http.server.ThreadingHTTPServer(("127.0.0.1", port), functools.partial(Handler, directory=root))
print("serving %s on http://127.0.0.1:%d (zips held %ss), log %s" % (root, port, slow, log), flush=True)
server.serve_forever()
EOF
	exec python3 -I "$kit/run/serve.py" "$kit/www" "$port" "$slow" "$kit/server.log"
}

# --- the client's sandbox --------------------------------------------------------------------

cmd_defaults() {
	verb=$1
	shift
	in_sandbox defaults "$verb" "$bundle_id" "$@"
}

cmd_reset() {
	if is_running; then die "the test client is running; sh scripts/g1-kit.sh quit"; fi
	in_sandbox defaults delete "$bundle_id" >/dev/null 2>&1 || true
	case $sandbox in "$HOME"/"$sandbox_name") rm -rf "$sandbox" ;; *) die "unexpected sandbox $sandbox" ;; esac
	# Sparkle's installer runs from launchd, outside the sandbox, and stages here.
	rm -rf "$HOME/Library/Caches/$bundle_id"
	mkdir -p "$sandbox/Library/Application Support/bridgeplay" "$sandbox/no-steam"
	in_sandbox defaults write "$bundle_id" setupAssistantFinished -bool true
	in_sandbox defaults write "$bundle_id" steamAppPath "$sandbox/no-steam/Steam.app"
	in_sandbox defaults write "$bundle_id" steamPatchKeeperPaused -bool true
	# The beta feed's URL is built into the app; the override keeps every check local.
	in_sandbox defaults write "$bundle_id" BetaFeedURLOverride "$base_url/beta.xml"
	say "sandbox reset: $sandbox (domain $bundle_id)"
}

# Removes every trace of the kit outside the kit folder: the domain, the sandbox, the caches.
cmd_clean() {
	cmd_reset >/dev/null
	in_sandbox defaults delete "$bundle_id" >/dev/null 2>&1 || true
	rm -rf "$sandbox" "$HOME/Library/Caches/$bundle_id"
	say "removed $bundle_id's defaults, $sandbox and ~/Library/Caches/$bundle_id (the kit folder $kit stays)"
}

cmd_install() {
	[ $# -eq 1 ] || die "usage: install BUILD"
	[ -d "$kit/apps/$1/Bridgeplay.app" ] || die "no app $1"
	if is_running; then die "the test client is running; sh scripts/g1-kit.sh quit"; fi
	mkdir -p "$kit/Applications"
	rm -rf "$installed"
	ditto "$kit/apps/$1/Bridgeplay.app" "$installed"
	say "installed $(app_field "$1" label) ($1) at $installed"
}

cmd_launch() {
	[ -d "$installed" ] || die "nothing installed"
	open "$installed"
}

cmd_quit() {
	is_running || { say "not running"; return 0; }
	osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
	say "asked the test client to quit"
}

cmd_kill() {
	if pkill -9 -f "$installed/Contents/MacOS/"; then say "killed the test client"; else say "not running"; fi
}

cmd_status() {
	if [ -d "$installed" ]; then
		p=$installed/Contents/Info.plist
		say "installed: $(plist -c 'Print :CFBundleShortVersionString' "$p") ($(plist -c 'Print :CFBundleVersion' "$p")), channel $(plist -c 'Print :BridgeplayChannel' "$p" 2>/dev/null || echo 'none (old client)'), $(is_running && echo running || echo 'not running')"
	else
		say "nothing installed"
	fi
	say "defaults ($bundle_id):"
	for k in BetaUpdates BetaUpdatesUI BetaFeedURLOverride StableFeedURLOverride; do
		v=$(in_sandbox defaults read "$bundle_id" "$k" 2>/dev/null) || v="(not set)"
		t=$(in_sandbox defaults read-type "$bundle_id" "$k" 2>/dev/null | sed 's/^Type is //') || t=""
		echo "    $k = $v${t:+ ($t)}"
	done
	say "update lines (sandbox bridgeplay.log):"
	grep -h 'update' "$sandbox/Library/Application Support/bridgeplay/bridgeplay.log" 2>/dev/null | tail -n 8 | sed 's/^/    /' || true
	say "served (kit/server.log):"
	tail -n 8 "$kit/server.log" 2>/dev/null | sed 's/^/    /' || true
}

# --- setup-parse -----------------------------------------------------------------------------

cmd_setup_parse() {
	ref=${1:-}
	feed=$kit/github-stable.xml
	[ -f "$feed" ] || die "no $feed; run: sh scripts/g1-kit.sh feed stable --github ITEM"
	w=$kit/run/setup-parse
	rm -rf "$w" && mkdir -p "$w/src"
	if [ -n "$ref" ]; then
		git -C "$repo" archive "$ref" app/Sources/BridgeplayInstallerCore | tar -x -C "$w/src"
	else
		mkdir -p "$w/src/app/Sources"
		cp -R "$repo/app/Sources/BridgeplayInstallerCore" "$w/src/app/Sources/"
	fi
	cat >"$w/main.swift" <<'EOF'
import Foundation
let release = try InstallerRelease.parse(appcast: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
print("setup parsed: \(release.shortVersion) (\(release.build)), macOS \(release.minimumOS), \(release.archiveURL.absoluteString)")
EOF
	xcrun swiftc -swift-version 6 "$w/src/app/Sources/BridgeplayInstallerCore/"*.swift "$w/main.swift" -o "$w/parse" 2>"$w/build.log" \
		|| { cat "$w/build.log" >&2; die "could not build the parser"; }
	"$w/parse" "$feed"
}

# --- scenarios -------------------------------------------------------------------------------

# Builds: stable 80, 83 and 86 as 0.8.<build>; betas 82 and 84 as 0.8.<build>-beta.1; the old
# client is 0.7.63 (80) from its tag.
ensure_app() { # BUILD LABEL [CLIENT]
	c=${3:-head}
	if [ "$c" = head ]; then
		# Rebuilt whenever app/ changed since, committed or not.
		[ -d "$kit/clients/head/Bridgeplay.app" ] && [ "$(cat "$kit/clients/head/source" 2>/dev/null)" = "$(head_source)" ] \
			|| cmd_client
	else
		[ -d "$kit/clients/$c/Bridgeplay.app" ] || cmd_client --ref "$c"
	fi
	# Stamped from this client since it was last built.
	if [ -f "$kit/apps/$1/info" ] && [ "$(app_field "$1" label)" = "$2" ] && [ "$(app_field "$1" client)" = "$c" ] \
		&& [ -z "$(find "$kit/clients/$c/commit" -newer "$kit/apps/$1/info")" ]; then return 0; fi
	cmd_app "$2" "$1" --client "${3:-head}"
}

start() { # BUILD: a fresh sandbox with BUILD installed
	cmd_reset
	cmd_install "$1"
	: >"$kit/server.log"
}

cmd_scenario() {
	[ $# -eq 1 ] || die "usage: scenario NAME"
	row=$1
	case $row in
		beta-off | X-[1-6] | X-5c | X-8 | X-10 | X-23 | R2-pending | R2-resumable | R2-optin | old-client) ;;
		*) die "no scenario $row" ;;
	esac
	case $row in
		X-10 | X-23 | old-client) ensure_app 80 0.7.63 v0.7.63 ;;
		*) ensure_app 80 0.8.80 ;;
	esac
	ensure_app 82 0.8.82-beta.1
	ensure_app 83 0.8.83
	ensure_app 84 0.8.84-beta.1
	ensure_app 86 0.8.86
	beta_ui() { cmd_defaults write BetaUpdatesUI -bool true; }
	enrol() { cmd_defaults write BetaUpdates -bool true; }
	case $row in
		beta-off)
			start 80
			cmd_feed stable 83=
			cmd_feed beta 83= 84 ;;
		X-1)
			start 80
			cmd_feed stable 83=
			cmd_feed beta 83= 82 ;;
		X-2 | X-8)
			start 80
			cmd_feed stable 80=
			cmd_feed beta 80= 82
			beta_ui ;;
		X-3)
			start 82
			enrol
			cmd_feed stable 83=
			cmd_feed beta 83= ;;
		X-4)
			start 82
			enrol
			cmd_feed stable 80=
			cmd_feed beta 80= 84@beta-critical ;;
		X-5 | X-5c)
			start 82
			enrol
			beta_ui
			cmd_feed stable 80=
			if [ "$row" = X-5 ]; then cmd_feed beta 80= 84; else cmd_feed beta 80= 84@beta-critical; fi ;;
		X-6)
			start 82
			cmd_feed stable 86=82,84
			cmd_feed beta 86=82,84 ;;
		R2-pending | R2-resumable)
			start 82
			enrol
			beta_ui
			cmd_feed stable 80=
			cmd_feed beta 80= 84
			# A waiting update installs even when the app is killed, so a resumable one needs
			# Sparkle to download it without installing it on quit.
			if [ "$row" = R2-resumable ]; then cmd_defaults write SUAutomaticallyUpdate -bool false; fi ;;
		R2-optin)
			start 80
			beta_ui
			cmd_feed stable 83=
			cmd_feed beta 83= 84 ;;
		X-10)
			start 80
			cmd_feed stable 83=
			cmd_feed beta 83= 84
			enrol
			beta_ui ;;
		X-23)
			start 82
			enrol
			beta_ui
			cmd_feed stable 83=
			cmd_feed beta 83= ;;
		old-client)
			start 80
			cmd_feed stable 83=82
			cmd_feed stable --github 83=82
			cmd_feed beta 83=82 84 ;;
		*) die "no scenario $row" ;;
	esac
	say "scenario $row ready; with the server running: sh scripts/g1-kit.sh launch"
}

[ $# -ge 1 ] || { usage; exit 1; }
command=$1
shift
case $command in
	client) cmd_client "$@" ;;
	app) cmd_app "$@" ;;
	feed) cmd_feed "$@" ;;
	serve) cmd_serve "$@" ;;
	scenario) cmd_scenario "$@" ;;
	reset) cmd_reset ;;
	clean) cmd_clean ;;
	install) cmd_install "$@" ;;
	launch) cmd_launch ;;
	quit) cmd_quit ;;
	kill) cmd_kill ;;
	defaults) [ $# -ge 1 ] || die "usage: defaults ARGS..."; cmd_defaults "$@" ;;
	status) cmd_status ;;
	setup-parse) cmd_setup_parse "$@" ;;
	help | -h | --help) usage ;;
	*) usage; exit 1 ;;
esac
