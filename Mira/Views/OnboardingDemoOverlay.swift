import AppKit
import SwiftUI
import CoreGraphics

// Live demos shown during onboarding narration steps.
// Screen-guidance: full-screen transparent NSWindow with spotlight ring + annotation.
// Autonomy: smooth cursor animation via CGWarpMouseCursorPosition.

// MARK: - Coordinator

@MainActor
final class OnboardingDemoOverlay {
    static let shared = OnboardingDemoOverlay()
    private init() {}

    private var overlayWindow: NSWindow?

    // MARK: Screen Guidance

    func showScreenGuidanceDemo() async {
        guard let screen = NSScreen.main else { return }

        // Pick a point near center-left of screen for the spotlight
        let screenH = screen.frame.height
        // Target in NS coords (bottom-left origin): center-left area
        let targetNS = NSPoint(x: screen.frame.midX - 60, y: screen.frame.midY + 20)
        // Convert to CG / SwiftUI coords (top-left origin)
        let targetCG = CGPoint(x: targetNS.x, y: screenH - targetNS.y)

        let win = makeOverlayWindow(screen: screen)
        let view = ScreenGuidanceDemoView(targetPoint: targetCG, screenSize: screen.frame.size)
        win.contentView = NSHostingView(rootView: view)
        win.orderFront(nil)
        overlayWindow = win

        try? await Task.sleep(nanoseconds: 3_400_000_000)

        win.orderOut(nil)
        overlayWindow = nil
    }

    // MARK: Autonomy (cursor movement)

    func showAutonomyDemo() async {
        guard let screen = NSScreen.main else { return }
        let screenH = screen.frame.height

        // Show click-ripple overlay
        let rippleState = RippleState()
        let win = makeOverlayWindow(screen: screen)
        win.contentView = NSHostingView(rootView: CursorRippleOverlayView(state: rippleState, screenSize: screen.frame.size))
        win.orderFront(nil)
        overlayWindow = win

        // Save current position (NS → CG)
        let startNS  = NSEvent.mouseLocation
        let startCG  = CGPoint(x: startNS.x, y: screenH - startNS.y)

        // Three waypoints in CG coords (top-left origin)
        let cx = screen.frame.midX
        let cy = screenH / 2
        let waypoints: [(CGPoint, Bool)] = [
            (CGPoint(x: cx + 120,  y: cy - 60),  true),
            (CGPoint(x: cx - 160,  y: cy + 40),  true),
            (CGPoint(x: cx + 20,   y: cy + 110), true),
        ]

        var prev = startCG
        for (target, doClick) in waypoints {
            await moveCursor(from: prev, to: target, duration: 0.65)
            if doClick {
                rippleState.trigger(at: CGPoint(x: target.x, y: target.y))
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            prev = target
        }

        // Return to start
        await moveCursor(from: prev, to: startCG, duration: 0.8)
        try? await Task.sleep(nanoseconds: 200_000_000)

        win.orderOut(nil)
        overlayWindow = nil
    }

    // MARK: Helpers

    private func makeOverlayWindow(screen: NSScreen) -> NSWindow {
        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 20)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return win
    }

    private func moveCursor(from: CGPoint, to: CGPoint, duration: TimeInterval) async {
        let steps = 50
        let nsPerStep = UInt64((duration / Double(steps)) * 1_000_000_000)
        for i in 1...steps {
            let t    = Double(i) / Double(steps)
            let ease = t < 0.5 ? 2*t*t : -1+(4-2*t)*t  // ease-in-out quad
            let x    = from.x + (to.x - from.x) * ease
            let y    = from.y + (to.y - from.y) * ease
            CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
            try? await Task.sleep(nanoseconds: nsPerStep)
        }
        CGWarpMouseCursorPosition(to)
    }
}

// MARK: - Screen Guidance Overlay

struct ScreenGuidanceDemoView: View {
    let targetPoint: CGPoint
    let screenSize: CGSize

    @State private var ringScale:    CGFloat = 0.2
    @State private var ringOpacity:  Double  = 0
    @State private var labelOffset:  CGFloat = 16
    @State private var labelOpacity: Double  = 0
    @State private var pulse:        Bool    = false

    var body: some View {
        ZStack {
            // Light scrim
            Color.black.opacity(0.18)

            // Spotlight rings
            ZStack {
                // Outer pulse
                Circle()
                    .stroke(Color(red: 0.55, green: 0.38, blue: 1.0).opacity(0.30), lineWidth: 1.5)
                    .frame(width: 120, height: 120)
                    .scaleEffect(pulse ? 1.15 : 1.0)
                    .opacity(ringOpacity * 0.5)

                // Main ring
                Circle()
                    .stroke(Color(red: 0.55, green: 0.38, blue: 1.0), lineWidth: 2.5)
                    .frame(width: 76, height: 76)
                    .scaleEffect(ringScale)
                    .opacity(ringOpacity)

                // Inner fill
                Circle()
                    .fill(Color(red: 0.55, green: 0.38, blue: 1.0).opacity(0.12))
                    .frame(width: 76, height: 76)
                    .scaleEffect(ringScale)
                    .opacity(ringOpacity)
            }
            .position(x: targetPoint.x, y: targetPoint.y)

            // Annotation label
            HStack(spacing: 6) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 14, weight: .semibold))
                Text("I see this")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.55, green: 0.38, blue: 1.0))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            )
            .position(x: targetPoint.x, y: targetPoint.y - 68)
            .offset(y: labelOffset)
            .opacity(labelOpacity)
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .ignoresSafeArea()
        .onAppear { animate() }
    }

    private func animate() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.68).delay(0.05)) {
            ringScale   = 1.0
            ringOpacity = 1.0
        }
        withAnimation(.easeOut(duration: 0.35).delay(0.4)) {
            labelOpacity = 1.0
            labelOffset  = 0
        }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(0.5)) {
            pulse = true
        }
        // Fade out before window closes
        withAnimation(.easeIn(duration: 0.5).delay(2.7)) {
            ringOpacity  = 0
            labelOpacity = 0
        }
    }
}

// MARK: - Autonomy Click Ripple Overlay

@MainActor
final class RippleState: ObservableObject {
    struct Ripple: Identifiable {
        let id = UUID()
        let point: CGPoint
    }
    @Published var ripples: [Ripple] = []

    func trigger(at point: CGPoint) {
        let r = Ripple(point: point)
        ripples.append(r)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            ripples.removeAll { $0.id == r.id }
        }
    }
}

struct CursorRippleOverlayView: View {
    @ObservedObject var state: RippleState
    let screenSize: CGSize

    var body: some View {
        ZStack {
            ForEach(state.ripples) { ripple in
                RippleCircle()
                    .position(x: ripple.point.x, y: ripple.point.y)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .ignoresSafeArea()
    }
}

struct RippleCircle: View {
    @State private var scale:   CGFloat = 0.3
    @State private var opacity: Double  = 0.9

    var body: some View {
        Circle()
            .stroke(Color(red: 0.20, green: 0.85, blue: 0.60), lineWidth: 2)
            .frame(width: 40, height: 40)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.75)) {
                    scale   = 2.0
                    opacity = 0
                }
            }
    }
}
