import AppKit
import SwiftUI

// MARK: - Codex computer-use HUD (Autonomy slice 2)
//
// A live "watch Codex work" panel shown while CodexComputerUseService drives the
// Mac. Mirrors TeachingHUD's window pattern: a borderless, non-activating panel
// (so clicking Stop/Close never steals focus from the app Codex is controlling)
// pinned bottom-center, observing CodexComputerUseService.shared.
//
// Honesty in the UI: every line is a real event parsed from Codex's JSONL stream
// (thinking / tool call / tool result / message), not a synthetic "working…"
// placeholder. The panel stays up after the run so the final outcome is readable,
// and exposes the same Stop kill-switch the service already supports.

@MainActor
final class CodexHUD {
    static let shared = CodexHUD()
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
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 18)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: CodexHUDView())
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

private struct CodexHUDView: View {
    @ObservedObject private var service = CodexComputerUseService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.08))
            stream
            footer
        }
        .frame(width: 460, height: 360, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.10, green: 0.11, blue: 0.13).opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 12))
                .foregroundColor(miraViolet)
            Text(service.isRunning ? "Mira is controlling your Mac" : "Mira finished")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            if service.isRunning {
                HStack(spacing: 5) {
                    PulsingDot()
                    Text("LIVE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(miraTeale.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Step stream (newest at bottom, auto-scrolled)

    private var stream: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(service.steps) { step in
                        StepRow(step: step)
                            .id(step.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: service.steps.count) {
                if let last = service.steps.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Footer — Stop while running, Close once done

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            if service.isRunning {
                hudButton("Stop", tint: .white.opacity(0.5)) { service.stop() }
            } else {
                hudButton("Close", tint: miraTeale) { CodexHUD.shared.hide() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

// MARK: - Single step row

private struct StepRow: View {
    let step: CodexComputerUseService.Step

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(tint)
                .frame(width: 14)
            Text(step.text)
                .font(.system(size: 12, design: step.kind == .tool ? .monospaced : .default))
                .foregroundColor(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var icon: String {
        switch step.kind {
        case .thinking:   return "sparkles"
        case .tool:       return "cursorarrow.rays"
        case .toolResult: return "checkmark.circle"
        case .message:    return "text.bubble"
        case .system:     return "info.circle"
        case .refusal:    return "exclamationmark.shield.fill"
        }
    }

    private var tint: Color {
        switch step.kind {
        case .thinking:   return miraViolet
        case .tool:       return DS.Colors.accent
        case .toolResult: return miraTeale
        case .message:    return .white.opacity(0.7)
        case .system:     return .white.opacity(0.3)
        case .refusal:    return .orange
        }
    }

    private var textColor: Color {
        switch step.kind {
        case .message:  return .white.opacity(0.92)
        case .system:   return .white.opacity(0.4)
        case .refusal:  return .orange
        default:        return .white.opacity(0.75)
        }
    }
}

// MARK: - Pulsing activity dot

private struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(miraTeale)
            .frame(width: 6, height: 6)
            .scaleEffect(pulsing ? 1.4 : 1.0)
            .opacity(pulsing ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
