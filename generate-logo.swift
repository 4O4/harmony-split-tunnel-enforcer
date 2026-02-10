#!/usr/bin/env swift

import AppKit
import CoreGraphics
import CoreText

let width: CGFloat = 800
let height: CGFloat = 200
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(
    data: nil,
    width: Int(width),
    height: Int(height),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Failed to create CGContext")
}

// --- Dark rounded-rect background ---
let bgRect = CGRect(x: 0, y: 0, width: width, height: height)
let bgCorner: CGFloat = 24
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: bgCorner, cornerHeight: bgCorner, transform: nil)
ctx.setFillColor(CGColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1.0))
ctx.addPath(bgPath)
ctx.fillPath()

// --- Fork icon on the left (scaled to ~140x140, centered vertically) ---
let iconSize: CGFloat = 140
let iconX: CGFloat = 30
let iconY: CGFloat = (height - iconSize) / 2

// Draw icon background rounded rect (matching app icon shape)
let iconRect = CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
let iconCorner: CGFloat = iconSize * 220.0 / 1024.0  // same ratio as app icon
let iconBgPath = CGPath(roundedRect: iconRect, cornerWidth: iconCorner, cornerHeight: iconCorner, transform: nil)
ctx.setFillColor(CGColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1.0))
ctx.addPath(iconBgPath)
ctx.fillPath()

// Draw fork shape inside the circle
let scale = iconSize / 1024.0
let offsetX = iconX
let offsetY = iconY

func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: offsetX + x * scale, y: offsetY + y * scale)
}

let mid: CGFloat = 512
let baseY: CGFloat = 200
let forkY: CGFloat = 440
let topY: CGFloat = 830
let stemW: CGFloat = 220
let branchW: CGFloat = 180
let spread: CGFloat = 420
let lx = mid - spread / 2
let rx = mid + spread / 2

let shape = CGMutablePath()
shape.move(to: pt(mid - stemW / 2, baseY))
shape.addLine(to: pt(mid - stemW / 2, forkY))
shape.addLine(to: pt(lx - branchW / 2, forkY + 30))
shape.addLine(to: pt(lx - branchW / 2, topY - 30))
shape.addQuadCurve(to: pt(lx + branchW / 2, topY - 30), control: pt(lx, topY + 30))
shape.addLine(to: pt(lx + branchW / 2, forkY + 30))
shape.addLine(to: pt(rx - branchW / 2, forkY + 30))
shape.addLine(to: pt(rx - branchW / 2, topY - 30))
shape.addQuadCurve(to: pt(rx + branchW / 2, topY - 30), control: pt(rx, topY + 30))
shape.addLine(to: pt(rx + branchW / 2, forkY + 30))
shape.addLine(to: pt(mid + stemW / 2, forkY))
shape.addLine(to: pt(mid + stemW / 2, baseY))
shape.addQuadCurve(to: pt(mid - stemW / 2, baseY), control: pt(mid, baseY - 40))
shape.closeSubpath()

ctx.setFillColor(CGColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1.0))
ctx.addPath(shape)
ctx.fillPath()

// Green dot
let dotSize: CGFloat = 28
let dotX = iconX + iconSize - dotSize - 8
let dotY2 = iconY + 8
ctx.setFillColor(CGColor(red: 0.35, green: 0.78, blue: 0.28, alpha: 1.0))
ctx.fillEllipse(in: CGRect(x: dotX, y: dotY2, width: dotSize, height: dotSize))

// --- Text ---
let textX: CGFloat = iconX + iconSize + 24
let white = NSColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1.0)
let green = NSColor(red: 0.45, green: 0.82, blue: 0.40, alpha: 1.0)
let subdued = NSColor(red: 0.55, green: 0.56, blue: 0.58, alpha: 1.0)

let titleFont = CTFontCreateWithName("SF Pro Display Bold" as CFString, 40, nil)
let smallFont = CTFontCreateWithName("SF Pro Display Medium" as CFString, 24, nil)

let greenAttrs: [NSAttributedString.Key: Any] = [
    .font: titleFont,
    .foregroundColor: green,
]
let whiteAttrs: [NSAttributedString.Key: Any] = [
    .font: titleFont,
    .foregroundColor: white,
]
let subduedAttrs: [NSAttributedString.Key: Any] = [
    .font: smallFont,
    .foregroundColor: subdued,
]

// Line 1: "Split Tunnel Enforcer" (Split Tunnel in green, Enforcer in white)
let line1 = NSMutableAttributedString(string: "Split Tunnel ", attributes: greenAttrs)
line1.append(NSAttributedString(string: "Enforcer", attributes: whiteAttrs))
let ctLine1 = CTLineCreateWithAttributedString(line1)

// Line 2: "for Harmony SASE" (subdued)
let line2 = NSAttributedString(string: "for Harmony", attributes: subduedAttrs)
let ctLine2 = CTLineCreateWithAttributedString(line2)

let textCenterY = height / 2
let line1Y = textCenterY + 10
let line2Y = textCenterY - 36

ctx.textPosition = CGPoint(x: textX, y: line1Y)
CTLineDraw(ctLine1, ctx)

ctx.textPosition = CGPoint(x: textX, y: line2Y)
CTLineDraw(ctLine2, ctx)

// --- Export PNG ---
guard let cgImage = ctx.makeImage() else {
    fatalError("Failed to create CGImage")
}

let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
bitmapRep.size = NSSize(width: width, height: height)
guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to create PNG data")
}

let outputURL = URL(fileURLWithPath: "logo.png")
try! pngData.write(to: outputURL)
print("Generated logo.png (\(Int(width))x\(Int(height)))")
