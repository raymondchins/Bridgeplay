#!/bin/sh
# shellcheck disable=SC2016 # the sh -ec programs expand their own variables
set -e
SRC="${1:-$(dirname "$0")/../feats/compat_run.sh}"
[ -f "$SRC" ] || { echo "gamefixescheck: $SRC not present, skipped"; exit 0; }

functions=""
for name in gamefix_log valid_dll_overrides gamefix_reason gamefix_read gamefix_apply_env \
	load_gamefixes resolve_msync graphics_log d3dmetal_engine backend_dlls managed_dlls backend_available \
	backend_record pe_word pe_words pe_rva_offset imports_d3d12 select_backend stage_backend_file restore_stock_dll \
	activate_backend record_backend compose_dll_overrides; do
	body=$(sed -n "/^$name() {\$/,/^}\$/p" "$SRC")
	[ -n "$body" ] || { echo "FAIL: $name not found in $SRC"; exit 1; }
	functions="$functions
$body"
done
public_names=$(sed -n '/^for np_name in $(env /,/^done$/p' "$SRC")
[ -n "$public_names" ] || { echo "FAIL: the BRIDGEPLAY_ to NOTPROTON_ loop not found"; exit 1; }
bridge_line=$(grep 'export WINEDLLOVERRIDES=' "$SRC" | grep 'lsteamclient=b' | sed 's/^[[:space:]]*//')
[ -n "$bridge_line" ] || { echo "FAIL: the bridge WINEDLLOVERRIDES line not found"; exit 1; }
forward=$(sed -n '/^for name in $(env /,/^done$/p' "$SRC")
[ -n "$forward" ] || { echo "FAIL: the launcher environment loop not found"; exit 1; }
launcher_body=$(sed -n '/^cat > "\$loader_macos\/launcher" <<LAUNCHER$/,/^LAUNCHER$/p' "$SRC")
[ -n "$launcher_body" ] || { echo "FAIL: the launcher heredoc not found"; exit 1; }
append_args=$(sed -n '/^if \[ -n "\$gamefix_args" \]; then$/,/^fi$/p' "$SRC")
[ -n "$append_args" ] || { echo "FAIL: the ARGS append not found"; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n         want [%s]\n         got  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has() { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1" "a line with $2" "$(cat "$3")"; fi; }
lacks() { if grep -qF -- "$2" "$3"; then bad "$1" "no line with $2" "$(cat "$3")"; else ok "$1"; fi; }

# A fresh compatdata, support folder and engine per case. LAYOUT is a list of
# backend/arch/name.dll files, "legacy" for no notproton-backends folder.
case_dir=""
new_case() {
	case_dir=$(mktemp -d "$work/case.XXXXXX")
	mkdir -p "$case_dir/support/gamefixes-default" "$case_dir/support/gamefixes" \
		"$case_dir/data/pfx/drive_c/windows/system32" "$case_dir/data/pfx/drive_c/windows/syswow64" \
		"$case_dir/game"
	for arch in x86_64-windows i386-windows; do
		mkdir -p "$case_dir/engine/lib/wine/$arch"
		for dll in dxgi d3d10 d3d11 d3d10core d3d12 d3d9; do
			printf 'stock %s %s\n' "$arch" "$dll" > "$case_dir/engine/lib/wine/$arch/$dll.dll"
		done
	done
	: > "$case_dir/log"
	printf 'MZ plain d3d11 game\n' > "$case_dir/game/game.exe"
}
engine() {
	for file in "$@"; do
		case "$file" in
			d3dmetal.enabled) mkdir -p "$case_dir/engine/lib/notproton-backends"
				: > "$case_dir/engine/lib/notproton-backends/d3dmetal.enabled" ;;
			# WinecxD3DMetal.link: Wine's four set aside, Apple's forwarders linked in their place.
			d3dmetal-linked)
				stock="$case_dir/engine/lib/notproton-backends/wine-stock/x86_64-windows"
				mkdir -p "$stock" "$case_dir/gptk"
				: > "$case_dir/engine/lib/notproton-backends/d3dmetal.enabled"
				for dll in dxgi d3d10 d3d11 d3d12; do
					mv "$case_dir/engine/lib/wine/x86_64-windows/$dll.dll" "$stock/$dll.dll"
					printf 'apple %s\n' "$dll" > "$case_dir/gptk/$dll.dll"
					ln -s "$case_dir/gptk/$dll.dll" "$case_dir/engine/lib/wine/x86_64-windows/$dll.dll"
				done
				printf 'apple nvapi64\n' > "$case_dir/gptk/nvapi64.dll"
				ln -s "$case_dir/gptk/nvapi64.dll" "$case_dir/engine/lib/wine/x86_64-windows/nvapi64.dll"
				ln -s "$case_dir/gptk/nvapi64.dll" "$case_dir/engine/lib/wine/x86_64-windows/nvapi.dll"
				printf 'apple nvngx-on-metalfx\n' > "$case_dir/gptk/nvngx-on-metalfx.dll"
				ln -s "$case_dir/gptk/nvngx-on-metalfx.dll" "$case_dir/engine/lib/wine/x86_64-windows/nvngx.dll" ;;
			msync) : > "$case_dir/engine/.notproton-msync" ;;
			empty) mkdir -p "$case_dir/engine/lib/notproton-backends" ;;
			*) mkdir -p "$case_dir/engine/lib/notproton-backends/${file%/*}"
				printf 'backend %s\n' "$file" > "$case_dir/engine/lib/notproton-backends/$file" ;;
		esac
	done
}
full_engine() {
	engine dxmt/x86_64-windows/dxgi.dll dxmt/x86_64-windows/d3d11.dll \
		dxmt/x86_64-windows/d3d10core.dll dxmt/x86_64-windows/winemetal.dll \
		dxvk/x86_64-windows/d3d11.dll dxvk/x86_64-windows/d3d10core.dll \
		dxvk/i386-windows/d3d11.dll dxvk/i386-windows/d3d10core.dll
}
default_conf() { printf '%s\n' "$@" > "$case_dir/support/gamefixes-default/4242.conf"; }
user_conf() { printf '%s\n' "$@" > "$case_dir/support/gamefixes/4242.conf"; }
sys() { cat "$case_dir/data/pfx/drive_c/windows/$1/$2.dll" 2>/dev/null || echo missing; }

