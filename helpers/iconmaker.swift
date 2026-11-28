// Reads an image and produces a macOS .icns masked to the continuous rounded
// rect (squircle) that native app icons use. Input is scaled to fill 1024x1024
// and clipped. Output covers 16x16 through 512x512@2x.
// Usage: iconmaker <input-image|input.exe> <output.icns>
//        iconmaker --shortcuts <appid> <icon.icns> <stock.icns>
//        iconmaker --games-category <appid>

import AppKit
import Foundation

if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--shortcuts" {
    np_shortcuts_icons(getenv("HOME"), CommandLine.arguments[2], CommandLine.arguments[3], CommandLine.arguments[4])
    exit(0)
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--games-category" {
    np_shortcuts_games(getenv("HOME"), CommandLine.arguments[2]) { path in
        guard let path else { return }
        // Launch Services rereads the plist now rather than on its next scan.
        let status = LSRegisterURL(URL(fileURLWithPath: String(cString: path)) as CFURL, true)
        fputs("iconmaker: filed \(String(cString: path)) with games (\(status))\n", stderr)
    }
    exit(0)
}

guard CommandLine.arguments.count == 3 else {
    fputs("usage: iconmaker <input-image|input.exe> <output.icns>\n", stderr)
    exit(1)
}

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

private func loadImage(_ path: String) -> NSImage? {
    var length = 0
    if let raw = np_pe_icon_ico(path, &length) {
        let ico = Data(bytesNoCopy: raw, count: length, deallocator: .free)
        if !ico.isEmpty, let image = NSImage(data: ico), hasArea(image) {
            FileHandle.standardError.write(Data("iconmaker: using icon from PE resources\n".utf8))
            return image
        }
    }
    return NSImage(contentsOfFile: path)
}

private func hasArea(_ image: NSImage) -> Bool {
    image.size.width > 0 && image.size.height > 0
        && image.size.width.isFinite && image.size.height.isFinite
}

guard let srcImage = loadImage(inputPath), hasArea(srcImage) else {
    fputs("iconmaker: cannot read \(inputPath)\n", stderr)
    exit(1)
}

// The Apple icon grid puts the squircle corner radius at ~22.37% of the
// icon side. NSBezierPath.init(roundedRect:xRadius:yRadius:) draws a
// continuous rounded rect on macOS 14+, which is the shape Finder uses.
let maskRadius: CGFloat = 0.2237

let sizes: [(side: Int, scale: Int, name: String)] = [
    (16, 1, "icon_16x16.png"),
    (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"),
    (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

struct IconmakerError: Error {
    let message: String
}

// Renders each size into a temporary iconset next to the output and packs it
// with iconutil. The defer removes the iconset on every exit, failures included.
func writeIcns(_ image: NSImage, to outputPath: String) throws {
    let fm = FileManager.default
    let iconsetURL = URL(filePath: outputPath + ".iconset")
    try? fm.removeItem(at: iconsetURL)
    try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: iconsetURL) }

    for entry in sizes {
        let px = entry.side * entry.scale
        let s = CGFloat(px)
        let r = s * maskRadius

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!

        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx

        // Clip to the squircle, then draw the source image scaled to fill.
        let rect = NSRect(x: 0, y: 0, width: s, height: s)
        let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        path.addClip()

        // Scale-to-fill: pick the scale that covers the canvas on both axes,
        // then center the overflow.
        let srcSize = image.size
        let scale = max(s / srcSize.width, s / srcSize.height)
        let drawW = srcSize.width * scale
        let drawH = srcSize.height * scale
        let drawRect = NSRect(
            x: (s - drawW) / 2, y: (s - drawH) / 2,
            width: drawW, height: drawH
        )
        image.draw(in: drawRect)

        ctx.flushGraphics()
        NSGraphicsContext.current = nil

        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw IconmakerError(message: "failed to render \(entry.name)")
        }

        try png.write(to: iconsetURL.appending(path: entry.name))
    }

    // iconutil produces the .icns from the populated iconset directory.
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", iconsetURL.path, "-o", outputPath]
    try proc.run()
    proc.waitUntilExit()

    if proc.terminationStatus != 0 {
        throw IconmakerError(message: "iconutil failed with status \(proc.terminationStatus)")
    }
}

do {
    try writeIcns(srcImage, to: outputPath)
} catch let error as IconmakerError {
    fputs("iconmaker: \(error.message)\n", stderr)
    exit(1)
} catch {
    fputs("iconmaker: \(error.localizedDescription)\n", stderr)
    exit(1)
}
