// NotificationsModule.swift
// MacNotch's Notifications module: your alerts, centred in the notch. Scored ❌
// in the audit — UNUserNotification appeared in four files but all of them were
// Mira POSTING its own notifications, never reading the system's.
//
// Reads Notification Center's accessibility tree. Probed against the live
// process before writing any of this, because the shape is not documented:
//
//   com.apple.notificationcenterui
//     └ AXWindow "Notification Center"
//         └ AXGroup → AXGroup → AXScrollArea
//             └ AXGroup            (the stack)
//                 └ AXGroup        (one notification)
//                      description = "App, Title, Subtitle, Body"
//
// That description is the only text carried — there are no separate title/body
// attributes — so parsing splits on ", " and takes the first component as the
// app. A body containing a comma will over-split; that is a display nuisance,
// not a correctness problem, and inventing structure that isn't there would be
// worse.
//
// NOT IMPLEMENTED: inline reply. MacNotch offers it, and it would mean locating
// and driving a text field inside another process's UI, then hitting its send
// button — the kind of thing that breaks silently on a macOS point release and
// posts a half-typed message when it does. Reading is safe; writing into
// someone else's notification is not, and I would rather ship the read half
// honestly than a reply that fails in a way you only notice later.

import SwiftUI
import AppKit
import ApplicationServices
import Combine

// MARK: - Model

struct SystemNotification: Identifiable, Equatable {
    let id: String
    let app: String
    let message: String

    /// SF Symbol guessed from the posting app, so the list scans by source.
    var icon: String {
        let a = app.lowercased()
        switch true {
        case a.contains("message"), a.contains("mail"):    return "envelope.fill"
        case a.contains("calendar"), a.contains("remind"): return "calendar"
        case a.contains("slack"), a.contains("discord"):   return "bubble.left.fill"
        case a.contains("privacy"), a.contains("security"):return "lock.shield.fill"
        case a.contains("music"), a.contains("podcast"):   return "music.note"
        case a.contains("xcode"), a.contains("script"):    return "hammer.fill"
        default:                                            return "bell.fill"
        }
    }
}

// MARK: - Service

@MainActor
final class SystemNotificationsService: ObservableObject {

    static let shared = SystemNotificationsService()

    @Published private(set) var notifications: [SystemNotification] = []
    @Published private(set) var isTrusted = AXIsProcessTrusted()

    private var timer: Timer?
    private init() {}

    func start() {
        guard timer == nil else { return }
        refresh()
        // Notification Center's tree only changes when something arrives or is
        // dismissed; 3s is responsive without walking another process's AX tree
        // constantly.
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        isTrusted = AXIsProcessTrusted()
        guard isTrusted else { notifications = []; return }

        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.notificationcenterui"
        }) else {
            notifications = []
            return
        }

        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var found: [SystemNotification] = []
        for window in Self.attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            Self.collect(window, into: &found, depth: 0)
        }
        // Only publish on change — reassigning identical content every 3s would
        // redraw the list and fight scrolling.
        if found != notifications { notifications = found }
    }

    /// Walks for AXGroups carrying a description. Those are the notifications;
    /// structural groups have none.
    private static func collect(_ el: AXUIElement,
                                into out: inout [SystemNotification],
                                depth: Int) {
        guard depth < 10 else { return }

        if let role = attr(el, kAXRoleAttribute) as? String, role == kAXGroupRole as String,
           let desc = attr(el, kAXDescriptionAttribute) as? String,
           !desc.trimmingCharacters(in: .whitespaces).isEmpty {

            let parts = desc.components(separatedBy: ", ")
            let app = parts.first ?? "Notification"
            let message = parts.dropFirst().joined(separator: ", ")
            if !message.isEmpty {
                // Description doubles as identity: Notification Center exposes no
                // stable id, and identical text from the same app IS the same
                // alert for display purposes.
                out.append(SystemNotification(id: desc, app: app, message: message))
                return   // don't descend into a notification's own subtree
            }
        }

        for child in attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            collect(child, into: &out, depth: depth + 1)
        }
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    /// Opens Notification Center so the user can act on or clear an alert.
    /// Mira does not dismiss other apps' notifications itself — that is a
    /// destructive action on something it does not own.
    func openNotificationCentre() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/NotificationCenter.app"))
    }
}

// MARK: - Module

@MainActor
final class NotificationsModule: NotchModule, ObservableObject {

    let id    = "notifications"
    let title = "Notifications"
    let icon  = "bell.fill"

    let heightLevel: NotchHeightLevel = .tall
    let allowsTallMode = false

    private let service = SystemNotificationsService.shared
    private var cancellables = Set<AnyCancellable>()

    var subtitle: NotchHeaderSubtitle? {
        let n = service.notifications.count
        guard n > 0 else { return nil }
        return NotchHeaderSubtitle(text: "\(n)", isPill: true)
    }

    var headerAccessories: [NotchHeaderAccessory] {
        [NotchHeaderAccessory(id: "refresh", systemImage: "arrow.clockwise",
                              label: "Refresh notifications") { [weak self] in
            self?.service.refresh()
        }]
    }

    init() {
        service.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func didAppear()    { service.start() }
    func didDisappear() { service.stop() }

    func makeContent() -> AnyView { AnyView(NotificationsView(service: service)) }
}

// MARK: - View

private struct NotificationsView: View {

    @ObservedObject var service: SystemNotificationsService
    @ObservedObject private var accentSvc = AccentColorService.shared

    private var accent: Color { accentSvc.color }

    var body: some View {
        Group {
            if !service.isTrusted {
                permissionPrompt
            } else {
                list
            }
        }
        .padding(.top, NotchModuleShellView.headerHeight)
        .background(Color.black)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(service.notifications) { note in
                    row(note)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .overlay {
            if service.notifications.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.22))
                    Text("No notifications")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.50))
                }
            }
        }
    }

    private func row(_ note: SystemNotification) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: note.icon)
                .font(.system(size: 12))
                .foregroundColor(accent.opacity(0.85))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(note.app)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Text(note.message)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(0.05)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(note.app): \(note.message)")
    }

    private var permissionPrompt: some View {
        VStack(spacing: 5) {
            Image(systemName: "lock")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.30))
            Text("Accessibility access needed")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
            Text("Reading notifications means reading Notification Center's accessibility tree.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
