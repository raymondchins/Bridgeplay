# d3dx9-patch

`winecx-gather-fragments.patch` turns `D3DXGatherFragments` and its `FromFileA/W` and
`FromResourceA/W` variants in `d3dx9_24` to `d3dx9_41` from spec stubs into functions that set
both output buffers to `NULL` and return `E_NOTIMPL`. A game that calls one (Granado Espada,
Discussion #3728) otherwise dies with `unimplemented function d3dx9_41.dll.D3DXGatherFragments`
(Wine bug 54196 is the same abort in `d3dx9_36`, closed as abandoned with no patch). Wine's
fragment linker already returns `E_NOTIMPL` from every method, so failing here matches it.
`d3dx9_42` and `d3dx9_43` don't export these functions, so the code is built only up to
`D3DX_SDK_VERSION` 41. The change is the shared `d3dx9_36/shader.c`, eighteen `.spec` entries
and the prototypes in `include/d3dx9shader.h`; only `d3dx9_41` and `d3dx9_36` are rebuilt and
shipped, since each version is a full 0.9-1.1 MB copy of d3dx9. Wine master still has the stubs
(checked 2026-11-15). Against winecx `e0aa380`; the build and pins are in `docs/WINECX.md`
(D3DX9 fragment gathering).
