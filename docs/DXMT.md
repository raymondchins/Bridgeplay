# DXMT build

Bridgeplay ships DXMT built from a pinned master commit, not the v0.80 release, to pick up
the 262 commits since that release (D3D11 fixes, the macOS 27 HUD fix, Xcode 27 build
fixes, the WIP D3D12 backend).

| | |
| - | - |
| Commit | `e94c312f5c054263acf261cfa109edf13e757587` (`v0.80-262-ge94c312`, 2026-10-06) |
| Why | head of `main` when pinned; every job of its CI run is green ([run 37474938195](https://github.com/3Shain/dxmt/actions/runs/37474938195)) |
| Tarball | `dxmt-e94c312.tar.gz`, top-level directory `e94c312/` |
| License | LGPL-2.1-or-later since `ec357fd` (v0.80 was the last MIT release) |
| Source | the upstream commit above, public at https://github.com/3Shain/dxmt/tree/e94c312f5c054263acf261cfa109edf13e757587. The currently published `dxmt-e94c312.tar.gz` predates `dxmt-<shortsha>-source.tar.gz` (below) and carries no license files or source of its own; the next rebuild publishes both on the same release, see Rebuilding |

## In Bridgeplay

Both free engines download this tarball from
`https://github.com/raymondchins/Bridgeplay/releases/download/dxmt-e94c312/` into the
engine cache (`FreeEngine.dxmt`, also `FreeEngineWinecx.current.renderer`). `winemetal.so`
and both `winemetal.dll` go into `lib/wine` as shipped. `d3d10core`, `d3d11` and `dxgi` go to
`lib/notproton-backends/dxmt/` with the 16 bytes of the Wine builtin marker at 0x40
overwritten with a DOS stub (the bytes winecx-gptk uses), because the launcher copies them
into a prefix as natives and Wine swaps a marked DLL found there for the `lib/wine` builtin
of the same name (`load_builtin` in `dlls/ntdll/unix/loader.c`). They are pinned both as
shipped (table below) and as installed:

| Installed file | sha256 |
| - | - |
| `x86_64-windows/d3d10core.dll` | `aeb43e1ca7d9f221b9f0070c8654fa3579fd767006272cf675a9113e27bc6e72` |
| `x86_64-windows/d3d11.dll` | `c1c8c4779686990bf343162a8804dd2d1564b2a893e64e5ddcc7db5e76ce409e` |
| `x86_64-windows/dxgi.dll` | `1bb4939ff43e676eac8b3f3cb0583985ab8f7b1a8e11760d14931da3fc44223b` |
| `i386-windows/d3d10core.dll` | `e851c39641f66d64a3e4460e7046900cd234b11f44d793826d2f094e9d2166d9` |
| `i386-windows/d3d11.dll` | `a654ea3851ccc128a1f33d978462872e22fa6430ea85eff6ba9549de95788652` |
| `i386-windows/dxgi.dll` | `91f38df103412235793f84efe06b87f6f6fc3a4791d4f8d9f8cc2e16bc137d53` |

The same stripping applied to v0.80 reproduces the hashes of the frontends in the WineCX
archive exactly. `nvapi64`, `nvngx` and `d3d12.dll` are not installed.
`FreeEngineTests.downloadsAndUnpacksRealDxmt` downloads the real tarball and checks all of
this.

## Rebuilding

    DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
        scripts/build-dxmt.sh e94c312f5c054263acf261cfa109edf13e757587

Add `--publish` to also create the `dxmt-<shortsha>` GitHub release once the build and its
checks pass. Needs Xcode with its Metal toolchain (`xcodebuild -downloadComponent
MetalToolchain`), Homebrew `cmake bison flex mingw-w64`, and python3; the script installs
meson 1.10.0 and ninja into a venv. Work goes to `scratch/dxmt-build/`, output to
`scratch/dxmt-out/`: the binary tarball with `COPYING.LIB`, `LICENSE` and
`LICENSE-0.80-and-earlier.txt` inside it, `dxmt-<shortsha>-source.tar.gz` (the Corresponding
Source: the exact worktree the build ran from, submodules included), and a `.sha256`
manifest covering both. Finished stages are reused. A cold run on an M5 Max
takes about 6 minutes plus clones: LLVM about 3, Wine configure about 1, DXMT about 1.

It follows the gcc-release jobs of DXMT's `ci.yml` (LLVM 15.0.7 for x86_64-apple-darwin,
Homebrew mingw-w64, meson 1.10.0), with these differences:

- **Wine.** CI links against 3Shain's prebuilt Wine 8.16. Here `winebuild` and the PE
  import libraries (`libwinecrt0.a`, `libntdll.a`, `libdbghelp.a`) come from wine-11.15
  (`2df1ee28`, the same pin as `bridge/setup-wine-tree.sh`). `winemac.so` and `ntdll.so`
  come from the pinned Gcenx 11.15 archive, with their install names set to
  `@rpath/<name>` so `winemetal.so` records the same load commands as the release.
- **Deployment target.** `MACOSX_DEPLOYMENT_TARGET=15.0`, matching the release's
  `minos 15.0`. Without it, Xcode 27 produces a `winemetal.so` with `minos 27.0` and a
  metallib inside `d3d11.dll`/`d3d12.dll` targeting `air64_v29-apple-macosx27.0.0`, and
  neither loads on macOS 26. The script checks both before packaging.
- **D3D12.** Built with gcc (CI builds it only with llvm-mingw and leaves it out of its
  package). It goes to `x86_64-windows-d3d12/`, outside the directories the engine copies.

The DLLs are not bit-reproducible, because the PE headers carry link timestamps. A rebuild
gives new hashes, so publish the tarball whose hashes are pinned and not a rebuild.

## ABI against winemac-patch

No change is needed. The `macdrv_functions` lookup in `src/winemetal/unix/winemetal_unix.c`
is the same as in v0.80. DXMT reads slots 1, 2, 6, 7 and 8 of the nine
`dxmt_export.c` exports. It also declares a tenth slot, `on_main_thread`, but never reads it. It reads
only `client_cocoa_view` from `get_win_data`, at offset 24, which matches `dxmt_win_data`.
The only symbol `winemetal.so` binds from Wine is `NtSetEvent` from `ntdll.so`.

A Rosetta `dlopen` of the built `winemetal.so` next to Gcenx's `ntdll.so` and `win32u.so`
and the shipped `winemac-winehq-11.15.so` resolves every dependency and finds
`macdrv_functions` with all nine slots set.

`winemetal.so` and both `winemetal.dll` files share one unix-call table. Replace them
together with the other DLLs, and never mix them with v0.80 files.

## D3D12

This build is for testing only. Upstream marks the backend unfinished: PR #182 ("D3D12
implementation, part 2") and PR #212 ("part 9") both say "DO NOT USE". In issue #194 the maintainer
answers "Don't (at the moment)" to a question about testing it. There are 153 commits to
`src/d3d12` since v0.80, and fixes are still landing (`a3d9005`, 2026-10-05; PR #225
open). It is 64-bit only. To try it, copy it into `x86_64-windows/` beside the other DLLs
from the same tarball.

## Files (`dxmt-e94c312.tar.gz`)

| File | sha256 |
| - | - |
| `x86_64-unix/winemetal.so` | `1d0a1258cbb696e1323d1fde77ebef7fedf5ea32a554bb777a9916321dedc195` |
| `x86_64-windows/d3d10core.dll` | `14fef5785b9c83ab1d440d9d8de9d2d875420b9ae468c282737fcd44bb75336b` |
| `x86_64-windows/d3d11.dll` | `f2ee8959c19548fb66c5b2a3802ff84967107d2faa3391bafb38c1363ece8a8b` |
| `x86_64-windows/dxgi.dll` | `75436305876c11f4b7e8535fc32b0007e157b062dbd1534c1757c310a44bd99e` |
| `x86_64-windows/winemetal.dll` | `33dd95086ab29ed03f876c47589b04a1e4a5891c6cbb5af6129309414aa8b0f7` |
| `x86_64-windows/nvapi64.dll` | `bc3a2f4f4020993d3f0ee4782b4b75faa1a9bb80bc8739d87619f06df9a5df57` |
| `x86_64-windows/nvngx.dll` | `a8e7793059116518f8aaf5e8c4e2376c1d66d800740b5d645a933f9cea26658a` |
| `i386-windows/d3d10core.dll` | `7cbefea0f3b766024b85413ec75a2cc32e0431bbcc5f966b0b7515b4d785f3e7` |
| `i386-windows/d3d11.dll` | `842b5a3868230e1b3eb829581b362f4ff56c86b318a3ce5b5307fa071485b58d` |
| `i386-windows/dxgi.dll` | `51d01ce7f2b9edacaaa3490d838a95bf060ff04db7f42fe746cb62174c484bca` |
| `i386-windows/winemetal.dll` | `6ddeb053c5510cffafdabfd27c8a67950f2e37308e6b9f9d1a0c44b9119ac456` |
| `x86_64-windows-d3d12/d3d12.dll` | `30c11f6672fd59ebbe316b3b4e85efb2090c6e28df8a0bdc74befde0f02d4c27` |
| tarball | `8de0d5b7eb2b96315f6ec8e259c05423ab43212e776196147b30d9f44927f7f0` |

This table pins what `dxmt-e94c312.tar.gz` already ships; its hash does not change. The next
pinned commit's tarball also carries `COPYING.LIB`, `LICENSE` and
`LICENSE-0.80-and-earlier.txt` (`scripts/build-dxmt.sh`), which `FreeEngine.swift` does not
list in `expectedFiles` and so does not need pinning here.
