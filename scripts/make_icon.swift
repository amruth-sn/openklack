// Render the OpenKlack app icon — original artwork, MIT.
//
// Run via: swift scripts/make_icon.swift Resources/AppIcon.icns
//
// Draws a single keycap on a dark tile, with sound waves coming off it, at
// every size macOS asks for and packs them into an .icns with iconutil.

import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha)
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

func draw() {
    // Tile: Apple's macOS icon grid puts an 824 pt body inside the 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = roundedRect(tile, 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    color(0x1c1d22).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: color(0x34363e), ending: color(0x16171b))!
        .draw(in: tilePath, angle: -90)

    // Keycap, viewed slightly from above: a darker skirt with the lighter
    // dished top offset upward.
    let skirt = CGRect(x: 214, y: 196, width: 468, height: 448)
    NSGraphicsContext.saveGraphicsState()
    let capShadow = NSShadow()
    capShadow.shadowColor = color(0x000000, 0.45)
    capShadow.shadowOffset = NSSize(width: 0, height: -18)
    capShadow.shadowBlurRadius = 30
    capShadow.set()
    color(0xc9b896).setFill()
    roundedRect(skirt, 78).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0xdccdb0), ending: color(0xb4a382))!
        .draw(in: roundedRect(skirt, 78), angle: -90)

    let top = CGRect(x: 266, y: 312, width: 364, height: 306)
    // Concave dish: shaded at the top edge, catching light toward the front.
    NSGradient(colors: [color(0xe2d5bb), color(0xf6efe2), color(0xfdf9f2)],
               atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(in: roundedRect(top, 58), angle: -90)
    color(0xffffff, 0.55).setStroke()
    let rim = roundedRect(top.insetBy(dx: 2, dy: 2), 56)
    rim.lineWidth = 4
    rim.stroke()

    // "Clack" lines bursting off the keycap's top-right corner.
    let corner = CGPoint(x: 660, y: 622)
    for angle in [10.0, 45.0, 80.0] {
        let a = angle * .pi / 180
        let line = NSBezierPath()
        line.move(to: CGPoint(x: corner.x + 105 * cos(a), y: corner.y + 105 * sin(a)))
        line.line(to: CGPoint(x: corner.x + 200 * cos(a), y: corner.y + 200 * sin(a)))
        line.lineWidth = 36
        line.lineCapStyle = .round
        color(0xf08a4b).setStroke()
        line.stroke()
    }
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("OpenKlack-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(output.path)")
