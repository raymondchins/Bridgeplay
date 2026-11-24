// Pins for the Mach-O files Bridgeplay ships in its bundle and lays into Wine

import Foundation

// Each one is committed signed ad hoc and pinned by that file's sha256. A release re-signs it
// with the Developer ID so Apple notarizes the app (Makefile, `app`), which changes the bytes
// but not the code. So it also matches by its hash without the signature
// (MachOBuild.hashesIgnoringSignature), and an engine laid out by either build stays current.
enum SignedPin {
    // sha256 as committed -> hash without the signature. SignedPinTests checks every entry
    // against the file in Resources, so a rebuilt binary needs its line updated here.
    static let content: [String: String] = [
        // cabextract (PrefixTools, for Winetricks)
        "8c8f3b80ce8998b952df3638abcacd44161793646376fa549d9f33ab8aeea171":
            "d8ac10ff9343a991c7a8d8de6f9576db29c0febe0a0f9ebc807c7a12cfd4d034",
        // libSDL2-2.0.0.dylib
        "aeeec088bf51f9eac0dbd8e26ae994c7b8568fb42fc676835d6dc2109fc559d1":
            "2e2a0912e0b1831986684a26e68e2b195e8e7d3ae2a0e7dce7084bd23827065c",
        // win32u-winecx-11.17.so
        "b012382d09b2ff1b3c0750d93867f72dd04a7c902bc4179be406b6c558ab162d":
            "656c033cb8aa1c8b55117d68047e0d4c39aa0be90db60f366d54a1059abb2988",
        // winebus-winecx-11.15.so
        "1bc53184f5d026ab84a26cf6ef721348fc3b028c019ff969e69eb6cf9b9d1af9":
            "e57838d1adb71daf921748f2f9591cdcd2d25631a02b84cb9dddd9a110d81b27",
        // winebus-winecx-11.17.so
        "6223c035c824c90708abbc3e733f8d1d6ed6b8b4e9a3e1a5c813493ceba50473":
            "b86ea933eead8dd6ed52863c47a07fa5f79a1ec575e5d55980a1dad0e3f76615",
        // winecoreaudio-winecx-11.17.so
        "680b267e8cf41af0868de4adf7f6760615a434a4be06b4ab0cfeece2d9240faa":
            "8a4888b841096cd321d0127a4831605125b38c6e634bdd0418db7b02dbe58c3a",
        // winemac-winecx-11.15.so
        "76d8f93839386f37e8badf0c82bb31b5ead22ac580f17896f9d2a729af0fc147":
            "bb78304668d8e4098602285e7c0e4061aec627a8ab687aa576092fd2d82765bd",
        // winemac-winecx-11.17.so
        "aa192f846ad15d56de200fc92752eaf2d455700846ae2cf1ccc7b27b535f1c00":
            "2961137b297518ab99ca11f65d00388d3521bd1e9f7a118219f7617523dc841b",
        // winemac-winehq-11.15.so
        "d95fe40b6321ba8a34933a6b394af6d75547220a7168896c357af3a32377b08f":
            "fe3188214322d862ca54761fd9ab70b95afe5b670684a99284dd0b0b5101c383",
    ]

    // The committed bytes, or the same code under any valid signature.
    static func matches(_ file: URL, sha256 pin: String) -> Bool {
        guard let actual = Digest.sha256IfPresent(file) else { return false }
        if actual == pin { return true }
        guard let expected = content[pin],
              (try? Shell.run("/usr/bin/codesign", ["--verify", "--strict", file.path(percentEncoded: false)]))?.succeeded == true,
              let hashes = try? MachOBuild.hashesIgnoringSignature(of: file)
        else { return false }
        return hashes.joined(separator: ",") == expected
    }
}
