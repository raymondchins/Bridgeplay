# rockstar-shim

`version.dll` for the Rockstar Games Launcher and GTA V Legacy, staged by the run script when a
game's conf says `ROCKSTAR_SHIM=1` (`gamefixes/271590.conf`). It goes next to
`SocialClubHelper.exe` (`C:\Program Files\Rockstar Games\Social Club`) and next to the game's
exe, never into `system32`, and the run script adds `version=n,b`. Every export forwards to
kernelbase/kernel32. `DllMain` acts in two processes and nowhere else.

## SocialClubHelper.exe: blank launcher windows

The launcher's windows (sign-in, main window, error pages) are CEF child windows owned by the
CEF browser process, while Chromium's GPU/viz process paints them. A `WINEDEBUG=+win` trace
showed the other process calling `NtUserGetDCEx` on the browser's `Chrome_WidgetWin_1` hundreds
of times; on winemac a process cannot draw into another process's window, so the windows stay
blank (macOS reports them on screen, alpha 1). The shim appends
`--in-process-gpu --disable-gpu --disable-gpu-compositing --disable-software-rasterizer` to the
browser process's command line (not to `--type=` subprocesses), so it composites in software
into its own window. `--in-process-gpu` alone crashed the browser when ANGLE failed in process
("Main browser connection lost", launcher code 161). Without `--disable-software-rasterizer`
(the switch Social Club's own `-scNoSoftwareRasterizer` adds) the in-process GPU thread still
starts SwiftShader, and about one launch in seven never created the browser window ("Timed
out waiting for browser window"); with it, 6 of 6 did, in about 5 s.

Wine's kernelbase keeps its own copy of the command line: `GetCommandLineW` is
`mov rax, [rip+disp32]; ret` reading `command_lineW`. The shim points that variable at the new
string as well, and leaves it alone if the instruction pattern differs.

The launcher starts CEF with the game folder as working directory. `SetDllDirectoryW(L"")`
keeps a d3d11 or dxgi in that folder out of CEF's DLL search; without it CEF loaded one and
timed out ("timed out loading both its online and offline content").

## GTA5.exe: DXVK's dxgi

On WineCX with D3DMetal enabled, the dxvk backend's `dxgi=b` gave GTA5.exe CrossOver's D3DMetal
dxgi (a 16 MB `PE-Wine` module in `winedbg`'s `info share`, beside DXVK's d3d11 and the
`d3dmetal` Mach-O). The DXVK repack ships no dxgi. GTA V creates its own DXGI factory and gives its
adapter to DXVK's d3d11, which then calls `DXGIFactory::CreateSwapChain` in D3DMetal; that fails
(`E_FAIL`) and the game deadlocks in its exception handler holding a critical section
(`winedbg` backtrace). A global `dxgi=n,b` with DXVK's dxgi broke the launcher's CEF.

The run script exports `NOTPROTON_ROCKSTAR_DXGI`, the Windows path of DXVK's dxgi shipped as
`rockstar-shim/x86_64-windows/dxgx.dll` (another name, so `dxgi=b` does not apply). In GTA5.exe
the shim loads it and registers it as `dxgi.dll`: it renames `BaseDllName` and moves the entry's
`HashLinks` to the bucket of the new name. The bucket array is private to ntdll; the shim finds
it from the other modules' bucket heads and uses the hash variant (Windows 8+, 7, first letter)
whose buckets line up for every loaded module, or changes nothing. Later
`LoadLibrary`/`GetModuleHandle("dxgi.dll")` then return DXVK's dxgi, and DXVK's d3d11 binds to it.

## Build

    rockstar-shim/build.sh    # needs x86_64-w64-mingw32-gcc (brew install mingw-w64)

The build is reproducible (no timestamp, no build id). Copy `version.dll` to
`app/Sources/BridgeplayApp/Resources/version-rockstar-shim.dll` and update its sha256 in
`FreeEngineWinecx.swift`. `dxgx.dll` is `x64/dxgi.dll` from
`dxvk-macOS-async-v1.10.3-20230507.tar.gz`
(https://github.com/Gcenx/DXVK-macOS/releases/tag/v1.10.3-20230507), the release whose d3d11.dll
is byte-identical to the repack's the engine already uses; it ships as
`app/Sources/BridgeplayApp/Resources/dxgi-dxvk-macos-1.10.3.dll`.
