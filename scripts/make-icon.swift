// Draws the app icon (a sunburst on a rounded square) into an .iconset folder.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let background = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.24, alpha: 1),
                        NSColor(calibratedRed: 0.22, green: 0.2, blue: 0.38, alpha: 1)])!
        .draw(in: background, angle: 90)

    let center = NSPoint(x: s / 2, y: s / 2)
    let radius = tile.width * 0.4
    let inner = radius * 0.3
    let ring = (radius - inner) / 3
    // (start fraction, end fraction, depth, hue)
    let segments: [(Double, Double, Int, Double)] = [
        (0.0, 0.42, 1, 0.75), (0.42, 0.68, 1, 0.95), (0.68, 0.86, 1, 0.08), (0.86, 1.0, 1, 0.45),
        (0.0, 0.25, 2, 0.72), (0.25, 0.4, 2, 0.79), (0.42, 0.6, 2, 0.93), (0.68, 0.8, 2, 0.06), (0.86, 0.95, 2, 0.43),
        (0.0, 0.14, 3, 0.7), (0.25, 0.33, 3, 0.8), (0.42, 0.52, 3, 0.92), (0.68, 0.74, 3, 0.05),
    ]
    for (a, b, depth, hue) in segments {
        let r0 = inner + CGFloat(depth - 1) * ring + s * 0.006
        let r1 = inner + CGFloat(depth) * ring
        let start = 90 - a * 360, end = 90 - b * 360
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: r1, startAngle: start, endAngle: end, clockwise: true)
        path.appendArc(withCenter: center, radius: r0, startAngle: end, endAngle: start, clockwise: false)
        path.close()
        NSColor(calibratedHue: hue, saturation: 0.62 - Double(depth) * 0.08, brightness: 0.78 + Double(depth) * 0.06, alpha: 1).setFill()
        path.fill()
        NSColor(calibratedRed: 0.17, green: 0.16, blue: 0.3, alpha: 1).setStroke()
        path.lineWidth = max(1, s * 0.008)
        path.stroke()
    }
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - inner + s * 0.01, y: center.y - inner + s * 0.01,
                                width: (inner - s * 0.01) * 2, height: (inner - s * 0.01) * 2)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