# Runs the script's sequence: conf, msync, backend, overrides, bridge trio. ENV holds the
# launch options. Prints KEY=value lines for the outcome.
launch() {
	verb=$1
	target=$2
	shift 2
	env -i PATH="$PATH" HOME="$HOME" "$@" \
		functions="$functions" bridge_line="$bridge_line" public_names="$public_names" \
		app_id=4242 verb="$verb" log="$case_dir/log" \
		np_support="$case_dir/support" CX_ROOT="$case_dir/engine" \
		STEAM_COMPAT_DATA_PATH="$case_dir/data" WINEPREFIX="$case_dir/data/pfx" \
		sh -ec '
			eval "$public_names"
			eval "$functions"
			gamefix_keys="" gamefix_backend="" gamefix_dlloverrides="" gamefix_msync="" gamefix_nvapi="" gamefix_dlss_fg="" gamefix_args=""
			backend_root="$CX_ROOT/lib/notproton-backends"
			load_gamefixes || true
			resolve_msync
			export WINEMSYNC="${WINEMSYNC:-0}"
			select_backend "$1"
			activate_backend || true
			record_backend || true
			graphics_log "backend=$backend ($backend_from)"
			compose_dll_overrides
			eval "$bridge_line"
			for v in backend WINEDLLOVERRIDES WINEMSYNC msync_from NOTPROTON_RETINA NOTPROTON_FRAMEGEN \
				NOTPROTON_FRAMEGEN_QUALITY NOTPROTON_FRAMEGEN_UI NOTPROTON_FRAMEGEN_FALLBACK NOTPROTON_FRAMEGEN_ENGINE CX_GRAPHICS_BACKEND \
				DXVK_HUD VKD3D_CONFIG WINEDEBUG MTL_HUD_ENABLED D3DM_VENDOR_ID D3DM_DEVICE_ID D3DM_DEVICE_DESCRIPTION NOTPROTON_NGX_SIGNER NOTPROTON_DRIVER_VERSION CX_ACTIVE_GRAPHICS_BACKEND NOTPROTON_VSYNC NOTPROTON_HIDE_WINE_EXPORTS CX_FWD_COMPAT_GL_CTX gamefix_args; do
				eval "printf \"%s=%s\\n\" \$v \"\${$v-<unset>}\""
			done
		' launch "$target" > "$case_dir/out" 2>&1 || echo "launch exited $?" >> "$case_dir/out"
}
got() { sed -n "s/^$1=//p" "$case_dir/out"; }
trio="steamclient=n;steamclient64=n;lsteamclient=b"

# Minimal PE images: one .rdata section at RVA 0x1000 (file 0x200) holding the import
# descriptors, KERNEL32.dll at file 0x300 and the string D3D12.dll at file 0x310. "import"
# lists D3D12.dll as a second descriptor, "string" only carries the string.
le() {
	v=$1 n=$2 bytes=""
	while [ "$n" -gt 0 ]; do
		bytes="$bytes$(printf '\\%03o' $((v & 255)))"
		v=$((v >> 8)) n=$((n - 1))
	done
	printf '%s' "$bytes"
}
put() {
	# shellcheck disable=SC2059 # the escapes are the bytes to write
	printf "$3" | dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null
}
pe_fixture() {
	dd if=/dev/zero of="$1" bs=1024 count=1 2>/dev/null
	put "$1" 0 'MZ'
	put "$1" 60 "$(le 64 4)"
	put "$1" 64 'PE\000\000'
	put "$1" 68 "$(le 34404 2)"
	put "$1" 70 "$(le 1 2)"
	if [ "$2" = 64 ]; then osize=240 magic=523 dirs=200; else osize=224 magic=267 dirs=184; fi
	put "$1" 84 "$(le "$osize" 2)"
	put "$1" 88 "$(le "$magic" 2)"
	put "$1" $((dirs - 4)) "$(le 16 4)"
	put "$1" $((dirs + 8)) "$(le 4096 4)"
	put "$1" $((dirs + 12)) "$(le 60 4)"
	sec=$((88 + osize))
	put "$1" "$sec" '.rdata'
	put "$1" $((sec + 8)) "$(le 512 4)"
	put "$1" $((sec + 12)) "$(le 4096 4)"
	put "$1" $((sec + 16)) "$(le 512 4)"
	put "$1" $((sec + 20)) "$(le 512 4)"
	put "$1" 524 "$(le 4352 4)"
	put "$1" 528 "$(le 4480 4)"
	put "$1" 768 'KERNEL32.dll\000'
	put "$1" 784 'D3D12.dll\000'
	if [ "$3" = import ]; then
		put "$1" 544 "$(le 4368 4)"
		put "$1" 548 "$(le 4488 4)"
	fi
}

echo "== parser: allow-list and rejections"
new_case
full_engine
default_conf '# shipped fix' '' '  DXVK_HUD=fps  ' "VKD3D_CONFIG=dxr$(printf '\r')" \
	'WINEDEBUG=-all' 'PATH=/evil' 'DYLD_INSERT_LIBRARIES=/evil.dylib' 'lower=1' 'no equals sign' \
	"DXMT_A=\$(touch $case_dir/pwned)" 'DXMT_B=`touch pwned`' 'DXMT_C="quoted"' "DXMT_D='single'" \
	'BACKEND=vulkan' 'MSYNC=2' 'RETINA=yes' 'DLLOVERRIDES=dxgi=native' 'DLLOVERRIDES=;=n' \
	'DXMT_=1' 'MTL_HUD_ENABLED=1' 'FRAMEGEN=4' 'FRAMEGEN_QUALITY=ultra' 'FRAMEGEN_UI=2' \
	'FRAMEGEN_FALLBACK=yes' 'FRAMEGEN_ENGINE=fsr' 'FRAMEGEN_OTHER=1' 'CX_FWD_COMPAT_GL_CTX=1'
