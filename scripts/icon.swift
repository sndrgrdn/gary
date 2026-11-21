import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/Gary.icns")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = size / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0x15171c).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: color(0x343946), ending: color(0x14161b))!.draw(in: tile, angle: -90)
    color(0xffffff, 0.10).setFill()
    NSRect(x: tile.minX, y: tile.maxY - 150, width: tile.width, height: 150).fill()
    color(0xffffff, 0.16).setFill()
    NSRect(x: tile.minX, y: tile.maxY - 152, width: tile.width, height: 3).fill()
    color(0x7aa2f7).setFill()
    NSBezierPath(roundedRect: NSRect(x: 190, y: tile.maxY - 96, width: 120, height: 42), xRadius: 21, yRadius: 21).fill()
    color(0xffffff, 0.55).setFill()
    for x in [560.0, 650, 740] { NSBezierPath(ovalIn: NSRect(x: x, y: tile.maxY - 96, width: 42, height: 42)).fill() }
    NSGraphicsContext.restoreGraphicsState()

    let card = NSRect(x: 262, y: 230, width: 500, height: 380)
    NSGraphicsContext.saveGraphicsState()
    let cardShadow = NSShadow()
    cardShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    cardShadow.shadowBlurRadius = 40
    cardShadow.shadowOffset = NSSize(width: 0, height: -16)
    cardShadow.set()
    color(0xeceef4).setFill()
    NSBezierPath(roundedRect: card, xRadius: 56, yRadius: 56).fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0x2b2f3a).setFill()
    NSBezierPath(roundedRect: NSRect(x: card.minX + 60, y: card.maxY - 110, width: 250, height: 44), xRadius: 22, yRadius: 22).fill()
    color(0x2b2f3a, 0.35).setFill()
    NSBezierPath(roundedRect: NSRect(x: card.minX + 60, y: card.maxY - 190, width: 380, height: 34), xRadius: 17, yRadius: 17).fill()
    NSBezierPath(roundedRect: NSRect(x: card.minX + 60, y: card.maxY - 256, width: 300, height: 34), xRadius: 17, yRadius: 17).fill()
    color(0x9ece6a).setFill()
    NSBezierPath(ovalIn: NSRect(x: card.maxX - 130, y: card.minY + 46, width: 70, height: 70)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appending(path: "Gary.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try draw(CGFloat(points * factor)).representation(using: .png, properties: [:])!.write(to: iconset.appending(path: name))
    }
}
let iconutil = try Process.run(URL(fileURLWithPath: "/usr/bin/iconutil"), arguments: ["-c", "icns", iconset.path, "-o", output.path])
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
