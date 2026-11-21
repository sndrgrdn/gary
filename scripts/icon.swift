import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/Gary.icns")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("icon: \(message)\n".utf8))
    exit(1)
}

guard let artwork = NSImage(contentsOf: URL(fileURLWithPath: "Resources/Gary.svg")) else { fail("cannot read Resources/Gary.svg") }

func draw(_ size: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0,
    ) else { fail("cannot allocate a \(size) point bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    artwork.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appending(path: "Gary.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        guard let png = draw(points * factor).representation(using: .png, properties: [:]) else { fail("cannot encode \(name)") }
        try png.write(to: iconset.appending(path: name))
    }
}

let iconutil = try Process.run(URL(fileURLWithPath: "/usr/bin/iconutil"), arguments: ["-c", "icns", iconset.path, "-o", output.path])
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
