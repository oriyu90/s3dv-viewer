// Renders the S3DV Viewer app icon: dark rounded square with an isometric
// depth-mesh cube motif (top face carries the depth-grid lines) + wordmark.
// Rasters are written into <out>; assemble with:
//   iconutil -c icns build/AppIcon.iconset -o assets/AppIcon.icns
import AppKit

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let names: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func drawIcon(in rect: NSRect) {
    let w = rect.width
    // background: Big Sur-style rounded square with a vertical deep-blue gradient
    let bg = NSBezierPath(roundedRect: rect, xRadius: w * 0.2237, yRadius: w * 0.2237)
    bg.addClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.049, green: 0.071, blue: 0.122, alpha: 1.0),
        NSColor(calibratedRed: 0.114, green: 0.169, blue: 0.278, alpha: 1.0),
    ])
    gradient?.draw(in: bg, angle: 90)

    // isometric cube geometry (u = vertical half-step, horizontal half-step = 1.6u)
    let cx = rect.midX
    let cy = rect.height * 0.545
    let u = w * 0.155
    let x = w * 0.155 * 1.6
    let pTop = NSPoint(x: cx, y: cy + 2 * u)
    let pUR = NSPoint(x: cx + x, y: cy + u)
    let pLR = NSPoint(x: cx + x, y: cy - u)
    let pBot = NSPoint(x: cx, y: cy - 2 * u)
    let pLL = NSPoint(x: cx - x, y: cy - u)
    let pUL = NSPoint(x: cx - x, y: cy + u)
    let pC = NSPoint(x: cx, y: cy)

    func poly(_ points: [NSPoint], fill: NSColor, stroke: NSColor, lineW: CGFloat) {
        let path = NSBezierPath()
        path.move(to: points[0])
        for pt in points.dropFirst() { path.line(to: pt) }
        path.close()
        path.lineJoinStyle = .round
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = lineW
        path.stroke()
    }

    let edge = NSColor(calibratedWhite: 1.0, alpha: 0.92)
    let lineW = w * 0.017
    poly([pUL, pTop, pUR, pC], fill: NSColor(calibratedRed: 0.607, green: 0.815, blue: 1.0, alpha: 0.95), stroke: edge, lineW: lineW)
    poly([pUL, pC, pBot, pLL], fill: NSColor(calibratedRed: 0.216, green: 0.412, blue: 0.667, alpha: 0.95), stroke: edge, lineW: lineW)
    poly([pC, pUR, pLR, pBot], fill: NSColor(calibratedRed: 0.125, green: 0.267, blue: 0.443, alpha: 0.95), stroke: edge, lineW: lineW)

    // depth-grid lines across the top face (parallelogram coordinates)
    func lerp(_ a: NSPoint, _ b: NSPoint, _ t: CGFloat) -> NSPoint {
        NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
    let gridStroke = NSColor(calibratedWhite: 1.0, alpha: 0.30)
    let gridPath = NSBezierPath()
    gridPath.lineJoinStyle = .round
    for t in [CGFloat(0.25), 0.5, 0.75] {
        gridPath.move(to: lerp(pUL, pTop, t))
        gridPath.line(to: lerp(pC, pUR, t))
        gridPath.move(to: lerp(pUL, pC, t))
        gridPath.line(to: lerp(pTop, pUR, t))
    }
    gridPath.lineWidth = w * 0.007
    gridStroke.setStroke()
    gridPath.stroke()

    // wordmark
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: w * 0.117, weight: .bold),
        .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.92),
        .kern: NSNumber(value: Double(w * 0.012)),
    ]
    let label = NSAttributedString(string: "S3DV", attributes: attrs)
    let size = label.size()
    label.draw(at: NSPoint(x: cx - size.width / 2, y: rect.height * 0.085))
}

for (name, pixel) in names {
    let image = NSImage(size: NSSize(width: pixel, height: pixel), flipped: false) { rect in
        drawIcon(in: rect)
        return true
    }
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("ERROR: rendering \(name) failed")
        exit(1)
    }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
    try png.write(to: url)
}
print("iconset written to \(outDir)")
