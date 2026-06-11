// DesignSystem.swift — ported from github.com/farzaa/clicky (MIT license)
import SwiftUI

// MARK: - Design System

enum DS {

    // MARK: Colors
    enum Colors {
        // Backgrounds
        static let background = Color(hex: "#101211")

        // Layered surfaces (dark → light)
        static let surface1   = Color(hex: "#171918")
        static let surface2   = Color(hex: "#202221")
        static let surface3   = Color(hex: "#272A29")
        static let surface4   = Color(hex: "#2E3130")

        // Borders
        static let borderSubtle = Color(hex: "#373B39")
        static let borderStrong = Color(hex: "#444947")

        // Text
        static let textPrimary   = Color(hex: "#ECEEED")
        static let textSecondary = Color(hex: "#ADB5B2")
        static let textTertiary  = Color(hex: "#6B736F")

        // Accent (blue-600)
        static let accent  = Color(hex: "#2563eb")
        // Hover / press state: slightly lighter
        static let accentHover = Color(hex: "#3B82F6")

        // Semantic
        static let success = Color(hex: "#34D399")
        static let warning = Color(hex: "#FFB224")
        static let error   = Color(hex: "#F87171")

        // Overlay
        static let overlay = Color.black.opacity(0.50)
    }

    // MARK: Corner Radii
    enum Radius {
        static let small:      CGFloat = 6
        static let medium:     CGFloat = 8
        static let large:      CGFloat = 10
        static let extraLarge: CGFloat = 12
        static let pill:       CGFloat = .infinity
    }

    // MARK: Animation Durations
    enum Animation {
        static let fast:   Double = 0.15
        static let normal: Double = 0.25
        static let slow:   Double = 0.40
    }
}

// MARK: - Composer Waveform Colors

enum BuddyComposerVisualStyle {
    static let waveformLeadingColor  = Color(hex: "#F3FBFF")
    static let waveformTrailingColor = Color(hex: "#8FD2FF")
    static let waveformGlowColor     = Color(hex: "#AEE3FF")
}

// MARK: - Button Styles

struct DSPrimaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                    .fill(configuration.isPressed
                          ? DS.Colors.accentHover
                          : (isHovered ? DS.Colors.accentHover : DS.Colors.accent))
                    .shadow(color: DS.Colors.accent.opacity(isHovered ? 0.45 : 0.28),
                            radius: isHovered ? 12 : 8, x: 0, y: 4)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeInOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerCursor()
    }
}

struct DSSecondaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                    .fill(configuration.isPressed
                          ? DS.Colors.surface3
                          : (isHovered ? DS.Colors.surface3 : DS.Colors.surface2))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeInOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerCursor()
    }
}

struct DSTertiaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                    .fill(configuration.isPressed || isHovered
                          ? DS.Colors.surface2
                          : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeInOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerCursor()
    }
}

struct DSTextButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(isHovered ? DS.Colors.accentHover : DS.Colors.accent)
            .opacity(configuration.isPressed ? 0.70 : 1.0)
            .animation(.easeInOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeInOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerCursor()
    }
}

struct DSOutlinedButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(isHovered ? DS.Colors.accentHover : DS.Colors.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                    .fill(configuration.isPressed || isHovered
                          ? DS.Colors.accent.opacity(0.10)
                          : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                            .stroke(isHovered ? DS.Colors.accentHover : DS.Colors.accent, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeInOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerCursor()
    }
}

struct DSDestructiveButtonStyle: ButtonStyle {
    private static let red = Color(hex: "#EF4444")
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                    .fill(configuration.isPressed || isHovered
                          ? Self.red.opacity(0.85)
                          : Self.red)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeInOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerCursor()
    }
}

struct DSIconButtonStyle: ButtonStyle {
    var tooltip: String? = nil
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(configuration.isPressed || isHovered
                          ? DS.Colors.surface3
                          : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .nativeTooltip(tooltip)
            .animation(.easeInOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeInOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = $0 }
            .pointerCursor()
    }
}

// MARK: - Pointer Cursor (AppKit Bridge)

private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PointerCursorNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

extension View {
    func pointerCursor() -> some View {
        overlay(PointerCursorView())
    }
}

// MARK: - I-Beam Cursor (AppKit Bridge)

private class IBeamCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct IBeamCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { IBeamCursorNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Native Tooltip

private struct NativeTooltipNSView: NSViewRepresentable {
    let tooltip: String
    func makeNSView(context: Context) -> NSView {
        let v = NSView(); v.toolTip = tooltip; return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.toolTip = tooltip }
}

extension View {
    func nativeTooltip(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            return AnyView(overlay(NativeTooltipNSView(tooltip: text)))
        }
        return AnyView(self)
    }
}

// MARK: - Color Hex Init

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
                   .replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        self.init(
            red:   Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >>  8) / 255.0,
            blue:  Double( rgb & 0x0000FF       ) / 255.0
        )
    }

    func blendedWithWhite(fraction: Double) -> Color {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return self }
        return Color(
            red:   c.redComponent   + (1 - c.redComponent)   * fraction,
            green: c.greenComponent + (1 - c.greenComponent) * fraction,
            blue:  c.blueComponent  + (1 - c.blueComponent)  * fraction
        )
    }
}
