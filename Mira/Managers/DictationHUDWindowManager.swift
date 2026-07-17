import AppKit
import SwiftUI
import Combine

// MARK: - DictationHUDWindowManager
//
// A small "Dictating…" pill that appears just below the notch while ⌃⌥S is held,
// showing the live transcript as you speak (HeyClicky shows a "Dictating" chip;
// Mira shows the actual words landing). Pure display — ignores mouse events and
// never steals focus from the app you're dictating into.

@MainActor
final class DictationHUDWindowManager {
    static let shared = DictationHUDWindowManager()

    private var panel: NSPanel?
    private var cancellable: AnyCancellable?
    private var started = false

    private let panelWidth:  CGFloat = 340
    private let panelHeight: CGFloat = 44

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        // Order the pill in/out as dictation begins/ends.
        cancellable = DictationAnywhereService.shared.$isDictating
            .removeDuplicates()
            .sink { [weak self] active in
                MainActor.assumeIsolated { active ? self?.show() : self?.hide() }
            }
    }

    // MARK: - Panel

    private func show() {
        let panel = panel ?? buildPanel()
        self.panel = panel
        reposition(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    private func buildPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.level                = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 5)
        panel.backgroundColor      = .clear
        panel.isOpaque             = false
        panel.hasShadow            = false
        panel.ignoresMouseEvents   = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior   = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let host = NSHostingView(rootView: DictationHUDView())
        host.frame = CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// Center horizontally on the notch screen, tucked just under the menu bar.
    private func reposition(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - panelWidth / 2
        let y = visible.maxY - panelHeight - 6
        panel.setFrame(CGRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }
}

// MARK: - DictationHUDView

private struct DictationHUDView: View {
    @ObservedObject private var svc = DictationAnywhereService.shared
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(red: 0.98, green: 0.28, blue: 0.30))
                .frame(width: 8, height: 8)
                .scaleEffect(pulse ? 1.0 : 0.6)
                .opacity(pulse ? 1.0 : 0.5)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)

            Text(svc.livePreview.isEmpty ? "Dictating…" : svc.livePreview)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.white.opacity(svc.livePreview.isEmpty ? 0.55 : 0.95))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.94))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 6)
        .onAppear { pulse = true }
    }
}
