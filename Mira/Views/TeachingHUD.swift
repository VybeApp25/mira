import AppKit
import SwiftUI

// MARK: - Teaching HUD (Teaching System M2)
//
// A small bottom-center panel that presents the current step. It's a
// non-activating panel so tapping its buttons never steals focus from the app
// the user is learning. Observes TeachingEngine.shared.
//
// Honesty in the UI: a "Done" button appears ONLY for steps Mira cannot observe
// (`.userConfirmation`). Observable steps show "Watching…" and advance on their
// own when the real state changes — the user is never asked to self-certify them.

@MainActor
final class TeachingHUD {
    static let shared = TeachingHUD()
    private init() {}

    private var panel: NSPanel?

    func show() {
        if panel == nil { build() }
        position()
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func build() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 150),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 18)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: TeachingHUDView())
        panel = p
    }

    private func position() {
        guard let p = panel, let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let size = p.frame.size
        p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 60))
    }
}

// MARK: - View

private struct TeachingHUDView: View {
    @ObservedObject private var engine = TeachingEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "graduationcap.fill")
                    .foregroundColor(miraTeale)
                    .font(.system(size: 12))
                Text(engine.skill?.title ?? "Lesson")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                if engine.phase == .running, engine.totalSteps > 0 {
                    Text("Step \(engine.stepIndex + 1) of \(engine.totalSteps)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            Text(engine.instruction)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)

            // Always reserve the status-line row so the button row below never
            // shifts when remediation text appears (kept the Done button steady).
            Text(engine.statusLine.isEmpty ? " " : engine.statusLine)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(engine.statusLine.isEmpty ? 0 : 0.45))
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 14, alignment: .leading)

            if engine.automatedInputDetected {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Text("Automated input detected — I won't advance on automated clicks. Use a real mouse, or Stop if you didn't start this.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6).padding(.horizontal, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.orange.opacity(0.12)))
            }

            HStack(spacing: 8) {
                if engine.phase == .running, !engine.canConfirm {
                    // Observable step — Mira advances it itself; no self-certify button.
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Watching…").font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                    }
                }
                Spacer()
                if engine.canSkip {
                    hudButton("Skip", tint: .white.opacity(0.5)) { engine.skipStep() }
                }
                if engine.canConfirm {
                    hudButton("Done", tint: miraTeale) { engine.confirmStep() }
                }
                hudButton("Stop", tint: .white.opacity(0.4)) { engine.stop() }
            }
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.10, green: 0.11, blue: 0.13).opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    private func hudButton(_ title: String, tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(tint == miraTeale ? .black.opacity(0.85) : tint)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint == miraTeale ? miraTeale : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }
}
