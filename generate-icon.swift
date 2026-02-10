#!/usr/bin/env swift

import AppKit
import CoreGraphics

let size: CGFloat = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Failed to create CGContext")
}

// --- Background: rounded rectangle, dark charcoal ---
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let cornerRadius: CGFloat = 220
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
ctx.setFillColor(CGColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1.0))
ctx.addPath(bgPath)
ctx.fillPath()

// Subtle gradient overlay for depth
let gradientColors = [
    CGColor(red: 0.18, green: 0.19, blue: 0.22, alpha: 1.0),
    CGColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1.0),
] as CFArray
if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 1.0]) {
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient,
        start: CGPoint(x: size / 2, y: size),
        end: CGPoint(x: size / 2, y: 0),
        options: [])
    ctx.restoreGState()
}

// --- Fork icon: centered, bold, white ---
let mid: CGFloat = size / 2
let baseY: CGFloat = 160
let forkY: CGFloat = 420
let topY: CGFloat = 830
let stemW: CGFloat = 220
let branchW: CGFloat = 180
let spread: CGFloat = 420

let lx = mid - spread / 2
let rx = mid + spread / 2

let shape = CGMutablePath()

// Bottom-left of stem, clockwise
shape.move(to: CGPoint(x: mid - stemW / 2, y: baseY))

// Left side of stem up to fork
shape.addLine(to: CGPoint(x: mid - stemW / 2, y: forkY))

// Left branch — outer edge
shape.addLine(to: CGPoint(x: lx - branchW / 2, y: forkY + 30))
shape.addLine(to: CGPoint(x: lx - branchW / 2, y: topY - 30))
// Rounded top of left branch
shape.addQuadCurve(to: CGPoint(x: lx + branchW / 2, y: topY - 30),
                   control: CGPoint(x: lx, y: topY + 30))
// Left branch — inner edge back down
shape.addLine(to: CGPoint(x: lx + branchW / 2, y: forkY + 30))

// Inner V gap
shape.addLine(to: CGPoint(x: rx - branchW / 2, y: forkY + 30))

// Right branch — inner edge up
shape.addLine(to: CGPoint(x: rx - branchW / 2, y: topY - 30))
// Rounded top of right branch
shape.addQuadCurve(to: CGPoint(x: rx + branchW / 2, y: topY - 30),
                   control: CGPoint(x: rx, y: topY + 30))
// Right branch — outer edge back down
shape.addLine(to: CGPoint(x: rx + branchW / 2, y: forkY + 30))

// Right side of stem back down
shape.addLine(to: CGPoint(x: mid + stemW / 2, y: forkY))
shape.addLine(to: CGPoint(x: mid + stemW / 2, y: baseY))

// Rounded bottom
shape.addQuadCurve(to: CGPoint(x: mid - stemW / 2, y: baseY),
                   control: CGPoint(x: mid, y: baseY - 40))
shape.closeSubpath()

// Draw fork with slight glow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 0), blur: 30,
              color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.15))
ctx.setFillColor(CGColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1.0))
ctx.addPath(shape)
ctx.fillPath()
ctx.restoreGState()

// --- Green status dot (bottom-right) ---
let dotSize: CGFloat = 200
let dotPadding: CGFloat = 110
let dotX = size - dotSize - dotPadding
let dotY = dotPadding
let dotRect = CGRect(x: dotX, y: dotY, width: dotSize, height: dotSize)

// Dot shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 0), blur: 20,
              color: CGColor(red: 0.35, green: 0.78, blue: 0.28, alpha: 0.6))
ctx.setFillColor(CGColor(red: 0.35, green: 0.78, blue: 0.28, alpha: 1.0))
ctx.fillEllipse(in: dotRect)
ctx.restoreGState()

// Dot highlight
let highlightSize = dotSize * 0.4
let highlightRect = CGRect(
    x: dotX + dotSize * 0.25,
    y: dotY + dotSize * 0.35,
    width: highlightSize,
    height: highlightSize
)
ctx.setFillColor(CGColor(red: 0.55, green: 0.90, blue: 0.50, alpha: 0.4))
ctx.fillEllipse(in: highlightRect)

// --- Export PNG ---
guard let cgImage = ctx.makeImage() else {
    fatalError("Failed to create CGImage")
}

let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
bitmapRep.size = NSSize(width: size, height: size)
guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to create PNG data")
}

let outputURL = URL(fileURLWithPath: "AppIcon.png")
try! pngData.write(to: outputURL)
print("Generated AppIcon.png (\(Int(size))x\(Int(size)))")
