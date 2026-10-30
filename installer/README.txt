Installing Bridgeplay

You need:
- An Apple Silicon Mac (M1 or later) with macOS 26 or later.
- An administrator account (the installer writes to Applications).
- Internet (the installer downloads Bridgeplay and, if needed, Steam; setup
  downloads Rosetta and the WineCX engine, about 440 MB).

1. Double-click "Install.command". macOS blocks it because Apple has not
   notarized it. Click Done.
2. Open System Settings > Privacy & Security. Scroll down to Security and
   click "Open Anyway" next to "Install.command".
3. Click "Open Anyway" again and confirm with your Mac password or Touch ID.
   The installer runs in a Terminal window. If Steam is missing, it downloads
   Steam directly from Valve.
4. Bridgeplay opens with its Setup Assistant. Follow it:
   - Your Mac: click Install for Rosetta if asked (needs your Mac password).
   - Graphics: already done, click Continue.
   - Steam: sign in to your Steam account.
   - Set Up: click Set Up. It downloads the WineCX engine. If asked for App
     Management, turn on Bridgeplay in the Settings window that opens. Setup
     then continues by itself.
5. Click Open Steam, pick a Windows game, Install, Play.

Updating from NotProton or an early Bridgeplay that still used "notproton"
folders: the first time Bridgeplay opens, it moves the files from those
folders to "bridgeplay" and keeps a backup. Quit Steam and any game first; it
waits until they are closed.

Controllers: the first time you use a controller, Steam asks for Input
Monitoring. Click Allow (or turn on Steam in System Settings > Privacy &
Security > Input Monitoring).

Licensing: Bridgeplay is licensed under GPL-3.0 (see LICENSE and NOTICE).
The installer includes Apple's Game Porting Toolkit redistributables (the gptk
folder), unmodified, under Apple's own license, which is in GPTK-License.rtf.
Bridgeplay is free and non-commercial.
DXMT and DXVK (in the cache folder) keep their own licenses, in the LICENSE.*
and COPYING.LIB.dxmt files here.