launch waitforexitandrun "$case_dir/game/game.exe"
is "a padded value is trimmed" "fps" "$(got DXVK_HUD)"
is "a CRLF line ends cleanly" "dxr" "$(got VKD3D_CONFIG)"
is "WINEDEBUG is allowed" "-all" "$(got WINEDEBUG)"
is "MTL_HUD_ENABLED is allowed" "1" "$(got MTL_HUD_ENABLED)"
is "CX_FWD_COMPAT_GL_CTX is allowed" "1" "$(got CX_FWD_COMPAT_GL_CTX)"
is "PATH is not on the allow-list" "0" "$(grep -c '^PATH=/evil' "$case_dir/out" || true)"
has "PATH is logged as rejected" "line 6 rejected PATH: not on the allow-list" "$case_dir/log"
has "DYLD_INSERT_LIBRARIES is rejected" "rejected DYLD_INSERT_LIBRARIES: not on the allow-list" "$case_dir/log"
has "a lower-case key is rejected" "line 8 rejected: not KEY=VALUE" "$case_dir/log"
has "a line without = is rejected" "line 9 rejected: not KEY=VALUE" "$case_dir/log"
has "\$( is rejected" "rejected DXMT_A: a backtick" "$case_dir/log"
is "and never runs" "no" "$([ -e "$case_dir/pwned" ] && echo yes || echo no)"
has "a backtick is rejected" "rejected DXMT_B: a backtick" "$case_dir/log"
has "double quotes are rejected" "rejected DXMT_C: a backtick" "$case_dir/log"
has "single quotes are rejected" "rejected DXMT_D: a backtick" "$case_dir/log"
has "an unknown backend is rejected" "rejected BACKEND: not dxmt, dxvk, wined3d or d3dmetal" "$case_dir/log"
has "MSYNC must be 0 or 1" "rejected MSYNC: not 0 or 1" "$case_dir/log"
has "RETINA must be 0 or 1" "rejected RETINA: not 0 or 1" "$case_dir/log"
has "a bad override order is rejected" "line 17 rejected DLLOVERRIDES: not Wine override syntax" "$case_dir/log"
has "an override without a name is rejected" "line 18 rejected DLLOVERRIDES: not Wine override syntax" "$case_dir/log"
has "a bare prefix is not a variable" "rejected DXMT_: not on the allow-list" "$case_dir/log"
has "FRAMEGEN must be a mode" "rejected FRAMEGEN: not 0, 1, 2, 3 or adaptive" "$case_dir/log"
has "FRAMEGEN_QUALITY must be a quality" "rejected FRAMEGEN_QUALITY: not performance, balanced or quality" "$case_dir/log"
has "FRAMEGEN_UI must be 0 or 1" "rejected FRAMEGEN_UI: not 0 or 1" "$case_dir/log"
has "FRAMEGEN_FALLBACK must be 0 or 1" "rejected FRAMEGEN_FALLBACK: not 0 or 1" "$case_dir/log"
has "FRAMEGEN_ENGINE must be an engine" "rejected FRAMEGEN_ENGINE: not own or metalfx" "$case_dir/log"
has "an unknown FRAMEGEN_ key is not on the allow-list" "rejected FRAMEGEN_OTHER: not on the allow-list" "$case_dir/log"
is "a rejected FRAMEGEN leaves frame generation unset" "<unset>" "$(got NOTPROTON_FRAMEGEN)"
has "applied values are logged" "applied DXVK_HUD=fps from the default conf" "$case_dir/log"

echo "== precedence: launch options > user conf > default conf > auto > default"
new_case
full_engine
default_conf 'DXVK_HUD=1' 'BACKEND=dxmt' 'WINEDEBUG=+loaddll' 'DLLOVERRIDES=xinput1_3=n,b;dinput8=n,b'
user_conf 'DXVK_HUD=fps' 'BACKEND=dxvk' 'DLLOVERRIDES=dinput8=b'
launch waitforexitandrun "$case_dir/game/game.exe" WINEDEBUG=-all
is "user conf beats default conf" "fps" "$(got DXVK_HUD)"
is "launch options beat both confs" "-all" "$(got WINEDEBUG)"
has "the kept launch option is logged" "WINEDEBUG kept from the launch options, the default conf value is not applied" "$case_dir/log"
has "the user conf replacing a key is logged" "user conf line 1 replaces the earlier DXVK_HUD" "$case_dir/log"
is "user conf BACKEND beats default conf BACKEND" "dxvk" "$(got backend)"
is "the later file wins DLLOVERRIDES whole" \
	"d3d10core,d3d11=n,b;dxgi=b;dinput8=b;$trio" "$(got WINEDLLOVERRIDES)"
new_case
full_engine
user_conf 'BACKEND=dxvk' 'DLLOVERRIDES=dinput8=n,b;dxgi=n'
launch waitforexitandrun "$case_dir/game/game.exe" BRIDGEPLAY_BACKEND=wined3d WINEDLLOVERRIDES='dinput8=b'
is "BRIDGEPLAY_BACKEND beats the conf" "wined3d" "$(got backend)"
is "overrides run backend, conf, launch options, then the Steam trio" \
	"d3d10core,d3d11,dxgi=b;dinput8=n,b;dxgi=n;dinput8=b;$trio" "$(got WINEDLLOVERRIDES)"
new_case
full_engine
default_conf 'BACKEND=dxvk'
pe_fixture "$case_dir/game/game.exe" 64 import
launch waitforexitandrun "$case_dir/game/game.exe"
is "a conf BACKEND beats auto-detection" "dxvk" "$(got backend)"
new_case
full_engine
launch waitforexitandrun "$case_dir/game/game.exe" BRIDGEPLAY_BACKEND=metal
is "an invalid BRIDGEPLAY_BACKEND falls through to auto" "dxmt" "$(got backend)"
has "and is logged" "BRIDGEPLAY_BACKEND is not dxmt, dxvk, wined3d or d3dmetal, ignored" "$case_dir/log"

echo "== auto-detect reads the import table"
new_case
full_engine
pe_fixture "$case_dir/game/game.exe" 64 import
launch waitforexitandrun "$case_dir/game/game.exe"
is "a PE32+ game importing D3D12.dll gets wined3d" "wined3d" "$(got backend)"
has "the reason is logged" "auto-detected, the game imports d3d12.dll" "$case_dir/log"
pe_fixture "$case_dir/game/game.exe" 32 import
launch waitforexitandrun "$case_dir/game/game.exe"
is "so does a PE32 game" "wined3d" "$(got backend)"
pe_fixture "$case_dir/game/game.exe" 64 string
launch waitforexitandrun "$case_dir/game/game.exe"
is "the string d3d12.dll in .rdata alone does not count" "dxmt" "$(got backend)"
pe_fixture "$case_dir/game/game.exe" 32 string
launch waitforexitandrun "$case_dir/game/game.exe"
is "nor in a PE32 game" "dxmt" "$(got backend)"
pe_fixture "$case_dir/game/game.exe" 64 import
dd if="$case_dir/game/game.exe" of="$case_dir/game/cut.exe" bs=600 count=1 2>/dev/null
launch waitforexitandrun "$case_dir/game/cut.exe"
is "an import name cut off by a short file detects nothing" "dxmt" "$(got backend)"
dd if="$case_dir/game/game.exe" of="$case_dir/game/cut.exe" bs=100 count=1 2>/dev/null
launch waitforexitandrun "$case_dir/game/cut.exe"
is "a header cut off detects nothing" "dxmt" "$(got backend)"
put "$case_dir/game/game.exe" 60 "$(le 4000000000 4)"
launch waitforexitandrun "$case_dir/game/game.exe"
is "a PE header offset past the end detects nothing" "dxmt" "$(got backend)"
printf 'MZ\0\0kernel32.dll\0D3D12.DLL\0' > "$case_dir/game/game.exe"
launch waitforexitandrun "$case_dir/game/game.exe"
is "an MZ file that is no PE detects nothing" "dxmt" "$(got backend)"
pe_fixture "$case_dir/game/game.exe" 64 string
pe_fixture "$case_dir/game/Engine.dll" 64 import
launch waitforexitandrun "$case_dir/game/game.exe"
is "a DLL beside the game does not count" "dxmt" "$(got backend)"
new_case
full_engine
pe_fixture "$case_dir/game/game.exe" 64 import
launch waitforexitandrun "$case_dir/game/game.exe" NOTPROTON_BACKEND=dxmt
is "NOTPROTON_BACKEND beats auto-detection" "dxmt" "$(got backend)"
new_case
full_engine
launch waitforexitandrun 'steam://rungameid/4242'
is "a target that is no file gets the default" "dxmt" "$(got backend)"
has "logged as default" "backend=dxmt (default)" "$case_dir/log"
new_case
full_engine
pe_fixture "$case_dir/game/game.exe" 64 import
launch waitforexitandrun "$case_dir/game/game.exe"
launch run "$case_dir/game/iscriptevaluator.exe"
is "a helper keeps the backend the game last ran with" "wined3d" "$(got backend)"

