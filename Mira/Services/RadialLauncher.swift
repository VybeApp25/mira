import Cocoa
import SwiftUI

// MARK: - RadialLauncherController
//
// Utility #3 of the "5 Mac apps" set: the radial ring app switcher from the reel.
// A full-screen overlay shows your running apps arranged in a circle; click one
// to switch to it. Opened from the App Launcher dock widget. Plan-gated: Pro = up
// to 8 apps in the ring, Ultra = unlimited. (Free keeps the basic launcher popover.)

@MainActor
final class RadialLauncherController {
    static let shared = RadialLauncherController()
    private init() {}

    private var window: NSWindow?

    var isOpen: Bool { window != nil }

    func toggle() { isOpen ? hide() : show() }

    func show() {
        guard window == nil, let screen = NSScreen.main else { return }
        let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque           = false
        win.backgroundColor    = .clear
        win.level              = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.hasShadow          = false
        win.contentView = NSHostingView(rootView: RadialLauncherView(onClose: { [weak self] in self?.hide() }))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - RadialLauncherView

struct RadialLauncherView: View {
    let onClose: () -> Void
    @ObservedObject private var ent = EntitlementService.shared

    private var apps: [NSRunningApplication] {
        let cap = ent.plan == .ultra ? Int.max : 8
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        return Array(running.prefix(cap))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
                .onTapGesture { onClose() }

            GeometryReader { geo in
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let items = apps
                let radius: CGFloat = items.count <= 6 ? 150 : 200

                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 2)
                        .frame(width: radius * 2 - 36, height: radius * 2 - 36)
                        .position(center)

                    ForEach(Array(items.enumerated()), id: \.offset) { idx, app in
                        let angle = (2 * Double.pi * Double(idx) / Double(max(items.count, 1))) - .pi / 2
                        Button {
                            app.activate()
                            onClose()
                        } label: {
                            tile(app)
                        }
                        .buttonStyle(.plain)
                        .position(x: center.x + radius * cos(angle),
                                  y: center.y + radius * sin(angle))
                    }

                    if items.isEmpty {
                        Text("No other apps running")
                            .font(.system(size: 13)).foregroundColor(.white.opacity(0.6))
                            .position(center)
                    }
                }
            }
        }
        .onExitCommand(perform: onClose)   // Esc dismisses
    }

    private func tile(_ app: NSRunningApplication) -> some View {
        VStack(spacing: 5) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 54, height: 54)
                    .shadow(color: .black.opacity(0.4), radius: 5, y: 2)
            }
            Text(app.localizedName ?? "")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 2)
        }
        .frame(width: 86)
    }
}
