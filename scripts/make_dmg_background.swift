// Renders the Finder background art for the S3DV viewer DMG.
//
//   swift scripts/make_dmg_background.swift [--scale 2] [--out-dir DIR] [--icon PATH|--no-icon]
//
// Pure CoreGraphics/AppKit offscreen rendering: no window server, no external
// assets except the app's own .icns (optional; a drawn fallback is used when it
// is missing). Output is deterministic for a given icon + scale.
//
// Layout is expressed in 1x Finder-window coordinates (640x400) and multiplied
// by `scale`, so the art lines up with the icon positions written to .DS_Store
// (app at 170,190 / Applications at 470,190, y measured from the window top).
//
// The app icon is drawn as a large, softly glowing *ghost* rather than a solid
// copy: Finder paints the real 128px icon on top of it, so the art supplies the
// halo and the ghost only peeks out around the edges.

import AppKit

// MARK: - Canvas geometry (1x)

let baseWidth: CGFloat = 640
let baseHeight: CGFloat = 400

// MARK: - Args

var scale = 2
var outDir = "assets/dmg"
var iconPath: String? = "assets/AppIcon.icns"

let argv = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < argv.count {
    switch argv[i] {
    case "--scale":
        i += 1
        guard i < argv.count, let v = Int(argv[i]), v >= 1, v <= 4 else {
            FileHandle.standardError.write("error: --scale expects 1...4\n".data(using: .utf8)!)
            exit(2)
        }
        scale = v
    case "--out-dir":
        i += 1
        guard i < argv.count else {
            FileHandle.standardError.write("error: --out-dir expects a path\n".data(using: .utf8)!)
            exit(2)
        }
        outDir = argv[i]
    case "--icon":
        i += 1
        iconPath = i < argv.count ? argv[i] : nil
    case "--no-icon":
        iconPath = nil
    case "-h", "--help":
        print("usage: make_dmg_background.swift [--scale N] [--out-dir DIR] [--icon PATH|--no-icon]")
        exit(0)
    default:
        FileHandle.standardError.write("error: unknown argument \(argv[i])\n".data(using: .utf8)!)
        exit(2)
    }
    i += 1
}

let pixelWidth = Int(baseWidth) * scale
let pixelHeight = Int(baseHeight) * scale

// MARK: - Helpers

func rgba(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: alpha
    )
}

/// Centres in 1x *top-left* coordinates, like Finder icon positions.
func centered(_ x: CGFloat, _ yTop: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x - w / 2, y: baseHeight - yTop - h / 2, width: w, height: h)
}

/// A smooth radial wash centred on a 1x top-left point.
func radialGlow(center: (CGFloat, CGFloat), radius: CGFloat, color: NSColor, alpha: CGFloat) {
    guard let g = NSGraphicsContext.current?.cgContext else { return }
    let origin = CGPoint(x: center.0, y: baseHeight - center.1)
    let space = CGColorSpaceCreateDeviceRGB()
    let stops: [CGFloat] = [0.0, 0.45, 1.0]
    let alphas: [CGFloat] = [alpha, alpha * 0.45, 0.0]
    let colors = alphas.compactMap {
        color.withAlphaComponent($0).usingColorSpace(.deviceRGB)?.cgColor
    }
    guard let grad = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops) else { return }
    g.saveGState()
    g.setBlendMode(.plusLighter)
    g.drawRadialGradient(
        grad,
        startCenter: origin, startRadius: 0,
        endCenter: origin, endRadius: radius,
        options: [.drawsAfterEndLocation]
    )
    g.restoreGState()
}

// MARK: - Bitmap

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelWidth,
    pixelsHigh: pixelHeight,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write("error: could not allocate \(pixelWidth)x\(pixelHeight) bitmap\n".data(using: .utf8)!)
    exit(1)
}
rep.size = NSSize(width: baseWidth, height: baseHeight)

guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write("error: could not create NSGraphicsContext\n".data(using: .utf8)!)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high
ctx.shouldAntialias = true

// MARK: - Background gradient (#101827 -> #1b2a3f)