echo "== the Steam panel's CX_GRAPHICS_BACKEND"
new_case
full_engine
engine d3dmetal.enabled
user_conf 'BACKEND=dxmt'
for pair in D3DMetal:d3dmetal dxmt:dxmt DXVK:dxvk wined3d:d3dmetal OpenGL:d3dmetal wine:d3dmetal; do
	launch waitforexitandrun "$case_dir/game/game.exe" CX_GRAPHICS_BACKEND="${pair%%:*}"
	is "CX_GRAPHICS_BACKEND=${pair%%:*} beats the conf as ${pair#*:}" "${pair#*:}" "$(got backend)"
done
launch waitforexitandrun "$case_dir/game/game.exe" CX_GRAPHICS_BACKEND=D3DMetal
is "d3dmetal still exports the lower-case name" "d3dmetal" "$(got CX_GRAPHICS_BACKEND)"
launch waitforexitandrun "$case_dir/game/game.exe" CX_GRAPHICS_BACKEND=vulkan
is "an unknown value falls through to the conf" "dxmt" "$(got backend)"
has "and is logged" "CX_GRAPHICS_BACKEND is not a backend this engine maps, ignored" "$case_dir/log"
launch waitforexitandrun "$case_dir/game/game.exe" CX_GRAPHICS_BACKEND=
is "an empty value falls through to the conf" "dxmt" "$(got backend)"
launch waitforexitandrun "$case_dir/game/game.exe" CX_GRAPHICS_BACKEND=dxvk NOTPROTON_BACKEND=dxmt
is "NOTPROTON_BACKEND beats CX_GRAPHICS_BACKEND" "dxmt" "$(got backend)"
new_case
full_engine
for pair in wined3d:wined3d OpenGL:wined3d wine:wined3d; do
	launch waitforexitandrun "$case_dir/game/game.exe" CX_GRAPHICS_BACKEND="${pair%%:*}"
	is "without D3DMetal CX_GRAPHICS_BACKEND=${pair%%:*} is ${pair#*:}" "${pair#*:}" "$(got backend)"
done

echo "== fallback when the engine lacks a backend"
new_case
engine dxmt/x86_64-windows/dxgi.dll dxmt/x86_64-windows/d3d11.dll dxmt/x86_64-windows/d3d10core.dll
launch waitforexitandrun "$case_dir/game/game.exe" NOTPROTON_BACKEND=dxvk
is "dxvk falls back to dxmt" "dxmt" "$(got backend)"
has "with the reason" "dxvk is not available (no x86_64 DLLs in notproton-backends/dxvk), falling back to dxmt" "$case_dir/log"
new_case
engine empty
launch waitforexitandrun "$case_dir/game/game.exe" NOTPROTON_BACKEND=dxvk
is "dxvk falls through dxmt to wined3d" "wined3d" "$(got backend)"
new_case
engine dxvk/x86_64-windows/d3d11.dll
launch waitforexitandrun "$case_dir/game/game.exe"
is "the dxmt default falls back to wined3d" "wined3d" "$(got backend)"
new_case
full_engine
launch waitforexitandrun "$case_dir/game/game.exe" NOTPROTON_BACKEND=d3dmetal
is "d3dmetal without the marker falls back to dxmt" "dxmt" "$(got backend)"
is "and leaves CX_GRAPHICS_BACKEND alone" "<unset>" "$(got CX_GRAPHICS_BACKEND)"
new_case
full_engine
engine d3dmetal.enabled
launch waitforexitandrun "$case_dir/game/game.exe" NOTPROTON_BACKEND=d3dmetal
is "d3dmetal with the marker" "d3dmetal" "$(got backend)"
is "selects D3DMetal in the engine" "d3dmetal" "$(got CX_GRAPHICS_BACKEND)"
is "and keeps every D3D DLL builtin, d3d10 and d3d12 too" "d3d10,d3d10core,d3d11,d3d12,dxgi=b;$trio" "$(got WINEDLLOVERRIDES)"
launch waitforexitandrun "$case_dir/game/game.exe" NOTPROTON_BACKEND=d3dmetal CX_GRAPHICS_BACKEND=dxmt
is "NOTPROTON_BACKEND=d3dmetal sets CX_GRAPHICS_BACKEND over the panel's" "d3dmetal" "$(got CX_GRAPHICS_BACKEND)"
has "and says so" "CX_GRAPHICS_BACKEND=dxmt replaced by d3dmetal" "$case_dir/log"

