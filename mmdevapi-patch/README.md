# mmdevapi-patch

`winecx-follow-system-default.patch` makes Wine's mmdevapi notice when macOS changes its
default output or input while a game runs, and send `OnDefaultDeviceChanged` to the game's
notification clients, as Windows does. Without it a game stays on the speakers after
headphones are connected (Deadlock, #3862). Against winecx `e0aa380`; the design, the build
and the pins are in `docs/WINECX.md` (Default audio device).
