import AppKit
import Foundation
import ImageIO

enum IconVariant: CaseIterable {
    case standard
    case dark
    case tinted

    var filename: String {
        switch self {
        case .standard:
            return "AppIcon-standard.png"
        case .dark:
            return "AppIcon-dark.png"
        case .tinted:
            return "AppIcon-tinted.png"
        }
    }
}

let outputDirectory = URL(fileURLWithPath: "/Users/jiahao/Desktop/Controller/Apps/ControlleriPad/ControlleriPad/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let iconSize = CGSize(width: 1024, height: 1024)

for variant in IconVariant.allCases {
    let bitmap = try makeIconBitmap(variant: variant, size: iconSize)
    let destination = outputDirectory.appendingPathComponent(variant.filename)
    try write(bitmap: bitmap, to: destination)
    print("Wrote \(destination.path)")
}

func makeIconBitmap(variant: IconVariant, size: CGSize) throws -> NSBitmapImageRep {
    let width = Int(size.width)
    let height = Int(size.height)

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "AppIconGeneration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create drawing context."])
    }

    context.scaleBy(x: 1, y: 1)

    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    defer {
        NSGraphicsContext.restoreGraphicsState()
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let bounds = CGRect(origin: .zero, size: size)

    drawBackground(in: bounds, variant: variant)
    drawDeck(in: bounds, variant: variant, context: context)

    guard let image = context.makeImage() else {
        throw NSError(domain: "AppIconGeneration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create image from drawing context."])
    }

    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = size
    return bitmap
}

func drawBackground(in bounds: CGRect, variant: IconVariant) {
    switch variant {
    case .standard:
        NSGradient(
            colors: [
                color(0xF6F8FB),
                color(0xE0E7F0),
                color(0xC9D5E4)
            ]
        )?.draw(in: bounds, angle: 315)

        color(0xFFFFFF, alpha: 0.78).setFill()
        NSBezierPath(ovalIn: CGRect(x: 92, y: 560, width: 420, height: 420)).fill()

        color(0xB9C8DB, alpha: 0.46).setFill()
        NSBezierPath(ovalIn: CGRect(x: 560, y: 84, width: 340, height: 340)).fill()
    case .dark:
        NSGradient(
            colors: [
                color(0x12161D),
                color(0x202735),
                color(0x2A3444)
            ]
        )?.draw(in: bounds, angle: 300)

        color(0x677792, alpha: 0.20).setFill()
        NSBezierPath(ovalIn: CGRect(x: 70, y: 610, width: 400, height: 400)).fill()

        color(0xA8B8CB, alpha: 0.08).setFill()
        NSBezierPath(ovalIn: CGRect(x: 548, y: 108, width: 320, height: 320)).fill()
    case .tinted:
        NSColor.clear.setFill()
        bounds.fill()
    }
}