echo "== WineCX with D3DMetal linked as the builtin"
new_case
full_engine
engine d3dmetal-linked
launch waitforexitandrun 'steam://rungameid/4242'
is "the default is d3dmetal" "d3dmetal" "$(got backend)"
has "logged as default" "backend=d3dmetal (default)" "$case_dir/log"
is "every D3D DLL is builtin, Apple's nvapi64 and nvngx disabled" "d3d10,d3d10core,d3d11,d3d12,dxgi=b;nvapi64,nvngx=d;$trio" "$(got WINEDLLOVERRIDES)"
is "CX_GRAPHICS_BACKEND is exported" "d3dmetal" "$(got CX_GRAPHICS_BACKEND)"
launch waitforexitandrun "$case_dir/game/game.exe"
is "a D3D11 game auto-detects d3dmetal" "d3dmetal" "$(got backend)"
has "with the reason" "auto-detected, the engine has D3DMetal" "$case_dir/log"
pe_fixture "$case_dir/game/game.exe" 64 import
launch waitforexitandrun "$case_dir/game/game.exe"
is "a D3D12 game auto-detects d3dmetal, not wined3d" "d3dmetal" "$(got backend)"
has "with the reason" "backend=d3dmetal (auto-detected, the game imports d3d12.dll)" "$case_dir/log"
launch waitforexitandrun "$case_dir/game/game.exe" NOTPROTON_BACKEND=wined3d
is "an explicit wined3d runs d3dmetal" "d3dmetal" "$(got backend)"
has "and says why" "wined3d is not available (D3DMetal replaces Wine's Direct3D in this engine), falling back to d3dmetal" "$case_dir/log"
user_conf 'BACKEND=wined3d'
launch waitforexitandrun "$case_dir/game/game.exe"
is "so does a conf BACKEND=wined3d" "d3dmetal" "$(got backend)"
user_conf 'BACKEND=dxmt'
launch waitforexitandrun "$case_dir/game/game.exe"
is "dxmt still works per game" "dxmt" "$(got backend)"
is "as natives, with Apple's d3d10 and d3d12 builtin" "d3d10core,d3d11,dxgi=n,b;d3d10,d3d12=b;nvapi64,nvngx=d;$trio" "$(got WINEDLLOVERRIDES)"
is "dxmt dxgi is in system32" "backend dxmt/x86_64-windows/dxgi.dll" "$(sys system32 dxgi)"
is "and CX_GRAPHICS_BACKEND is left alone" "<unset>" "$(got CX_GRAPHICS_BACKEND)"
user_conf 'BACKEND=dxvk'
launch waitforexitandrun "$case_dir/game/game.exe"
is "dxvk still works per game" "d3d10core,d3d11=n,b;d3d10,d3d12,dxgi=b;nvapi64,nvngx=d;$trio" "$(got WINEDLLOVERRIDES)"
is "the stale dxmt dxgi goes back to Wine's set-aside copy, never Apple's" "stock x86_64-windows dxgi" "$(sys system32 dxgi)"
user_conf ''
launch waitforexitandrun "$case_dir/game/game.exe"
is "back on d3dmetal, dxvk's d3d11 goes back to Wine's copy" "stock x86_64-windows d3d11" "$(sys system32 d3d11)"
is "and nothing of Apple's is copied into the prefix" "0" "$(grep -rl '^apple ' "$case_dir/data/pfx" | wc -l | tr -d ' ')"
user_conf 'NVAPI=1'
launch waitforexitandrun "$case_dir/game/game.exe"
is "a conf NVAPI=1 turns Apple's nvapi64 and nvngx (DLSS) on" "d3d10,d3d10core,d3d11,d3d12,dxgi=b;nvapi64,nvngx=b;$trio" "$(got WINEDLLOVERRIDES)"
is "and D3DMetal reports an NVIDIA adapter" "0x10de 0x2684 NVIDIA GeForce RTX 4090" \
	"$(got D3DM_VENDOR_ID) $(got D3DM_DEVICE_ID) $(got D3DM_DEVICE_DESCRIPTION)"
user_conf 'NVAPI=1' 'D3DM_DEVICE_ID=0x2704'
launch waitforexitandrun "$case_dir/game/game.exe"
is "a conf's D3DM_DEVICE_ID wins over the default" "0x10de 0x2704" "$(got D3DM_VENDOR_ID) $(got D3DM_DEVICE_ID)"
is "NVAPI=1 lets Streamline load Apple's NGX bridge" "1" "$(got NOTPROTON_NGX_SIGNER)"
is "and wined3d reports a current NVIDIA driver" "32.0.15.9541" "$(got NOTPROTON_DRIVER_VERSION)"
is "and leaves hardware scheduling alone" "<unset>" "$(got CX_ACTIVE_GRAPHICS_BACKEND)"
user_conf 'NVAPI=1' 'DLSS_FG=1'
launch waitforexitandrun "$case_dir/game/game.exe"
is "DLSS_FG=1 reports hardware scheduling for DLSS frame generation" "d3dmetal" "$(got CX_ACTIVE_GRAPHICS_BACKEND)"
user_conf 'VSYNC=1'
launch waitforexitandrun "$case_dir/game/game.exe"
is "VSYNC=1 asks the overlay shim to keep the layer on display sync" "1" "$(got NOTPROTON_VSYNC)"
user_conf 'HIDE_WINE_EXPORTS=1'
launch waitforexitandrun "$case_dir/game/game.exe"
is "HIDE_WINE_EXPORTS=1 hides ntdll's wine_* exports from GetProcAddress" "1" "$(got NOTPROTON_HIDE_WINE_EXPORTS)"
user_conf 'NVAPI=1' 'BACKEND=dxmt'
launch waitforexitandrun "$case_dir/game/game.exe"
is "but not for dxmt" "d3d10core,d3d11,dxgi=n,b;d3d10,d3d12=b;nvapi64,nvngx=d;$trio" "$(got WINEDLLOVERRIDES)"
is "nor its adapter" "<unset>" "$(got D3DM_VENDOR_ID)"
has "and says so" "NVAPI=1 not applied, dxmt is not d3dmetal" "$case_dir/log"
user_conf 'NVAPI=yes'
launch waitforexitandrun "$case_dir/game/game.exe"
has "NVAPI must be 0 or 1" "rejected NVAPI: not 0 or 1" "$case_dir/log"
new_case
engine d3dmetal-linked nvapi-shim/x86_64-windows/nvapi64.dll
user_conf 'NVAPI=1'
launch waitforexitandrun "$case_dir/game/game.exe"
is "with the nvapi shim, nvapi64 is native in front of Apple's" "d3d10,d3d10core,d3d11,d3d12,dxgi=b;nvapi64=n,b;nvngx=b;$trio" "$(got WINEDLLOVERRIDES)"
is "and the shim is staged into system32" "backend nvapi-shim/x86_64-windows/nvapi64.dll" "$(sys system32 nvapi64)"
is "beside Apple's nvapi as the nvapi.dll placeholder it loads" "apple nvapi64" "$(sys system32 nvapi)"
user_conf 'NVAPI=0'
launch waitforexitandrun "$case_dir/game/game.exe"
is "NVAPI=0 disables it again" "d3d10,d3d10core,d3d11,d3d12,dxgi=b;nvapi64,nvngx=d;$trio" "$(got WINEDLLOVERRIDES)"
new_case
engine d3dmetal-linked empty
launch waitforexitandrun "$case_dir/game/game.exe" NOTPROTON_BACKEND=dxmt
is "a missing dxmt falls back to d3dmetal, not wined3d" "d3dmetal" "$(got backend)"
new_case
full_engine
engine d3dmetal-linked
chmod 500 "$case_dir/data/pfx/drive_c/windows/system32"
launch waitforexitandrun "$case_dir/game/game.exe" NOTPROTON_BACKEND=dxmt
chmod 700 "$case_dir/data/pfx/drive_c/windows/system32"
is "a backend that cannot be staged falls back to d3dmetal" "d3dmetal" "$(got backend)"
has "with the reason" "dxmt could not be staged, falling back to d3dmetal" "$case_dir/log"

