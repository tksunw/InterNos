// Generates AppIcon.icns: soundwave glyph on a deep indigo gradient, macOS-style rounded rect.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS icon grid: content inset ~10% each side, continuous-corner rect.
let inset = size * 0.098
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.2237, yRadius: size * 0.2237)
path.addClip()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.38, alpha: 1),
    NSColor(calibratedRed: 0.33, green: 0.20, blue: 0.62, alpha: 1),
])!
gradient.draw(in: rect, angle: 90)

// Glyph: waveform.and.mic — speaks "voice in, text out" without literal text.
let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let symbolSize = symbol.size
    let scale = (rect.width * 0.62) / max(symbolSize.width, symbolSize.height)
    let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
    let origin = NSPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
    symbol.draw(in: NSRect(origin: origin, size: drawSize))
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
let masterURL = URL(fileURLWithPath: outDir).appendingPathComponent("icon-1024.png")
try! png.write(to: masterURL)
print("wrote \(masterURL.path)")
