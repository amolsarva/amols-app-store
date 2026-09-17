#!/usr/bin/env swift
// Renders Backstage's app icon (a stage curtain + terminal prompt) to PNG.
// Usage: swift tools/make-icon.swift out.png   (build.sh turns it into AppIcon.icns)
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// Rounded-square background with a deep blue→violet gradient.
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let path = CGPath(roundedRect: rect.insetBy(dx: size * 0.06, dy: size * 0.06),
                  cornerWidth: size * 0.22, cornerHeight: size * 0.22, transform: nil)
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let colors = [NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.42, alpha: 1).cgColor,
              NSColor(calibratedRed: 0.42, green: 0.22, blue: 0.62, alpha: 1).cgColor]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Curtain: two sweeping arcs at the top corners.
ctx.setFillColor(NSColor(calibratedRed: 0.85, green: 0.25, blue: 0.35, alpha: 0.9).cgColor)
for mirrored in [false, true] {
    ctx.saveGState()
    if mirrored { ctx.translateBy(x: size, y: 0); ctx.scaleBy(x: -1, y: 1) }
    let curtain = CGMutablePath()
    curtain.move(to: CGPoint(x: size * 0.06, y: size * 0.94))
    curtain.addCurve(to: CGPoint(x: size * 0.42, y: size * 0.94),
                     control1: CGPoint(x: size * 0.10, y: size * 0.62),
                     control2: CGPoint(x: size * 0.30, y: size * 0.70))
    curtain.addLine(to: CGPoint(x: size * 0.06, y: size * 0.94))
    ctx.addPath(curtain)
    ctx.fillPath()
    ctx.restoreGState()
}

// Terminal prompt: chevron + underscore.
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineWidth(size * 0.055)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: size * 0.33, y: size * 0.55))
ctx.addLine(to: CGPoint(x: size * 0.47, y: size * 0.42))
ctx.addLine(to: CGPoint(x: size * 0.33, y: size * 0.29))
ctx.strokePath()
ctx.move(to: CGPoint(x: size * 0.545, y: size * 0.29))
ctx.addLine(to: CGPoint(x: size * 0.70, y: size * 0.29))
ctx.strokePath()

ctx.restoreGState()
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