echo "== legacy layout"
new_case
user_conf 'BACKEND=dxvk' 'DLLOVERRIDES=dinput8=n,b'
cp "$case_dir/engine/lib/wine/x86_64-windows/dxgi.dll" "$case_dir/data/pfx/drive_c/windows/system32/dxgi.dll"
launch waitforexitandrun "$case_dir/game/game.exe"
is "the backend is the baked-in one" "dxmt-builtin" "$(got backend)"
is "only the conf and the trio reach the overrides" "dinput8=n,b;$trio" "$(got WINEDLLOVERRIDES)"
is "nothing is copied" "stock x86_64-windows dxgi" "$(sys system32 dxgi)"
has "the ignored request is logged" "requested backend dxvk ignored" "$case_dir/log"
is "the state file records it" "dxmt-builtin" "$(sed -n 1p "$case_dir/data/notproton-backend")"

echo "== activation and switching"
new_case
full_engine
launch waitforexitandrun "$case_dir/game/game.exe"
is "dxmt sets what it ships native" "d3d10core,d3d11,dxgi=n,b;$trio" "$(got WINEDLLOVERRIDES)"
is "dxmt dxgi is in system32" "backend dxmt/x86_64-windows/dxgi.dll" "$(sys system32 dxgi)"
is "winemetal stays with Wine" "missing" "$(sys system32 winemetal)"
is "dxmt has no i386, syswow64 is untouched" "missing" "$(sys syswow64 dxgi)"
is "the state file records dxmt" "dxmt" "$(sed -n 1p "$case_dir/data/notproton-backend")"
: > "$case_dir/log"
launch waitforexitandrun "$case_dir/game/game.exe"
lacks "a second launch copies nothing" "staged" "$case_dir/log"
launch waitforexitandrun "$case_dir/game/game.exe" NOTPROTON_BACKEND=dxvk
is "dxvk sets only d3d11 and d3d10core native, dxgi stays Wine's" \
	"d3d10core,d3d11=n,b;dxgi=b;$trio" "$(got WINEDLLOVERRIDES)"
is "the stale dxmt dxgi goes back to Wine's" "stock x86_64-windows dxgi" "$(sys system32 dxgi)"
is "dxvk d3d11 replaces dxmt's" "backend dxvk/x86_64-windows/d3d11.dll" "$(sys system32 d3d11)"
is "dxvk i386 lands in syswow64" "backend dxvk/i386-windows/d3d11.dll" "$(sys syswow64 d3d11)"
has "the switch is logged" "backend switched from dxmt to dxvk" "$case_dir/log"
launch waitforexitandrun "$case_dir/game/game.exe"
is "back on dxmt, the stale i386 dxvk d3d11 goes back to Wine's" "stock i386-windows d3d11" "$(sys syswow64 d3d11)"
launch waitforexitandrun "$case_dir/game/game.exe" NOTPROTON_BACKEND=wined3d
is "wined3d keeps every backend DLL builtin" "d3d10core,d3d11,dxgi=b;$trio" "$(got WINEDLLOVERRIDES)"
is "and puts Wine's dxgi back" "stock x86_64-windows dxgi" "$(sys system32 dxgi)"
is "and Wine's d3d11" "stock x86_64-windows d3d11" "$(sys system32 d3d11)"
printf 'user reshade\n' > "$case_dir/data/pfx/drive_c/windows/system32/dxgi.dll"
launch waitforexitandrun "$case_dir/game/game.exe" NOTPROTON_BACKEND=wined3d
is "a DLL the user put there is left alone" "user reshade" "$(sys system32 dxgi)"
new_case
full_engine
chmod 500 "$case_dir/data/pfx/drive_c/windows/system32"
launch waitforexitandrun "$case_dir/game/game.exe"
chmod 700 "$case_dir/data/pfx/drive_c/windows/system32"
is "a backend that cannot be staged falls back to wined3d" "wined3d" "$(got backend)"
has "with the reason" "dxmt could not be staged, falling back to wined3d" "$case_dir/log"

echo "== msync"
new_case
full_engine
launch waitforexitandrun "$case_dir/game/game.exe"
is "the free engine keeps msync off" "0 default" "$(got WINEMSYNC) $(got msync_from)"
new_case
full_engine
engine msync
launch waitforexitandrun "$case_dir/game/game.exe"
is "an engine with msync turns it on" "1 engine" "$(got WINEMSYNC) $(got msync_from)"
printf 0 > "$case_dir/data/notproton-msync"
launch waitforexitandrun "$case_dir/game/game.exe"
is "over an older carried-over 0" "1 engine" "$(got WINEMSYNC) $(got msync_from)"
user_conf 'MSYNC=0'
launch waitforexitandrun "$case_dir/game/game.exe"
is "a conf MSYNC=0 turns it off" "0 gamefix" "$(got WINEMSYNC) $(got msync_from)"
launch waitforexitandrun "$case_dir/game/game.exe" WINEMSYNC=1
is "launch options beat the conf" "1 environment" "$(got WINEMSYNC) $(got msync_from)"
new_case
full_engine
user_conf 'MSYNC=1'
printf 1 > "$case_dir/data/notproton-msync"
launch waitforexitandrun "$case_dir/game/game.exe"
is "without the marker a conf MSYNC=1 keeps the carried-over value" "1 carried-over" "$(got WINEMSYNC) $(got msync_from)"
has "and says why" "MSYNC=1 not applied, the engine has no .notproton-msync" "$case_dir/log"

echo "== ARGS"
new_case
full_engine
default_conf 'ARGS=-dx12'
user_conf 'ARGS=-dx11  -windowed +exec=autoexec.cfg'
launch waitforexitandrun "$case_dir/game/game.exe"
is "the user conf ARGS wins" "-dx11  -windowed +exec=autoexec.cfg" "$(got gamefix_args)"
launch run "$case_dir/game/iscriptevaluator.exe"
is "helpers get no ARGS" "" "$(got gamefix_args)"
has "and the log says so" "ARGS not applied, run is not the game launch" "$case_dir/log"
for bad_args in '-dx11 ;reboot' '-a *' '-a $HOME' '-a|b' '-a&' '-a>b' '-a\b' '-a?'; do
	new_case
	full_engine
	user_conf "ARGS=$bad_args"
	launch waitforexitandrun "$case_dir/game/game.exe"
	is "ARGS=$bad_args is rejected" "" "$(got gamefix_args)"
	has "and logged" "rejected ARGS: an argument with characters outside" "$case_dir/log"
done
out=$(gamefix_args='-dx11  -windowed +exec=autoexec.cfg' log=/dev/null append_args="$append_args" \
	sh -ec 'eval "$append_args"; printf "[%s]" "$@"' sh /g/game.exe -novid 'two words')
is "ARGS come after the launch options' own arguments, split on spaces" \
	"[/g/game.exe][-novid][two words][-dx11][-windowed][+exec=autoexec.cfg]" "$out"
