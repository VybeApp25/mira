import AppKit

// MARK: - Geometry

struct NotchGeometry {
    let hasNotch:    Bool
    let notchWidth:  CGFloat
    let notchHeight: CGFloat
    /// Center of the notch's bottom edge in Cocoa screen coordinates (origin bottom-left).
    let notchCenter: CGPoint
    let screen:      NSScreen

    /// Full notch rect (x = left edge, y = bottom edge).
    var notchRect: CGRect {
        CGRect(
            x:      notchCenter.x - notchWidth / 2,
            y:      notchCenter.y,
            width:  notchWidth,
            height: notchHeight
        )
    }
}

// MARK: - Provider

enum NotchGeometryProvider {

    static func detect(for screen: NSScreen = .main ?? NSScreen.screens[0]) -> NotchGeometry {
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 {
            return realNotch(screen: screen)
        }
        return virtualNotch(screen: screen)
    }

    // MARK: Private

    private static func realNotch(screen: NSScreen) -> NotchGeometry {
        let h = screen.safeAreaInsets.top          // notch height (e.g. ~37 pt)
        let w = estimatedWidth(for: screen)
        // In Cocoa coords the notch bottom edge sits at screen.frame.maxY - h
        let bottomY = screen.frame.maxY - h
        return NotchGeometry(
            hasNotch:    true,
            notchWidth:  w,
            notchHeight: h,
            notchCenter: CGPoint(x: screen.frame.midX, y: bottomY),
            screen:      screen
        )
    }

    private static func virtualNotch(screen: NSScreen) -> NotchGeometry {
        // Synthesise a centred "notch" on menu-bar Macs without hardware notch.
        let w: CGFloat = 200
        let h: CGFloat = 37
        let bottomY = screen.frame.maxY - h
        return NotchGeometry(
            hasNotch:    false,
            notchWidth:  w,
            notchHeight: h,
            notchCenter: CGPoint(x: screen.frame.midX, y: bottomY),
            screen:      screen
        )
    }

    // MacBook Pro 14/16" notch ≈ 12.8 % of logical screen width; clamp to safe range.
    private static func estimatedWidth(for screen: NSScreen) -> CGFloat {
        (screen.frame.width * 0.128).clamped(to: 180 ... 252)
    }
}

private extension CGFloat {
    func clamped(to r: ClosedRange<CGFloat>) -> CGFloat {
        if self < r.lowerBound { return r.lowerBound }
        if self > r.upperBound { return r.upperBound }
        return self
    }
}