func drawDeck(in bounds: CGRect, variant: IconVariant, context: CGContext) {
    let deckRect = CGRect(x: 166, y: 214, width: 692, height: 596)
    let trackpadRect = CGRect(x: deckRect.minX + 54, y: deckRect.minY + 72, width: 364, height: 452)
    let topLeftKey = CGRect(x: deckRect.minX + 468, y: deckRect.minY + 302, width: 96, height: 96)
    let topRightKey = CGRect(x: deckRect.minX + 590, y: deckRect.minY + 302, width: 96, height: 96)
    let bottomWideKey = CGRect(x: deckRect.minX + 468, y: deckRect.minY + 182, width: 218, height: 96)

    switch variant {
    case .standard, .dark:
        let outerShadow = NSShadow()
        outerShadow.shadowColor = NSColor.black.withAlphaComponent(variant == .standard ? 0.16 : 0.30)
        outerShadow.shadowBlurRadius = variant == .standard ? 30 : 38
        outerShadow.shadowOffset = NSSize(width: 0, height: -18)
        outerShadow.set()

        let deckPath = NSBezierPath(roundedRect: deckRect, xRadius: 136, yRadius: 136)
        deckGradient(for: variant)?.draw(in: deckPath, angle: 310)

        NSGraphicsContext.saveGraphicsState()
        color(0xFFFFFF, alpha: variant == .standard ? 0.14 : 0.10).setStroke()
        deckPath.lineWidth = 2
        deckPath.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let splitPath = NSBezierPath()
        splitPath.move(to: CGPoint(x: deckRect.minX + 446, y: deckRect.minY + 128))
        splitPath.line(to: CGPoint(x: deckRect.minX + 446, y: deckRect.maxY - 128))
        color(0xFFFFFF, alpha: variant == .standard ? 0.10 : 0.08).setStroke()
        splitPath.lineWidth = 2
        splitPath.lineCapStyle = .round
        splitPath.stroke()

        drawInsetPanel(rect: trackpadRect, fillGradient: trackpadGradient(for: variant), stroke: color(0xFFFFFF, alpha: variant == .standard ? 0.92 : 0.28))
        drawInsetPanel(rect: topLeftKey, fillGradient: keyGradient(for: variant), stroke: color(0xFFFFFF, alpha: variant == .standard ? 0.96 : 0.14))
        drawInsetPanel(rect: topRightKey, fillGradient: keyGradient(for: variant), stroke: color(0xFFFFFF, alpha: variant == .standard ? 0.96 : 0.14))
        drawInsetPanel(rect: bottomWideKey, fillGradient: keyGradient(for: variant), stroke: color(0xFFFFFF, alpha: variant == .standard ? 0.96 : 0.14))

        let accentDot = NSBezierPath(ovalIn: CGRect(x: deckRect.midX - 18, y: deckRect.minY + 78, width: 36, height: 36))
        color(variant == .standard ? 0xD8E2ED : 0xD9E2EC, alpha: variant == .standard ? 0.84 : 0.56).setFill()
        accentDot.fill()
    case .tinted:
        color(0xFFFFFF).setFill()
        NSBezierPath(roundedRect: deckRect, xRadius: 136, yRadius: 136).fill()

        punchOut(rect: trackpadRect, radius: 80, context: context)
        punchOut(rect: topLeftKey, radius: 28, context: context)
        punchOut(rect: topRightKey, radius: 28, context: context)
        punchOut(rect: bottomWideKey, radius: 28, context: context)
        punchOut(rect: CGRect(x: deckRect.midX - 18, y: deckRect.minY + 78, width: 36, height: 36), radius: 18, context: context)
        punchOut(rect: CGRect(x: deckRect.minX + 444, y: deckRect.minY + 128, width: 4, height: deckRect.height - 256), radius: 2, context: context)
    }
}

func drawInsetPanel(rect: CGRect, fillGradient: NSGradient?, stroke: NSColor) {
    let path = NSBezierPath(roundedRect: rect, xRadius: 28, yRadius: 28)
    fillGradient?.draw(in: path, angle: 270)
    stroke.setStroke()
    path.lineWidth = 1.5
    path.stroke()
}

func punchOut(rect: CGRect, radius: CGFloat, context: CGContext) {
    NSGraphicsContext.saveGraphicsState()
    context.setBlendMode(.clear)
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.restoreGraphicsState()
}

func deckGradient(for variant: IconVariant) -> NSGradient? {
    switch variant {
    case .standard:
        return NSGradient(colors: [color(0x1C2230), color(0x2D3748), color(0x3D4B5F)])
    case .dark:
        return NSGradient(colors: [color(0x313C4E), color(0x435267), color(0x53647A)])
    case .tinted:
        return nil
    }
}

func trackpadGradient(for variant: IconVariant) -> NSGradient? {
    switch variant {
    case .standard:
        return NSGradient(colors: [color(0xF9FBFD), color(0xE6EDF4), color(0xD8E2ED)])
    case .dark:
        return NSGradient(colors: [color(0xEEF3F8), color(0xDCE4ED), color(0xCBD5E0)])
    case .tinted:
        return nil
    }
}

func keyGradient(for variant: IconVariant) -> NSGradient? {
    switch variant {
    case .standard:
        return NSGradient(colors: [color(0xFDFEFF), color(0xF1F5F9)])
    case .dark:
        return NSGradient(colors: [color(0xF4F7FA), color(0xE0E7EE)])
    case .tinted:
        return nil
    }
}

func color(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
    let red = CGFloat((hex >> 16) & 0xFF) / 255
    let green = CGFloat((hex >> 8) & 0xFF) / 255
    let blue = CGFloat(hex & 0xFF) / 255
    return NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

func write(bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AppIconGeneration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG image."])
    }

    try pngData.write(to: url)
}