out=$(gamefix_args='' log=/dev/null append_args="$append_args" \
	sh -ec 'eval "$append_args"; printf "[%s]" "$@"' sh /g/game.exe -novid)
is "no ARGS leaves the command line alone" "[/g/game.exe][-novid]" "$out"

echo "== RETINA"
new_case
full_engine
user_conf 'RETINA=1'
launch waitforexitandrun "$case_dir/game/game.exe"
is "RETINA maps to NOTPROTON_RETINA" "1" "$(got NOTPROTON_RETINA)"
launch waitforexitandrun "$case_dir/game/game.exe" BRIDGEPLAY_RETINA=0
is "the High Resolution launch option wins" "0" "$(got NOTPROTON_RETINA)"
launch waitforexitandrun "$case_dir/game/game.exe" NOTPROTON_RETINA=0
is "the pre-3.0 spelling still wins over the conf" "0" "$(got NOTPROTON_RETINA)"
launch waitforexitandrun "$case_dir/game/game.exe" NOTPROTON_RETINA=0 BRIDGEPLAY_RETINA=1
is "NOTPROTON_ wins when both spellings are set" "0" "$(got NOTPROTON_RETINA)"
new_case
full_engine
user_conf 'BRIDGEPLAY_RETINA=1' 'BRIDGEPLAY_FRAMEGEN=2' 'BRIDGEPLAY_BACKEND=dxvk'
launch waitforexitandrun "$case_dir/game/game.exe"
is "a conf key takes the BRIDGEPLAY_ name" "1" "$(got NOTPROTON_RETINA)"
is "and so does FRAMEGEN" "2" "$(got NOTPROTON_FRAMEGEN)"
has "BACKEND does not, it names no variable" "rejected BRIDGEPLAY_BACKEND: not on the allow-list" "$case_dir/log"

echo "== FRAMEGEN"
new_case
full_engine
user_conf 'FRAMEGEN=1'
launch waitforexitandrun "$case_dir/game/game.exe"
is "FRAMEGEN maps to NOTPROTON_FRAMEGEN" "1" "$(got NOTPROTON_FRAMEGEN)"
launch waitforexitandrun "$case_dir/game/game.exe" NOTPROTON_FRAMEGEN=0
is "the frame generation launch option wins" "0" "$(got NOTPROTON_FRAMEGEN)"
for mode in 0 2 3 adaptive; do
	new_case
	full_engine
	user_conf "FRAMEGEN=$mode"
	launch waitforexitandrun "$case_dir/game/game.exe"
	is "FRAMEGEN=$mode is accepted" "$mode" "$(got NOTPROTON_FRAMEGEN)"
done
new_case
full_engine
default_conf 'FRAMEGEN_QUALITY=performance' 'FRAMEGEN_UI=1' 'FRAMEGEN_FALLBACK=1' 'FRAMEGEN_ENGINE=own'
user_conf 'FRAMEGEN=2' 'FRAMEGEN_QUALITY=quality' 'FRAMEGEN_UI=0' 'FRAMEGEN_FALLBACK=0' 'FRAMEGEN_ENGINE=metalfx'
launch waitforexitandrun "$case_dir/game/game.exe"
is "FRAMEGEN_QUALITY maps to NOTPROTON_FRAMEGEN_QUALITY, user over default" "quality" "$(got NOTPROTON_FRAMEGEN_QUALITY)"
is "FRAMEGEN_UI maps to NOTPROTON_FRAMEGEN_UI" "0" "$(got NOTPROTON_FRAMEGEN_UI)"
is "FRAMEGEN_FALLBACK maps to NOTPROTON_FRAMEGEN_FALLBACK" "0" "$(got NOTPROTON_FRAMEGEN_FALLBACK)"
is "FRAMEGEN_ENGINE maps to NOTPROTON_FRAMEGEN_ENGINE" "metalfx" "$(got NOTPROTON_FRAMEGEN_ENGINE)"
launch waitforexitandrun "$case_dir/game/game.exe" NOTPROTON_FRAMEGEN_QUALITY=balanced NOTPROTON_FRAMEGEN_UI=1 \
	NOTPROTON_FRAMEGEN_FALLBACK=1 NOTPROTON_FRAMEGEN_ENGINE=own
is "the quality launch option wins" "balanced" "$(got NOTPROTON_FRAMEGEN_QUALITY)"
is "the Protect UI launch option wins" "1" "$(got NOTPROTON_FRAMEGEN_UI)"
is "the fallback launch option wins" "1" "$(got NOTPROTON_FRAMEGEN_FALLBACK)"
is "the engine launch option wins" "own" "$(got NOTPROTON_FRAMEGEN_ENGINE)"
new_case
full_engine
launch waitforexitandrun "$case_dir/game/game.exe"
is "no conf leaves the quality to the shim" "<unset>" "$(got NOTPROTON_FRAMEGEN_QUALITY)"

# The stub reports NOTPROTON_OVERLAY_SHIM, set beside DYLD_INSERT_LIBRARIES, since SIP strips DYLD_* from /bin/sh.
# Without SIP (GitHub runners) dyld does load the shim into /bin/sh, so it is a real, empty arm64e dylib.
echo "== the launcher loads the shim for frame generation unless it is off"
mkdir -p "$work/launcher/Contents/MacOS" "$work/launcher/home/Library/Application Support/bridgeplay"
clang -dynamiclib -arch arm64e -arch arm64 -arch x86_64 -x c /dev/null \
	-o "$work/launcher/home/Library/Application Support/bridgeplay/overlay-shim.dylib"
printf '#!/bin/sh\nprintf "%%s" "${NOTPROTON_OVERLAY_SHIM:-none}"\n' > "$work/launcher/wine"
chmod +x "$work/launcher/wine"
env -i PATH="$PATH" HOME="$work/launcher/home" WINELOADER="$work/launcher/wine" loader_root="$work/launcher" \
	np_support="$work/launcher/home/Library/Application Support/bridgeplay" \
	loader_macos="$work/launcher/Contents/MacOS" body="$launcher_body" sh -ec 'eval "$body"'
chmod +x "$work/launcher/Contents/MacOS/launcher"
for spec in '-:none' '0:none' 'off:none' '1:shim' '2:shim' '3:shim' 'adaptive:shim'; do
	fg=${spec%%:*} want=${spec#*:}
	if [ "$fg" = - ]; then
		env -i PATH="$PATH" "$work/launcher/Contents/MacOS/launcher" >/dev/null 2>&1 || true
	else
		env -i PATH="$PATH" NOTPROTON_FRAMEGEN="$fg" "$work/launcher/Contents/MacOS/launcher" >/dev/null 2>&1 || true
	fi
	got_dyld=$(cat "$work/launcher/bridgeplay-wine.log")
	case "$got_dyld" in *overlay-shim.dylib) got_dyld=shim ;; esac
	is "NOTPROTON_FRAMEGEN=${fg#-} without the Steam overlay: $want" "$want" "$got_dyld"
