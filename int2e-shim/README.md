# int2e-shim

`version.dll` proxy for x86_64 games whose anti-tamper / protector (such as VMProtect in
Car Parking Multiplayer 2's `UnityPlayer.dll`, `gamefixes/4252340.conf`) executes direct Windows
`int 0x2e` (`cd 2e`) syscalls instead of calling `ntdll` exports.

The app installs it as `lib/notproton-backends/int2e-shim/x86_64-windows/version.dll` (WineCX
11.17). When a game's conf sets `INT2E_SHIM=1` (or the launch options set `BRIDGEPLAY_INT2E_SHIM=1`), `compat_run.sh` stages it
into `$WINEPREFIX/drive_c/windows/system32/version.dll` and adds `version=n,b` to
`WINEDLLOVERRIDES`. The DLL pins itself in memory, so the vectored handler never outlives it. When `INT2E_SHIM` is off and `system32/version.dll` still carries the
`int2e-shim: ` marker, Wine's stock `version.dll` is restored. A user-provided native
`version.dll` in `system32` is left untouched, and `ROCKSTAR_SHIM=1` skips `int2e-shim` so
neither overrides the other's `version=n,b`.

## Why it is needed

On macOS / Rosetta, executing `int 0x2e` (`cd 2e`) in user space raises
`EXCEPTION_ACCESS_VIOLATION` (`ExceptionInformation = {0, ~0}`), killing the process with
`0xc0000142` (`STATUS_DLL_INIT_FAILED`) before any window is created.

On `DLL_PROCESS_ATTACH`, `int2e-shim` registers a first-chance vectored exception handler
(`veh_int2e`) that recognizes `cd 2e` faults and redirects `Rip` to a per-callsite 32-byte stub:

1. Stub invokes `call qword ptr [0x7ffe1000]` (`__wine_syscall_dispatcher`).
2. Wine's dispatcher rewinds its return address and enters `+0x00`, which jumps past the call
   to `+0x0b` (`jmp qword ptr [orig_rip + 2]`) with the original stack intact.

Exports forward to `kernelbase`/`kernel32` (matching `rockstar-shim/version.def`).

## Build

    int2e-shim/build.sh    # needs x86_64-w64-mingw32-gcc (brew install mingw-w64)

The build is reproducible (no CRT, no timestamp, no build id). Copy `version.dll` to
`app/Sources/BridgeplayApp/Resources/version-int2e-shim.dll` and update its sha256 pin in
`FreeEngineWinecx.swift` and `docs/WINECX.md`.
