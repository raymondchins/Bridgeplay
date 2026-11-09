# ntdll-patch/

Small detours patched into each engine's `ntdll.dll` so that a game's calls into Steam's
`steamclient` load Proton's lsteamclient instead. Each engine build has its own payloads
(`detour2*.bin` x86_64, `detour32*.bin` i386, `detour64-fex*.bin` arm64), committed in
`app/Sources/BridgeplayApp/Resources/` and applied by `Model/NtdllPatcher.swift`.

- **Per-build constants** come from the target `ntdll.dll`: `resolve.py` reads them (it needs
  `capstone`) and self-tests against its `PINNED` table, keyed by the ntdll's sha256.
  `build.sh`, `build32.sh` and `build64.sh` build the payloads; `apply.py`
  gives the patched hash. The full recipe is in
  [docs/WINECX.md](../docs/WINECX.md#regenerating-the-pins).
- **Pins:** each payload's sha256 goes in `NtdllPatcher.byBuild` or the release's
  `ntdllPatches` in `FreeEngineWinecx.swift`, and in the Shipped binaries table of
  `docs/WINECX.md`, together with the clean and patched ntdll hashes.
- **Checks:** `make detourcheck` runs `shimcheck.py` (every shipped x86 payload,
  `detour2*.bin` and `detour32*.bin`, hands the detour the register its ntdll keeps the MODREF
  in; the arm64 `detour64-fex*.bin` are not checked) and the unit tests in `tests/`. A payload that
  was never rebuilt after a shim change still matches its own pin, which is why the check
  exists. `wmguard.py` lists the registers each shim overwrites first.
- **Smoke test:** a new or bumped engine needs a 32-bit game launched from Steam on it,
  checked to reach Steam. `detourcheck` only proves each detour reads the register its pin
  names.
- `detour2-winehq-11.15.bin` does not rebuild byte for byte from the current `detour.c`; it
  stays until a WineHQ x86_64 game is tested with a rebuilt payload (docs/WINECX.md).
