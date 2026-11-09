# NGX signer patch (WineCX 11.17)

NVIDIA Streamline loads an NGX core only when it carries an NVIDIA Authenticode signature
(`sl_security.h`: `CryptQueryObject` + `WinVerifyTrust` by path). Apple's MetalFX DLSS bridge,
`nvngx-on-metalfx`, linked as `system32\nvngx.dll`, is unsigned, so Streamline games
(Resident Evil Requiem, 007 First Light) logged `failed to load NGXCore: -2146885623` and
never offered DLSS. Games calling NGX directly (Death Stranding) were unaffected.

`winecx-ngx-signer.patch` (against winecx `e0aa380`) wraps `CryptQueryObject` (crypt32) and
`WinVerifyTrust` (wintrust): with `NOTPROTON_NGX_SIGNER` set, a check of `nvngx.dll` or
`_nvngx.dll` by path in the system directory (`GetSystemDirectoryW()`, not any folder named
`system32`) is answered from an NVIDIA-signed Streamline module next to the game executable
(`sl.interposer.dll`, `sl.common.dll` or `nvngx_dlss.dll`). Every other path is untouched.
`compat_run.sh` sets the variable only with `NVAPI=1` on D3DMetal. `WinVerifyTrust` runs a
redirected check on a heap copy of the caller's `WINTRUST_DATA` and `WINTRUST_FILE_INFO`, so
the caller's structs are only written where Windows writes them too (`hWVTStateData`); a
`WTD_STATEACTION_VERIFY` copy stays alive until its `WTD_STATEACTION_CLOSE`.

The committed `crypt32-winecx-11.17.dll` and `wintrust-winecx-11.17.dll` were rebuilt with
those two changes (system-directory match, struct copy) on 2026-10-24 and repinned. Built
from the earlier patch, the recipe below reproduced the previous binaries except the PE
timestamp, checksum, build id and the source path in assert strings. The rebuilt pair has not
been checked in a Streamline game yet.

Verified 2026-10-12: RE Requiem lists NVIDIA DLSS; 007 First Light logs
`Loaded NGXCore from path (C:\windows\system32\nvngx.dll)`.

Build in a tree configured as in `winemac-patch/README.md` (with
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` so the x86_64 clang runs):
`make dlls/crypt32/x86_64-windows/crypt32.dll dlls/wintrust/x86_64-windows/wintrust.dll`, then
`x86_64-w64-mingw32-strip --strip-debug`. Pins: `FreeEngineWinecx.v1117.nvidia` and `docs/WINECX.md`.