let canvas = NSRect(x: 0, y: 0, width: baseWidth, height: baseHeight)
NSGradient(starting: rgba(0x101827), ending: rgba(0x1B2A3F))?.draw(in: canvas, angle: -90)

// Top sheen and bottom vignette: barely perceptible, keeps the plate from
// looking like a flat swatch.
NSGradient(starting: rgba(0xFFFFFF, 0.045), ending: rgba(0xFFFFFF, 0.0))?
    .draw(in: NSRect(x: 0, y: baseHeight * 0.62, width: baseWidth, height: baseHeight * 0.38), angle: -90)
NSGradient(starting: rgba(0x000000, 0.0), ending: rgba(0x000000, 0.30))?
    .draw(in: NSRect(x: 0, y: 0, width: baseWidth, height: 150), angle: -90)

// MARK: - App icon halo + ghost (left, at 170,190)

let iconCenter: (CGFloat, CGFloat) = (170, 190)

radialGlow(center: iconCenter, radius: 165, color: rgba(0x5B87C8), alpha: 0.55)
radialGlow(center: iconCenter, radius: 96, color: rgba(0x8FB6FF), alpha: 0.30)

func drawFallbackIcon(in box: NSRect, alpha: CGFloat) {
    // Wireframe-cube mark, used only when no .icns is available.
    let plate = NSBezierPath(roundedRect: box, xRadius: box.width * 0.22, yRadius: box.width * 0.22)
    rgba(0x8FB6FF, 0.10 * alpha).setFill()
    plate.fill()
    rgba(0x8FB6FF, 0.55 * alpha).setStroke()
    plate.lineWidth = 1.5
    plate.stroke()

    let c = NSPoint(x: box.midX, y: box.midY)
    let s = box.width * 0.26
    let top = NSPoint(x: c.x, y: c.y + s)
    let ul = NSPoint(x: c.x - s * 0.9, y: c.y + s * 0.45)
    let ur = NSPoint(x: c.x + s * 0.9, y: c.y + s * 0.45)
    let ll = NSPoint(x: c.x - s * 0.9, y: c.y - s * 0.45)
    let lr = NSPoint(x: c.x + s * 0.9, y: c.y - s * 0.45)
    let bot = NSPoint(x: c.x, y: c.y - s)

    let cube = NSBezierPath()
    for (a, b) in [(top, ul), (top, ur), (ul, ll), (ur, lr), (ll, bot), (lr, bot), (ul, ur), (ll, lr)] {
        cube.move(to: a)
        cube.line(to: b)
    }
    rgba(0x9CC4FF, 0.85 * alpha).setStroke()
    cube.lineWidth = 2.0
    cube.lineJoinStyle = .round
    cube.stroke()
}

if let path = iconPath, let image = NSImage(contentsOfFile: path) {
    // Drawn at 140pt: slightly larger than the 128pt icon Finder paints on top,
    // so the artwork supplies a thin rim + shadow and nothing reads as a
    // duplicated icon. No blur: keeps the PNG deterministic and seam-free.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = rgba(0x000000, 0.55)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    image.draw(
        in: centered(iconCenter.0, iconCenter.1, 140, 140),
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    NSGraphicsContext.restoreGraphicsState()
} else {
    drawFallbackIcon(in: centered(iconCenter.0, iconCenter.1, 186, 186), alpha: 0.55)
}

// MARK: - Applications drop zone (right, at 470,190)

let appCenter: (CGFloat, CGFloat) = (470, 190)

radialGlow(center: appCenter, radius: 120, color: rgba(0x5B87C8), alpha: 0.28)

// Dashed rounded frame, sized so it sits just inside Finder's 128px icon.
let frameRect = centered(appCenter.0, appCenter.1, 164, 164)
let frame = NSBezierPath(roundedRect: frameRect, xRadius: 30, yRadius: 30)
frame.setLineDash([7, 6], count: 2, phase: 0)
rgba(0x8FB6FF, 0.26).setStroke()
frame.lineWidth = 1.2
frame.stroke()

