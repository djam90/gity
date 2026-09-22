// Renders the app icon at 1024px following the macOS icon grid (824pt squircle on a 1024 canvas).
import AppKit

let size: CGFloat = 1024
let inset: CGFloat = 100
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// Soft drop shadow under the tile.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

// Background gradient.
NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(colors: [
    NSColor(srgbRed: 0.98, green: 0.45, blue: 0.24, alpha: 1),
    NSColor(srgbRed: 0.91, green: 0.20, blue: 0.40, alpha: 1),
    NSColor(srgbRed: 0.55, green: 0.18, blue: 0.62, alpha: 1),
])!.draw(in: body, angle: -60)

// Subtle top highlight.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Branch glyph.
let config = NSImage.SymbolConfiguration(pointSize: 460, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let glyph = symbol.size
    let rect = NSRect(x: (size - glyph.width) / 2, y: (size - glyph.height) / 2, width: glyph.width, height: glyph.height)
    NSGraphicsContext.saveGraphicsState()
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    glyphShadow.shadowBlurRadius = 12
    glyphShadow.shadowOffset = NSSize(width: 0, height: -6)
    glyphShadow.set()
    symbol.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