done

echo "== the launcher receives the allow-listed variables"
set --
out=$(env -i PATH="$PATH" forward="$forward" VKD3D_CONFIG=dxr MVK_CONFIG_LOG_LEVEL=1 \
	STAGING_SHARED_MEMORY=1 WINE_CPU_TOPOLOGY=4:0,1,2,3 WINE_LARGE_ADDRESS_AWARE=1 CX_FWD_COMPAT_GL_CTX=1 \
	DXVK_HUD=fps NOTPROTON_FRAMEGEN=1 NOTPROTON_FRAMEGEN_QUALITY=quality NOTPROTON_FRAMEGEN_UI=0 \
	NOTPROTON_FRAMEGEN_FALLBACK=0 NOTPROTON_FRAMEGEN_ENGINE=metalfx NOTPROTON_FRAMEGENX=1 NOTPROTON_UNRELATED=1 sh -c 'set --; eval "$forward"; printf "%s\n" "$@"' | grep -v '^--env$' | LC_ALL=C sort | tr '\n' ' ')
is "VKD3D_, MVK_, STAGING_, WINE_ topology and CX_FWD_COMPAT_GL_CTX variables are forwarded" \
	"CX_FWD_COMPAT_GL_CTX=1 DXVK_HUD=fps MVK_CONFIG_LOG_LEVEL=1 NOTPROTON_FRAMEGEN=1 NOTPROTON_FRAMEGEN_ENGINE=metalfx NOTPROTON_FRAMEGEN_FALLBACK=0 NOTPROTON_FRAMEGEN_QUALITY=quality NOTPROTON_FRAMEGEN_UI=0 STAGING_SHARED_MEMORY=1 VKD3D_CONFIG=dxr WINE_CPU_TOPOLOGY=4:0,1,2,3 WINE_LARGE_ADDRESS_AWARE=1 " "$out"

echo "== the wineserver directory self-heal"
heal=$(sed -n '/^heal_wine_tmp() {$/,/^}$/p' "$SRC")
[ -n "$heal" ] || { echo "FAIL: heal_wine_tmp not found in $SRC"; exit 1; }
first_wine=$(grep -nE '"\$WINE(LOADER|SERVER)" (-[kw]|wineboot|reg|"\$)' "$SRC" | head -1 | cut -d: -f1)
called=$(grep -n '^heal_wine_tmp /tmp$' "$SRC" | head -1 | cut -d: -f1)
is "it runs on /tmp before the first wine or wineserver call" "yes" \
	"$([ -n "$called" ] && [ -n "$first_wine" ] && [ "$called" -lt "$first_wine" ] && echo yes || echo no)"
fake_tmp="$work/tmproot"
mkdir -p "$fake_tmp"
wine_dir="$fake_tmp/.wine-$(id -u)"
heal_log="$work/heal.log"
run_heal() { : > "$heal_log"; log="$heal_log" heal="$heal" sh -ec 'eval "$heal"; heal_wine_tmp "$1"' heal "$fake_tmp"; }
run_heal
is "no directory, nothing logged" "" "$(cat "$heal_log")"
mkdir "$wine_dir"
chmod 755 "$wine_dir"
run_heal
is "a 755 directory of ours goes back to 700" "700" "$(stat -f %Lp "$wine_dir")"
has "and is logged" "was mode 755, set to 700" "$heal_log"
run_heal
is "a 700 directory is left as it is, silently" "" "$(cat "$heal_log")"
rmdir "$wine_dir"
mkdir "$work/elsewhere"
chmod 755 "$work/elsewhere"
ln -s "$work/elsewhere" "$wine_dir"
run_heal
is "a symlink is never followed" "755" "$(stat -f %Lp "$work/elsewhere")"
is "nor replaced" "yes" "$([ -L "$wine_dir" ] && echo yes || echo no)"
has "and is warned about" "is a symlink, left alone" "$heal_log"
rm "$wine_dir"
printf x > "$wine_dir"
chmod 644 "$wine_dir"
run_heal
is "a file is left alone" "644" "$(stat -f %Lp "$wine_dir")"
has "and is warned about" "is not a directory (Regular File), left alone" "$heal_log"
rm "$wine_dir"

echo "== layers: shipped and user defaults for every game"
new_case
full_engine
global_conf() { printf '%s\n' "$@" > "$case_dir/support/gamefixes-default/default.conf"; }
user_global_conf() { printf '%s\n' "$@" > "$case_dir/support/gamefixes/default.conf"; }
global_conf 'BACKEND=dxvk' 'RETINA=1' 'WINEDEBUG=-all' 'FRAMEGEN=2'
user_global_conf 'RETINA=0' 'FRAMEGEN=adaptive'
default_conf 'FRAMEGEN=3'
launch waitforexitandrun "$case_dir/game/game.exe"
is "the shipped global conf applies" "dxvk" "$(got backend)"
is "the shipped global conf exports" "-all" "$(got WINEDEBUG)"
is "the user's global conf wins over the shipped one" "0" "$(got NOTPROTON_RETINA)"
is "a shipped per-game conf wins over both global confs" "3" "$(got NOTPROTON_FRAMEGEN)"
has "the shipped global conf is read first" "reading the shipped-global conf" "$case_dir/log"
has "the log names the shipped global layer" "BACKEND in the shipped-global conf" "$case_dir/log"
has "the log names the user's global layer" "applied NOTPROTON_RETINA=0 from the global conf" "$case_dir/log"

new_case
full_engine
global_conf 'BACKEND=dxvk' 'RETINA=1'
user_global_conf 'MTL_HUD_ENABLED=1'
user_conf 'BACKEND=dxmt'
launch waitforexitandrun "$case_dir/game/game.exe" BRIDGEPLAY_RETINA=0 MTL_HUD_ENABLED=0
is "a user per-game conf wins over the global confs" "dxmt" "$(got backend)"
is "launch options win over the shipped global conf" "0" "$(got NOTPROTON_RETINA)"
is "launch options win over the user's global conf" "0" "$(got MTL_HUD_ENABLED)"

new_case
full_engine
user_global_conf 'BACKEND=d3dmetal'
launch waitforexitandrun "$case_dir/game/game.exe"
is "a global d3dmetal on an engine without it falls back" "dxmt" "$(got backend)"
has "the fallback names the global layer" "BACKEND in the global conf, fell back from d3dmetal" "$case_dir/log"

if [ "$fails" -eq 0 ]; then
	echo "==> gamefixescheck: all assertions hold"
else
	echo "==> gamefixescheck: $fails failed"
	exit 1
fi
