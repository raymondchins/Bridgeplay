# winemac-patch

Upstream Wine builds hide the macdrv functions DXMT's `winemetal.so` looks up with
`dlsym`, so DXMT can create a D3D11 device but no swapchain. `dxmt_export.c` exports
them as the `macdrv_functions` table DXMT checks first, translating `struct macdrv_win_data`
to the older layout DXMT expects and creating the window's client view on demand.

To rebuild `app/Sources/BridgeplayApp/Resources/winemac-winehq-11.15.so`:

    tar xf wine-11.15.tar.xz && cd wine-11.15
    cp ../winemac-patch/dxmt_export.c dlls/winemac.drv/
    # add "dxmt_export.c \" to SOURCES in dlls/winemac.drv/Makefile.in
    PATH="$(brew --prefix bison)/bin:$PATH" arch -x86_64 ./configure --enable-win64 \
        --enable-archs=x86_64 --without-x --without-freetype CC="clang -arch x86_64" \
        OBJC="clang -arch x86_64"
    MACOSX_DEPLOYMENT_TARGET=26.0 arch -x86_64 make dlls/winemac.drv/winemac.so
    codesign -fs - dlls/winemac.drv/winemac.so

`MACOSX_DEPLOYMENT_TARGET=26.0` keeps the driver loadable on macOS 26; without it the
toolchain stamps its SDK version (27.0) as the minimum, which `make mincheck` refuses. The
tree's own `ntdll.so` and `win32u.so` can stand in for the runtime's at link time (only their
`@rpath/` install names and exports matter); built this way the result matches the previous
pin in every section, all imports and every load command except the minimum version.

Then put its sha256 in `macDriver` in `FreeEngine.swift` and in `docs/WINECX.md`, and update its line in `SignedPin.swift` (the new sha256 and its hash without the signature, see `docs/WINECX.md`, Shipped binaries).

## WineCX: `winecx-d3dmetal-retina.patch`

D3DMetal (libd3dshared's `WineSwapchainCallbacks::InitializeForHWND`) sizes a window's
backbuffer, and through it the `CAMetalLayer` drawable, from `-frame` of the view
`macdrv_view_create_metal_view` returns. A frame is in points, while D3D sizes are Win32
pixels, which are backing pixels in Retina mode, so a 1512x876-point window got a
1512x876 drawable for a 3024x1752 game and showed only its top-left quarter. The patch
hands D3DMetal a proxy view whose `-frame` is in Win32 pixels (`cgrect_win_from_mac`) and
forwards everything else; DXMT never asks for `frame`.

D3DMetal reads that frame again for `ResizeBuffers`, which games call from `WM_SIZE`. Its
client surfaces (`data->d3dmetal_client_surfaces`, CW HACK 22435) are not on win32u's list,
so `update_client_surfaces()` skipped them and their view only followed the window on the
next present: D3DMetal read the old frame and kept the old size. Ravenswatch creates its
swapchain while its window is maximized (client 3024x1752: the work area under the menu bar
and above the Dock, minus the caption), then goes borderless 3024x1964 and resizes from
`WM_SIZE`; the drawable stayed 3024x1752 and the image was stretched. The patch has
`macdrv_WindowPosChanged()` queue those surfaces' view frames before `WM_SIZE` is sent, and
the proxy reads `-frame` on the main thread behind them. With it the drawable follows to
3024x1964.

To rebuild `app/Sources/BridgeplayApp/Resources/winemac-winecx-11.15.so` from winecx
`5b45f45` (runtime 4.5.125), natively, with the CI's flags:

    git -C winecx apply ../winemac-patch/winecx-d3dmetal-retina.patch
    mkdir build && cd build
    PATH="$(brew --prefix bison)/bin:$PATH" MACOSX_DEPLOYMENT_TARGET=26.0 ac_cv_func_pipe2=no \
      ../winecx/configure --host=x86_64-apple-darwin24 --enable-archs=x86_64 --disable-tests \
      --without-x --without-wayland --without-oss --without-alsa --without-pulse --without-sane \
      --without-usb --without-v4l2 --without-pcap --without-capi --without-opencl --without-cups \
      --without-freetype --without-gstreamer --without-ffmpeg \
      CC="/usr/bin/clang -arch x86_64" CXX="/usr/bin/clang++ -arch x86_64" \
      CFLAGS="-O2 -Wno-error=implicit-function-declaration"
    make dlls/winemac.drv/<each object of winemac.so>   # the .o list of its Makefile rule
    # link as the Makefile rule does, against the runtime's own ntdll.so and win32u.so
    clang -arch x86_64 -dynamiclib -install_name @rpath/winemac.so -Wl,-rpath,@loader_path/ \
      -o winemac.so dlls/winemac.drv/*.o <runtime>/ntdll.so <runtime>/win32u.so \
      -framework AppKit -framework Carbon -framework CoreVideo -framework Foundation \
      -framework IOKit -framework Metal -framework OpenGL -framework QuartzCore -framework Security
    codesign -fs - winemac.so

Built this way without the patch, the result matches the runtime's `winemac.so` in every
section (`__text`, `__cstring`, `__const`, `__data`, objc) and in its 2147 symbols; only
`__LINKEDIT` and the SDK's framework versions differ. Then put its sha256 in `macDriver`
in `FreeEngineWinecx.swift` and in `docs/WINECX.md`, and update its line in `SignedPin.swift` (the new sha256 and its hash without the signature, see `docs/WINECX.md`, Shipped binaries).

### 11.17: `winecx-11.17-d3dmetal-retina.patch`

The same change re-derived against winecx `e0aa380` (runtime 4.7.3). 565f638 only adds the
`raw` argument to `macdrv_CreateClientSurface`; the proxy and the d3dmetal.c hooks apply as
they were. CW HACK 22435 had to change: Wine 11.17 no longer exports `client_surface_update`
from win32u (only `client_surface_present`, `update_client_surfaces` and friends are in
`gdi_driver.h`), so the 11.15 hunk fails to link. The 11.17 hunk calls
`client_surface_present()` instead, which recomputes the rects and runs the driver's `update`
exactly as `client_surface_update()` did, then `present`, which makes the surface the window's
client view. To keep that a no-op it only touches the D3DMetal surface that already is
`data->client_view` (the one D3DMetal last presented), not every surface in the list.

Build as above from `e0aa380`, with two differences in the link: no `-framework CoreVideo`
(11.17's `cocoa_window.m` dropped `WineDisplayLink`, and the Makefile rule with it), and the
CI's `install_name_tool -add_rpath @loader_path/../../` before the final `codesign -fs -`.
Built this way without the patch, the result matches the runtime 4.7.3 `winemac.so` in every
section, all 2095 symbols and every load command.
