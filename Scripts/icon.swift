import AppKit

// Draws the app icon at 1024 px and writes icon.png next to the given path.
let out = CommandLine.arguments[1]
let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 186, yRadius: 186)
NSGradient(colors: [NSColor(red: 0.05, green: 0.10, blue: 0.30, alpha: 1), NSColor(red: 0.12, green: 0.38, blue: 0.75, alpha: 1),
                    NSColor(red: 0.45, green: 0.30, blue: 0.85, alpha: 1)])!.draw(in: shape, angle: 60)
shape.addClip()
NSGradient(colors: [NSColor(white: 1, alpha: 0.35), NSColor(white: 1, alpha: 0)])!
    .draw(in: NSBezierPath(ovalIn: NSRect(x: 0, y: 560, width: 1024, height: 700)), angle: -90)
// Chip body
let chip = NSBezierPath(roundedRect: NSRect(x: 322, y: 322, width: 380, height: 380), xRadius: 84, yRadius: 84)
NSColor(white: 1, alpha: 0.22).setFill(); chip.fill()
NSColor(white: 1, alpha: 0.75).setStroke(); chip.lineWidth = 12; chip.stroke()
NSColor(white: 1, alpha: 0.7).setFill()
for i in 0..<4 {
    let o = 372.0 + Double(i) * 78
    for r in [NSRect(x: o, y: 716, width: 34, height: 70), NSRect(x: o, y: 238, width: 34, height: 70),
              NSRect(x: 238, y: o, width: 70, height: 34), NSRect(x: 716, y: o, width: 70, height: 34)] {
        NSBezierPath(roundedRect: r, xRadius: 17, yRadius: 17).fill()
    }
}
let cfg = NSImage.SymbolConfiguration(pointSize: 210, weight: .bold).applying(.init(paletteColors: [.white]))
if let star = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = star.size
    star.draw(in: NSRect(x: 512 - s.width / 2, y: 512 - s.height / 2, width: s.width, height: s.height))
}
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
