import AppKit

enum MenuBarIcon {

    enum Status {
        case enforced       // green dot
        case fullTunnel     // yellow dot
        case disconnected   // red dot
    }

    static func forState(_ state: VPNState) -> NSImage {
        if state.splitActive { return build(.enforced) }
        if state.hasCatchAll { return build(.fullTunnel) }
        return build(.disconnected)
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

            let lx = mid - spread / 2
            let rx = mid + spread / 2

            // Build as one solid shape for maximum boldness
            let shape = CGMutablePath()

            // Start from bottom-left of stem, go clockwise
            shape.move(to: CGPoint(x: mid - stemW / 2, y: baseY))

            // Left side of stem up to fork point
            shape.addLine(to: CGPoint(x: mid - stemW / 2, y: forkY))

            // Left branch — outer edge going up-left
            shape.addLine(to: CGPoint(x: lx - branchW / 2, y: forkY + 1))
            shape.addLine(to: CGPoint(x: lx - branchW / 2, y: topY - 1))
            // Rounded top of left branch
            shape.addQuadCurve(to: CGPoint(x: lx + branchW / 2, y: topY - 1),
                               control: CGPoint(x: lx, y: topY + 1))
            // Left branch — inner edge going back down
            shape.addLine(to: CGPoint(x: lx + branchW / 2, y: forkY + 1))

            // Gap between branches (inner V)
            shape.addLine(to: CGPoint(x: rx - branchW / 2, y: forkY + 1))

            // Right branch — inner edge going up
            shape.addLine(to: CGPoint(x: rx - branchW / 2, y: topY - 1))
            // Rounded top of right branch
            shape.addQuadCurve(to: CGPoint(x: rx + branchW / 2, y: topY - 1),
                               control: CGPoint(x: rx, y: topY + 1))
            // Right branch — outer edge going back down
            shape.addLine(to: CGPoint(x: rx + branchW / 2, y: forkY + 1))

            // Right side of stem back down
            shape.addLine(to: CGPoint(x: mid + stemW / 2, y: forkY))
            shape.addLine(to: CGPoint(x: mid + stemW / 2, y: baseY))

            // Rounded bottom of stem
            shape.addQuadCurve(to: CGPoint(x: mid - stemW / 2, y: baseY),
                               control: CGPoint(x: mid, y: baseY - 1.5))
            shape.closeSubpath()

            ctx.addPath(shape)
            ctx.fillPath()

            // --- Status dot — match Harmony SASE style ---
            ctx.setAlpha(1.0)
            let dotSize: CGFloat = 7.0
            let dotX = size.width - dotSize
            let dotY: CGFloat = 0.0

            let dotColor: NSColor
            switch status {
            case .enforced:    dotColor = NSColor(red: 0.35, green: 0.78, blue: 0.28, alpha: 1) // Harmony green
            case .fullTunnel:  dotColor = NSColor(red: 0.95, green: 0.75, blue: 0.0, alpha: 1)
            case .disconnected: dotColor = NSColor(red: 0.85, green: 0.25, blue: 0.25, alpha: 1)
            }

            ctx.setFillColor(dotColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: dotX, y: dotY, width: dotSize, height: dotSize))

            return true
        }
        image.isTemplate = false
        return image
    }
}