// Folder glyph hint: tab + body + a small "drop in" chevron, drawn faintly so
// Finder's alias icon stays the lead element.
let glyphCenterY = appCenter.1 + 2
let folderW: CGFloat = 60
let folderH: CGFloat = 40
let folderRect = NSRect(
    x: appCenter.0 - folderW / 2,
    y: baseHeight - glyphCenterY - folderH / 2,
    width: folderW,
    height: folderH
)
let tabRect = NSRect(x: folderRect.minX + 4, y: folderRect.maxY - 3, width: folderW * 0.50, height: 11)
rgba(0x9CC4FF, 0.16).setFill()
NSBezierPath(roundedRect: tabRect, xRadius: 4.5, yRadius: 4.5).fill()

let body = NSBezierPath(roundedRect: folderRect, xRadius: 9, yRadius: 9)
NSGradient(starting: rgba(0xA9C8FF, 0.24), ending: rgba(0x7FA8E8, 0.13))?.draw(in: body, angle: -90)
rgba(0xC7DBFF, 0.32).setStroke()
body.lineWidth = 1.2
body.stroke()

let chevron = NSBezierPath()
let cx = folderRect.midX
let cy = folderRect.midY + 6
chevron.move(to: NSPoint(x: cx - 7, y: cy + 5))
chevron.line(to: NSPoint(x: cx, y: cy - 3))
chevron.line(to: NSPoint(x: cx + 7, y: cy + 5))
chevron.lineJoinStyle = .round
chevron.lineCapStyle = .round
chevron.lineWidth = 2.0
rgba(0xDCE9FF, 0.42).setStroke()
chevron.stroke()

// Caption sits *above* the frame: Finder draws the alias label underneath, so
// anything placed below would collide with it.
let caption = NSAttributedString(
    string: "A P P L I C A T I O N S",
    attributes: [
        .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
        .foregroundColor: rgba(0xB9CDE6, 0.72),
        .kern: 0.6,
    ]
)
let capSize = caption.size()
caption.draw(at: NSPoint(x: appCenter.0 - capSize.width / 2, y: baseHeight - 96))

// MARK: - Arrow between the two icons

let arrowY = baseHeight - 190
let arrowStart = NSPoint(x: 296, y: arrowY)
let arrowEnd = NSPoint(x: 404, y: arrowY)

let shaft = NSBezierPath()
shaft.move(to: arrowStart)
shaft.line(to: NSPoint(x: arrowEnd.x - 13, y: arrowEnd.y))
shaft.lineCapStyle = .round
shaft.lineWidth = 2.0
rgba(0x8FB6FF, 0.45).setStroke()
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: arrowEnd.x - 15, y: arrowEnd.y + 7))
head.line(to: NSPoint(x: arrowEnd.x - 2, y: arrowEnd.y))
head.line(to: NSPoint(x: arrowEnd.x - 15, y: arrowEnd.y - 7))
head.lineJoinStyle = .round
head.lineCapStyle = .round
head.lineWidth = 2.0
rgba(0x8FB6FF, 0.62).setStroke()
head.stroke()

// MARK: - Title block (bottom band, clear of the icon labels)

let title = NSAttributedString(
    string: "S3DV viewer",
    attributes: [
        .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
        .foregroundColor: rgba(0xF2F6FC, 0.95),
        .kern: -0.2,
    ]
)
let subtitle = NSAttributedString(
    string: "ドラッグして Applications へ",
    attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: rgba(0x9FB3CC, 0.92),
    ]
)
let titleSize = title.size()
let subtitleSize = subtitle.size()
title.draw(at: NSPoint(x: (baseWidth - titleSize.width) / 2, y: 58))
subtitle.draw(at: NSPoint(x: (baseWidth - subtitleSize.width) / 2, y: 36))

ctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

// MARK: - Write PNGs

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("error: PNG encoding failed\n".data(using: .utf8)!)
    exit(1)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func write(_ data: Data, to path: String) {
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(data.count) bytes, \(pixelWidth)x\(pixelHeight))")
    } catch {
        FileHandle.standardError.write("error: \(path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// background.png is rendered at `scale` so Finder downscales it on 2x displays;
// background@2x.png is the identical Retina-resolution copy.
write(png, to: "\(outDir)/background.png")
if scale == 2 {
    write(png, to: "\(outDir)/background@2x.png")
}
