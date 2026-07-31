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
    /// Sender or headline, when the source gives one separately from the body.
    /// The accessibility path has no such split, so it passes an empty string.
    var title: String = ""
    var bundleID: String = ""
    var deliveredAt: Date?

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
    private init() { loadCleared() }

    /// Poll for arrivals.
    ///
    /// Runs from app launch and NEVER stops while Mira is running. An earlier
    /// version stopped it in the module's didDisappear, which meant Mira watched
    /// for notifications only while you had the Notifications panel open — the
    /// exact opposite of what the feature is for. Nothing popped on the closed
    /// notch because nothing was looking.
    func start(interval: TimeInterval = 2) {
        // Restart rather than bail, so a cadence change takes effect.
        timer?.invalidate()
        refresh()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// True when the database is readable — i.e. Mira has Full Disk Access.
    /// Published so the panel can say which source it is on and what is missing.
    @Published private(set) var hasDatabaseAccess = false

    func refresh() {
        isTrusted = AXIsProcessTrusted()
        hasDatabaseAccess = NotificationCenterStore.isReadable

        // The database FIRST. It is the record of what was actually delivered,
        // where the accessibility tree only ever shows a banner while it happens
        // to be on screen — on this Mac that window was so short, and so often
        // absent entirely, that the AX path returned nothing while texts were
        // demonstrably arriving.
        if hasDatabaseAccess {
            let fromDatabase = NotificationCenterStore.recent()
            if !fromDatabase.isEmpty {
                ingest(fromDatabase)
                return
            }
        }

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
        ingest(found)
    }

    private func ingest(_ found: [SystemNotification]) {
        // Work out what is NEW before publishing, so the collapsed notch can pop
        // an arrival rather than only ever showing a static count. The AX tree
        // is a snapshot of what Notification Center is holding, so "new" is
        // simply an id we have not seen in a previous snapshot.
        // Cleared items never pop, even if the source re-reports them. Clearing
        // is a statement about attention, and re-interrupting with something the
        // user has already dismissed is the fastest way to make them turn the
        // whole feature off.
        let incoming = found.filter { !seenIDs.contains($0.id) && isVisible($0) }

        // The first pass after launch seeds the seen set WITHOUT popping.
        // Everything already delivered is new to us but old to the user, and
        // opening a laptop to a three-hour-old text taking over the notch would
        // be worse than not having the feature.
        if hasSeeded {
            // Newest wins. The database returns newest-first while the
            // accessibility walk returns tree order, so picking positionally
            // would pop the wrong one depending on which source answered.
            let arrival = incoming
                .max { ($0.deliveredAt ?? .distantPast) < ($1.deliveredAt ?? .distantPast) }
                ?? incoming.first
            if let arrival {
                latest = arrival
                latestAt = Date()
            }
        } else {
            hasSeeded = true
        }
        // Keep the seen set to the ids still present plus what just arrived, so
        // it can't grow without bound over a long uptime — and so a notification
        // that is dismissed and posted again counts as new, which it is.
        seenIDs = Set(found.map(\.id))

        // Only publish on change — reassigning identical content every 3s would
        // redraw the list and fight scrolling.
        if found != notifications { notifications = found }
    }

    /// The most recent arrival, and when we noticed it. The collapsed strip uses
    /// the timestamp to decide whether this is still worth interrupting for.
    @Published private(set) var latest: SystemNotification?
    @Published private(set) var latestAt: Date?

    private var seenIDs: Set<String> = []
    private var hasSeeded = false

    // MARK: - Clearing
    //
    // Mira CANNOT dismiss another app's notification from macOS. There is no
    // API for it — UNUserNotificationCenter only removes what your own app
    // posted — and the alternative, deleting rows from Notification Center's
    // database, is both blocked by TCC and a fine way to corrupt a system file
    // that a daemon has open. Clicking the notification in Notification Center
    // is still the only thing that clears it system-wide.
    //
    // So clearing here is Mira's own view of the list. That is genuinely what
    // was needed: the source is a rolling log of everything delivered, so
    // without this the panel shows the same backlog forever and a new arrival
    // is just one more line in it.

    /// Everything delivered at or before this is hidden. One timestamp handles
    /// "clear all" no matter how large the backlog, where storing every id
    /// would grow without bound.
    @Published private(set) var clearedBefore: Date?

    /// Individually dismissed items delivered after the watermark.
    @Published private(set) var clearedIDs: Set<String> = []

    private let clearedBeforeKey = "mira_notifications_cleared_before_v1"
    private let clearedIDsKey    = "mira_notifications_cleared_ids_v1"

    /// What the panel and the collapsed count should actually use.
    var visibleNotifications: [SystemNotification] {
        notifications.filter { isVisible($0) }
    }

    func isVisible(_ note: SystemNotification) -> Bool {
        if clearedIDs.contains(note.id) { return false }
        if let clearedBefore, let delivered = note.deliveredAt, delivered <= clearedBefore {
            return false
        }
        return true
    }

    func clear(_ note: SystemNotification) {
        clearedIDs.insert(note.id)
        persistCleared()
    }

    func clearAll() {
        // Watermark at the newest thing we can see rather than at `now`, so a
        // notification that lands in the same second as the tap isn't silently
        // swallowed by it.
        let newest = notifications.compactMap(\.deliveredAt).max()
        clearedBefore = newest ?? Date()
        clearedIDs.removeAll()
        persistCleared()
    }

    /// Bring the backlog back. Nothing was destroyed — the source still has
    /// everything — so undoing a clear costs one line.
    func restoreCleared() {
        clearedBefore = nil
        clearedIDs.removeAll()
        persistCleared()
    }

    var hasCleared: Bool { clearedBefore != nil || !clearedIDs.isEmpty }

    private func persistCleared() {
        let defaults = UserDefaults.standard
        if let clearedBefore {
            defaults.set(clearedBefore.timeIntervalSince1970, forKey: clearedBeforeKey)
        } else {
            defaults.removeObject(forKey: clearedBeforeKey)
        }
        // Only ids newer than the watermark are worth keeping; the rest are
        // already covered by it.
        let pruned = clearedIDs.filter { id in
            guard let clearedBefore,
                  let match = notifications.first(where: { $0.id == id }),
                  let delivered = match.deliveredAt else { return true }
            return delivered > clearedBefore
        }
        clearedIDs = pruned
        defaults.set(Array(pruned), forKey: clearedIDsKey)
    }

    private func loadCleared() {
        let defaults = UserDefaults.standard
        if let stamp = defaults.object(forKey: clearedBeforeKey) as? Double {
            clearedBefore = Date(timeIntervalSince1970: stamp)
        }
        clearedIDs = Set(defaults.stringArray(forKey: clearedIDsKey) ?? [])
    }

    /// How long a new notification holds the closed notch before it drops back
    /// to a count. Long enough to read a line, short enough that walking away
    /// from the Mac doesn't leave it pinned there.
    static let popDuration: TimeInterval = 10

    var isPopping: Bool {
        guard let latestAt else { return false }
        return Date().timeIntervalSince(latestAt) < Self.popDuration
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

    var headerAccessories: [NotchHeaderAccessory] {
        var out: [NotchHeaderAccessory] = []

        if !service.visibleNotifications.isEmpty {
            out.append(NotchHeaderAccessory(id: "clearAll",
                                            systemImage: "xmark.bin",
                                            label: "Clear all — hides them here, "
                                                 + "they stay in Notification Center") { [weak self] in
                self?.service.clearAll()
            })
        }

        // Only offered while there is something to bring back, so it isn't a
        // permanent button that usually does nothing.
        if service.hasCleared {
            out.append(NotchHeaderAccessory(id: "restore",
                                            systemImage: "arrow.uturn.backward",
                                            label: "Show cleared notifications again") { [weak self] in
                self?.service.restoreCleared()
            })
        }

        out.append(NotchHeaderAccessory(id: "refresh", systemImage: "arrow.clockwise",
                                        label: "Refresh notifications") { [weak self] in
            self?.service.refresh()
        })
        return out
    }

    var subtitle: NotchHeaderSubtitle? {
        let count = service.visibleNotifications.count
        if count == 0 { return service.hasCleared ? NotchHeaderSubtitle(text: "cleared") : nil }
        return NotchHeaderSubtitle(text: count == 1 ? "1 new" : "\(count) new")
    }

    init() {
        service.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // Faster while the panel is on screen, back to the background cadence when
    // it isn't — but never stopped. Stopping is what broke the pop.
    func didAppear()    { service.start(interval: 1.5) }
    func didDisappear() { service.start(interval: 2) }

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
                ForEach(service.visibleNotifications) { note in
                    row(note)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .overlay {
            if service.visibleNotifications.isEmpty, !service.hasDatabaseAccess {
                // The shared prompt, not a bespoke one. Every feature that is
                // blocked on a grant should ask the same way, or the user learns
                // a different affordance per panel.
                PermissionPromptView(
                    permission: .fullDisk,
                    detail: "Notifications are delivered to a database only Full Disk Access can "
                          + "read. Banners are on screen for a moment and often not at all, so "
                          + "watching for them misses most of what arrives.")
            } else if service.visibleNotifications.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.22))
                    // Distinguishes an empty inbox from one you emptied. The
                    // second has an undo and the first does not, and saying
                    // "No notifications" for both hides that.
                    Text(service.hasCleared ? "All clear" : "No notifications")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.50))
                    if service.hasCleared {
                        Text("Cleared here — still in Notification Center")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.30))
                    }
                }
            }
        }
    }

    private func row(_ note: SystemNotification) -> some View {
        NotificationRow(note: note, accent: accent) { service.clear(note) }
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

// MARK: - Row

private struct NotificationRow: View {

    let note: SystemNotification
    let accent: Color
    let onClear: () -> Void

    @State private var hovering = false

    var body: some View {
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

            // Revealed on hover rather than always drawn: a column of crosses
            // down a list of messages reads as a list of things to delete,
            // which is not what a notification list is for.
            if hovering {
                Button(action: onClear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .help("Clear from Mira")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.08 : 0.05)))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(note.app): \(note.message)")
    }
}
