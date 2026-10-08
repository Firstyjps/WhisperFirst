// สร้างไอคอนแอป 1024px: ไล่สีส้ม→ชมพู + waveform สีขาว + "ก"
import AppKit

let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(x: 100, y: 100, width: S - 200, height: S - 200)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(srgbRed: 1.0, green: 0.55, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.86, green: 0.16, blue: 0.47, alpha: 1)])!
    .draw(in: path, angle: -55)
let cfg = NSImage.SymbolConfiguration(pointSize: 400, weight: .bold).applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = sym.size
    sym.draw(in: NSRect(x: (S - s.width) / 2, y: (S - s.height) / 2 + 60, width: s.width, height: s.height))
}
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 150, weight: .heavy), .foregroundColor: NSColor.white.withAlphaComponent(0.92)]
let t = NSAttributedString(string: "ก", attributes: attrs)
t.draw(at: NSPoint(x: (S - t.size().width) / 2, y: 175))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
