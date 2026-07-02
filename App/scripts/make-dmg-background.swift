// Renders the DMG installer-window background: indigo gradient, title, an arrow pointing
// from the app icon (left) toward the Applications folder (right), and a hint line.
// Icon positions in make-dmg.sh must match the gaps left here: app ~(170,200), Apps ~(490,200)
// in a 660x400-point window (top-left origin in Finder; this art is centered vertically so it
// reads correctly either way). Usage: swift make-dmg-background.swift <out-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// Render at 2x, then downscale for a 1x companion; combine into a multi-rep TIFF later.
func render(scale: CGFloat) -> Data {
    let w: CGFloat = 660 * scale
    let h: CGFloat = 400 * scale
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: w, height: h)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.14, green: 0.12, blue: 0.32, alpha: 1),
        NSColor(calibratedRed: 0.26, green: 0.18, blue: 0.52, alpha: 1),
    ])!
    gradient.draw(in: rect, angle: 90)

    func draw(_ text: String, size: CGFloat, y: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * scale, weight: weight),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .paragraphStyle: style,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let th = s.size().height
        s.draw(in: NSRect(x: 0, y: (h - y * scale) - th / 2, width: w, height: th))
    }

    draw("Install Internos", size: 26, y: 64, weight: .semibold, alpha: 0.95)
    draw("Drag the app onto the Applications folder", size: 13, y: 330, weight: .regular, alpha: 0.7)

    // Arrow across the middle, between the two icon slots (~x 250 → 410).
    let arrow = NSBezierPath()
    let midY = (h / 2)
    let x0 = 258 * scale, x1 = 402 * scale
    arrow.lineWidth = 6 * scale
    arrow.lineCapStyle = .round
    arrow.move(to: NSPoint(x: x0, y: midY))
    arrow.line(to: NSPoint(x: x1, y: midY))
    let head = 16 * scale
    arrow.move(to: NSPoint(x: x1 - head, y: midY + head))
    arrow.line(to: NSPoint(x: x1, y: midY))
    arrow.line(to: NSPoint(x: x1 - head, y: midY - head))
    NSColor.white.withAlphaComponent(0.85).setStroke()
    arrow.stroke()

    image.unlockFocus()
    let tiff = image.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    return rep.representation(using: .png, properties: [:])!
}

let url2x = URL(fileURLWithPath: outDir).appendingPathComponent("dmg-bg@2x.png")
let url1x = URL(fileURLWithPath: outDir).appendingPathComponent("dmg-bg-1x.png")
try! render(scale: 2).write(to: url2x)
try! render(scale: 1).write(to: url1x)
print("wrote \(url1x.lastPathComponent) and \(url2x.lastPathComponent)")
