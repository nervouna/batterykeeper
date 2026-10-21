// Renders the app icon artwork, design/icon.png: an upright battery on a cream base, in the
// flat style of the author's Piccolo icon. The battery's empty top pane, the gutter at the
// 80 % charge limit and the green pane below it follow Piccolo's glass.
//
// Usage: swift design/render-icon.swift [output.png]   (default: design/icon.png)
//
// The base is Apple's macOS icon grid: an 824 px continuous rounded square at 100 px on a
// 1024 px canvas, transparent outside. Geometry is in pixels, origin top left.

import AppKit
import SwiftUI

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("icon.png").path

func colour(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// Piccolo's cream and brown, and a green as light and saturated as Piccolo's blue.
let cream = colour(0xF7EBD7)
let brown = colour(0x5F4234)
let green = colour(0x5BBE6E)
let floorShadow = colour(0xEAD7BF)

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

let size = 1024
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("cannot create the canvas") }
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

// The base.
let base = rounded(CGRect(x: 100, y: 100, width: 824, height: 824), 185.4)
ctx.addPath(base)
ctx.setFillColor(cream)
ctx.fillPath()
ctx.addPath(base)
ctx.clip()

let wall: CGFloat = 40     // the outline
let gap: CGFloat = 14      // cream between the outline and the green pane
let gutter: CGFloat = 36   // the brown bar at the limit
let limit: CGFloat = 0.8   // the share of the inside below the gutter's centre

let terminal = CGSize(width: 160, height: 44)
let body = CGRect(x: (CGFloat(size) - 360) / 2, y: (CGFloat(size) - 540 - terminal.height) / 2 - 10 + terminal.height,
                  width: 360, height: 540)

// A soft floor shadow under the battery.
let shadowRect = CGRect(x: body.midX - body.width * 0.46, y: body.maxY - 8, width: body.width * 0.92, height: 56)
ctx.saveGState()
ctx.addEllipse(in: shadowRect)
ctx.clip()
ctx.translateBy(x: shadowRect.midX, y: shadowRect.midY)
ctx.scaleBy(x: shadowRect.width / shadowRect.height, y: 1)
let gradient = CGGradient(colorsSpace: sRGB, colors: [floorShadow, cream] as CFArray, locations: [0.35, 1])!
ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero,
                       endRadius: shadowRect.height / 2, options: [])
ctx.restoreGState()

// The terminal, tucked under the top wall, and the outline.
ctx.setFillColor(brown)
ctx.addPath(rounded(CGRect(x: body.midX - terminal.width / 2, y: body.minY - terminal.height,
                           width: terminal.width, height: terminal.height + 20), 18))
ctx.fillPath()
ctx.addPath(rounded(body, 78))
ctx.fillPath()
let inside = body.insetBy(dx: wall, dy: wall)
ctx.setFillColor(cream)
ctx.addPath(rounded(inside, 40))
ctx.fillPath()

// The gutter at the limit and the green pane below it.
let limitY = inside.maxY - inside.height * limit
let bar = CGRect(x: inside.minX - 1, y: limitY - gutter / 2, width: inside.width + 2, height: gutter)
ctx.setFillColor(brown)
ctx.fill(bar)
let pane = inside.insetBy(dx: gap, dy: gap)
ctx.setFillColor(green)
ctx.addPath(rounded(CGRect(x: pane.minX, y: bar.maxY + gap, width: pane.width, height: pane.maxY - bar.maxY - gap), 22))
ctx.fillPath()

guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL,
                                                        "public.png" as CFString, 1, nil)
else { fatalError("cannot write \(output)") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(output)") }
print("wrote \(output)")
