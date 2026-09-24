// Makes a macOS-style app icon (.icns) from an SF Symbol, so every app in this collection looks at home.
//
//   swift make-app-icon.swift <out.icns> <sf-symbol> <#top-hex> <#bottom-hex> [<secondary-symbol>]
//
// Follows the macOS Big Sur icon grid: an 824-pt rounded square centred in a 1024 canvas, with a
// soft drop shadow, a vertical gradient, a gentle top sheen, and a white glyph. An optional second
// symbol is drawn as a small badge in the lower-right corner.
import AppKit

let args = CommandLine.arguments
guard args.count >= 5 else {
    print("usage: make-app-icon.swift <out.icns> <sf-symbol> <#top> <#bottom> [badge-symbol]"); exit(64)
}
let out = URL(fileURLWithPath: args[1])
let symbol = args[2]
let badge = args.count > 5 ? args[5] : nil

func color(_ hex: String) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}
let top = color(args[3]), bottom = color(args[4])

func glyph(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
}

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    // Shadow
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    bottom.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    // Gradient body + sheen
    NSGradient(starting: top, ending: bottom)!.draw(in: shape, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let sheen = NSBezierPath(ovalIn: NSRect(x: -60, y: 560, width: 1144, height: 700))
    NSColor.white.withAlphaComponent(0.10).setFill()
    sheen.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.18).setStroke()
    shape.lineWidth = 3
    shape.stroke()
    // Glyph (with a soft shadow so it lifts off the gradient)
    if let g = glyph(symbol, size: 430) {
        NSGraphicsContext.saveGraphicsState()
        let gs = NSShadow()
        gs.shadowColor = NSColor.black.withAlphaComponent(0.25)
        gs.shadowOffset = NSSize(width: 0, height: -8)
        gs.shadowBlurRadius = 18
        gs.set()
        let r = g.size
        let scale = min(520 / r.width, 520 / r.height)
        let w = r.width * scale, h = r.height * scale
        g.draw(in: NSRect(x: 512 - w / 2, y: 512 - h / 2 + (badge == nil ? 0 : 30), width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
    } else {
        FileHandle.standardError.write("unknown SF Symbol: \(symbol)\n".data(using: .utf8)!); exit(1)
    }
    if let b = badge, let bg = glyph(b, size: 150, weight: .bold) {
        let disc = NSRect(x: 640, y: 170, width: 230, height: 230)
        NSColor.white.setFill(); NSBezierPath(ovalIn: disc).fill()
        let tinted = bg.copy() as! NSImage
        tinted.lockFocus(); bottom.set(); NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
        let sc = min(130 / tinted.size.width, 130 / tinted.size.height)
        let w = tinted.size.width * sc, h = tinted.size.height * sc
        tinted.draw(in: NSRect(x: disc.midX - w / 2, y: disc.midY - h / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for (scale, suffix) in [(1, ""), (2, "@2x")] {
        let png = render(base * scale).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
if p.terminationStatus != 0 { exit(p.terminationStatus) }
try! render(512).representation(using: .png, properties: [:])!
    .write(to: out.deletingPathExtension().appendingPathExtension("png"))
print("wrote \(out.path)")
