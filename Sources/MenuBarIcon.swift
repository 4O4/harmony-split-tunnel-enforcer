import AppKit

enum MenuBarIcon {

    enum Status {
        case enforced       // green dot
        case fullTunnel     // red dot — catch-all routes active
        case connected      // yellow dot — VPN up, no catch-all
        case disconnected   // gray dot
    }

    static func forState(_ state: VPNState) -> NSImage {
        if state.splitActive { return build(.enforced) }
        if state.hasCatchAll { return build(.fullTunnel) }
        if state.connected { return build(.connected) }
        return build(.disconnected)
    }

    static func drawFork(ctx: CGContext, mid: CGFloat, baseY: CGFloat, forkY: CGFloat, topY: CGFloat, stemW: CGFloat, branchW: CGFloat, spread: CGFloat, curveScale: CGFloat = 1.0) {
        let lx = mid - spread / 2
        let rx = mid + spread / 2

        let shape = CGMutablePath()
        shape.move(to: CGPoint(x: mid - stemW / 2, y: baseY))
        shape.addLine(to: CGPoint(x: mid - stemW / 2, y: forkY))
        shape.addLine(to: CGPoint(x: lx - branchW / 2, y: forkY + curveScale))
        shape.addLine(to: CGPoint(x: lx - branchW / 2, y: topY - curveScale))
        shape.addQuadCurve(to: CGPoint(x: lx + branchW / 2, y: topY - curveScale),
                           control: CGPoint(x: lx, y: topY + curveScale))
        shape.addLine(to: CGPoint(x: lx + branchW / 2, y: forkY + curveScale))
        shape.addLine(to: CGPoint(x: rx - branchW / 2, y: forkY + curveScale))
        shape.addLine(to: CGPoint(x: rx - branchW / 2, y: topY - curveScale))
        shape.addQuadCurve(to: CGPoint(x: rx + branchW / 2, y: topY - curveScale),
                           control: CGPoint(x: rx, y: topY + curveScale))
        shape.addLine(to: CGPoint(x: rx + branchW / 2, y: forkY + curveScale))
        shape.addLine(to: CGPoint(x: mid + stemW / 2, y: forkY))
        shape.addLine(to: CGPoint(x: mid + stemW / 2, y: baseY))
        shape.addQuadCurve(to: CGPoint(x: mid - stemW / 2, y: baseY),
                           control: CGPoint(x: mid, y: baseY - curveScale * 1.5))
        shape.closeSubpath()

        ctx.addPath(shape)
        ctx.fillPath()
    }

    static func build(_ status: Status) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let baseColor = isDark ? NSColor.white : NSColor.black

            ctx.setFillColor(baseColor.cgColor)
            let mid: CGFloat = 8  // fork centered, dot overlaps at right edge

            let alpha: CGFloat = status == .disconnected ? 0.4 : 1.0
            ctx.setAlpha(alpha)

            // --- Bold chunky fork ---
            let baseY: CGFloat = 2.5
            let forkY: CGFloat = 7.5
            let topY: CGFloat = 15.0
            let stemW: CGFloat = 5.5
            let branchW: CGFloat = 4.5
            let spread: CGFloat = 9.0

            drawFork(ctx: ctx, mid: mid, baseY: baseY, forkY: forkY, topY: topY, stemW: stemW, branchW: branchW, spread: spread)

            // --- Status dot — match Harmony SASE style ---
            ctx.setAlpha(1.0)
            let dotSize: CGFloat = 7.0
            let dotX = size.width - dotSize - 1
            let dotY: CGFloat = 0.0

            let dotColor: NSColor
            switch status {
            case .enforced:     dotColor = NSColor(red: 0.35, green: 0.78, blue: 0.28, alpha: 1) // Harmony green
            case .fullTunnel:   dotColor = NSColor(red: 0.85, green: 0.25, blue: 0.25, alpha: 1)
            case .connected:    dotColor = NSColor(red: 0.95, green: 0.75, blue: 0.0, alpha: 1)
            case .disconnected: dotColor = NSColor.systemGray
            }

            ctx.setFillColor(dotColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: dotX, y: dotY, width: dotSize, height: dotSize))

            return true
        }
        image.isTemplate = false
        return image
    }
}

enum PopoverIcon {
    typealias Status = MenuBarIcon.Status

    static func build(status: Status) -> NSImage {
        let s: CGFloat = 36
        let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Dark rounded rect background
            let corner: CGFloat = s * 220.0 / 1024.0
            let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s), cornerWidth: corner, cornerHeight: corner, transform: nil)
            ctx.setFillColor(CGColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1.0))
            ctx.addPath(bgPath)
            ctx.fillPath()

            // Fork — scaled proportions matching app icon
            let alpha: CGFloat = status == .disconnected ? 0.4 : 1.0
            ctx.setAlpha(alpha)
            ctx.setFillColor(CGColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1.0))

            let scale = s / 1024.0
            MenuBarIcon.drawFork(
                ctx: ctx,
                mid: s / 2,
                baseY: 200 * scale,
                forkY: 440 * scale,
                topY: 830 * scale,
                stemW: 220 * scale,
                branchW: 180 * scale,
                spread: 420 * scale,
                curveScale: 30 * scale
            )

            // Status dot
            ctx.setAlpha(1.0)
            let dotSize: CGFloat = 9
            let dotX = s - dotSize - 3
            let dotY: CGFloat = 3

            let dotColor: CGColor
            switch status {
            case .enforced:     dotColor = CGColor(red: 0.35, green: 0.78, blue: 0.28, alpha: 1)
            case .fullTunnel:   dotColor = CGColor(red: 0.85, green: 0.25, blue: 0.25, alpha: 1)
            case .connected:    dotColor = CGColor(red: 0.95, green: 0.75, blue: 0.0, alpha: 1)
            case .disconnected: dotColor = NSColor.systemGray.cgColor
            }
            ctx.setFillColor(dotColor)
            ctx.fillEllipse(in: CGRect(x: dotX, y: dotY, width: dotSize, height: dotSize))

            return true
        }
        image.isTemplate = false
        return image
    }
}
