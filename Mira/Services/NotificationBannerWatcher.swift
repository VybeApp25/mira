// NotificationBannerWatcher.swift
// Watches Notification Center's banner window, reads each alert the instant it is
// posted, and — when the user asks for it — parks that window off screen so the
// native banner never appears and the notch shows it instead.
//
// WHY THIS EXISTS, and why it replaces the database as the PRIMARY source.
//
// NotificationsModule reads `usernoted`'s database, which is a real record of
// what was delivered and survives a relaunch. But it has two limits that only
// showed up once it was measured against what is actually on screen:
//
//   1. IT DOES NOT CONTAIN iPHONE NOTIFICATIONS. Counted directly: the database
//      holds 91 records across 8 apps, all of them Mac apps, while Notification
//      Center was at that moment displaying alerts from X, Vivint, myQ and
//      CapCut. Searching the whole `app` table for those returns ZERO rows.
//      Continuity-mirrored alerts are shown by Notification Center without ever
//      being written to this store. An earlier comment of mine in
//      LiveActivityService claimed the opposite — that iPhone notifications
//      "appear here without anything extra". That was wrong, and it is corrected
//      there now.
//
//   2. IT IS LATE. The write is not synchronous with the banner; polling it
//      measured 5-10s behind the alert. For the one source in the notch that is
//      time-critical, that is late enough to be useless.
//
// The accessibility tree has neither problem: it is the thing being drawn, so it
// is exact and immediate, and it carries mirrored alerts because Notification
// Center draws those too. The database stays as history — it is the only source
// that outlives Mira's own process.
//
// A NOTE ON A PREVIOUS WRONG CONCLUSION. NotificationsModule's header says
// banners are not observable over accessibility and that the AX path "returns
// nothing, ever". That is false, and the corrected header there says so. Banners
// carry subrole AXNotificationCenterBanner with `title`/`subtitle`/`body`
// children; the original probe simply ran when no banner happened to be on
// screen, and a window-created observer removes the guesswork entirely.
//
// SUPPRESSION. macOS offers no API to stop another app's banner. The two real
// options are a Focus mode — which suppresses system-wide, changes a setting
// Mira does not own, and would keep suppressing if Mira died — or moving the
// banner window off screen, which is what this does. The window is transient and
// recreated per banner, so nothing is left in a bad state: if Mira quits, is
// killed, or loses Accessibility, the very next banner is drawn normally. That
// property is the reason for this choice over Focus.

import AppKit
import ApplicationServices
import Combine

@MainActor
final class NotificationBannerWatcher: ObservableObject {

    static let shared = NotificationBannerWatcher()

    /// Hide native banners and show them only in the notch.
    ///
    /// Off by default. Suppressing the system's own alerts is a big claim to make
    /// on a user's behalf, and it is only honest once they have seen Mira catch
    /// them — so it is opt-in, and turning it off takes effect on the next banner.
    @Published var suppressBanners: Bool = UserDefaults.standard.bool(forKey: suppressKey) {
        didSet {
            guard oldValue != suppressBanners else { return }
            UserDefaults.standard.set(suppressBanners, forKey: Self.suppressKey)
        }
    }

    private static let suppressKey = "mira_hide_system_banners_v1"

    /// True once the observer is attached to a live Notification Center.
    @Published private(set) var isWatching = false

    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var appElement: AXUIElement?

    /// Banner identifiers already handed to the service, so a stack that stays on
    /// screen across several sweeps is reported once.
    private var seen: [String: Date] = [:]

    /// Runs only while a banner window exists. A window-created event fires for
    /// the FIRST banner; a second alert arriving while that window is still up is
    /// added to the existing window and produces no event at all, so it would be
    /// missed entirely without this.
    private var sweepTimer: Timer?

    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: - Lifecycle

    func start() {
        attach()

        // Notification Center is restarted by the system often enough to matter —
        // a crash, a logout/login, `killall NotificationCenter`. Without this the
        // watcher would go quiet for the rest of the session with no sign.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            center.publisher(for: name)
                .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
                .filter { $0.bundleIdentifier == Self.notificationCenterBundleID }
                .sink { [weak self] _ in
                    // A small delay: on launch the process exists before its
                    // accessibility server is answering.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.attach() }
                }
                .store(in: &cancellables)
        }

        // Accessibility can be granted after launch, and the observer cannot be
        // created before it is. Retry until it takes, then stop.
        if !isWatching {
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
                Task { @MainActor in
                    guard let self else { t.invalidate(); return }
                    if self.isWatching { t.invalidate() } else { self.attach() }
                }
            }
        }
    }

    private static let notificationCenterBundleID = "com.apple.notificationcenterui"

    private func attach() {
        guard AXIsProcessTrusted() else { isWatching = false; return }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == Self.notificationCenterBundleID
        }) else { isWatching = false; return }

        if observedPID == app.processIdentifier, observer != nil { return }
        detach()

        let pid = app.processIdentifier
        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<NotificationBannerWatcher>.fromOpaque(refcon).takeUnretainedValue()
            // The callback already runs on the main run loop; hop only to satisfy
            // the actor, and do the parking FIRST inside handle().
            MainActor.assumeIsolated { watcher.handle(window: element) }
        }

        guard AXObserverCreate(pid, callback, &newObserver) == .success,
              let newObserver else { isWatching = false; return }

        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(newObserver, element,
                                  kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           AXObserverGetRunLoopSource(newObserver), .defaultMode)

        observer = newObserver
        observedPID = pid
        appElement = element
        isWatching = true
    }

    private func detach() {
        if let observer, let appElement {
            AXObserverRemoveNotification(observer, appElement,
                                         kAXWindowCreatedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                                  AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = nil
        appElement = nil
        isWatching = false
    }

    // MARK: - Handling

    private func handle(window: AXUIElement) {
        process(window: window)
        startSweep()
    }

    /// Park first, read second.
    ///
    /// Ordering is the whole trick. The window is created before it is composited,
    /// so moving it in the same turn of the run loop means the banner is never
    /// drawn on screen at all — measured with a screenshot burst, every frame
    /// byte-identical, against a control run of the same burst that caught the
    /// banner in 6 distinct frames. Harvesting first would spend milliseconds in
    /// accessibility calls and let it flash.
    private func process(window: AXUIElement) {
        guard Self.isTransientBannerWindow(window) else { return }

        if suppressBanners { Self.park(window) }

        var banners: [AXUIElement] = []
        Self.collectBanners(window, depth: 0, into: &banners)
        guard !banners.isEmpty else { return }

        pruneSeen()
        for banner in banners {
            guard let note = Self.read(banner) else { continue }
            if seen[note.id] != nil { continue }
            seen[note.id] = Date()
            SystemNotificationsService.shared.ingestLive(note)

            // Only for apps that aren't on this Mac — anything installed already
            // resolves properly and far more cheaply. This is what gets a real
            // icon for iPhone alerts mirrored over Continuity.
            if AppIconResolver.icon(bundleID: note.bundleID, appName: note.app) == nil {
                BannerIconCapture.shared.captureIfNeeded(appName: note.app,
                                                         window: window,
                                                         banner: banner)
            }
        }
    }

    /// Distinguishes the transient banner overlay from the Notification Center
    /// PANEL, which is a window of the same process with the same AXSystemDialog
    /// subrole and the same banner children.
    ///
    /// This matters more than it looks: parking every window from this process
    /// would fling the real Notification Center off screen the moment the user
    /// clicked the clock, and they would have no idea why. The panel wraps its
    /// alerts in a group identified AXNotificationListItems; the transient
    /// overlay hangs them directly off its scroll area.
    private static func isTransientBannerWindow(_ window: AXUIElement) -> Bool {
        !containsNotificationList(window, depth: 0)
    }

    private static func containsNotificationList(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth < 12 else { return false }
        if let ident = attr(element, "AXIdentifier") as? String, ident == "AXNotificationListItems" {
            return true
        }
        for child in attr(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if containsNotificationList(child, depth: depth + 1) { return true }
        }
        return false
    }

    /// Moves the banner window so its content is off every display, while
    /// leaving ONE PIXEL of it overlapping the main display.
    ///
    /// That single pixel is not fussiness, it is what keeps the icon capture
    /// possible. ScreenCaptureKit refuses a window that touches no display —
    /// measured, SCStreamError -3811 — so parking at (-30000, -30000), which was
    /// the first version, silently disabled BannerIconCapture whenever
    /// suppression was on. Which is exactly when it is needed.
    ///
    /// The overlapping pixel is the window's leading edge, which is transparent:
    /// the banner sits ~360pt in from the far side, so shifting by the display's
    /// full width puts every drawn pixel beyond it. Verified invisible.
    private static func park(_ window: AXUIElement) {
        var origin = parkOrigin(for: window)
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    /// Somewhere that is off every screen but still adjacent to one.
    ///
    /// Tries right of the main display, then below it, checking each against the
    /// REAL display arrangement — on a two-monitor desk, shoving the window
    /// right would park it in the middle of the second monitor and show every
    /// banner there instead of hiding it. If both are occupied it gives up and
    /// goes far off-screen: suppression still works, only the icon capture is
    /// lost, and that is the right thing to sacrifice.
    private static func parkOrigin(for window: AXUIElement) -> CGPoint {
        var size = CGSize(width: 1728, height: 1117)
        if let value = attr(window, kAXSizeAttribute) {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }

        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let displays = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        let main = CGDisplayBounds(CGMainDisplayID())

        let toTheRight = CGRect(x: main.maxX, y: main.minY, width: size.width, height: size.height)
        if !displays.contains(where: { $0.intersects(toTheRight) }) {
            return CGPoint(x: main.maxX - 1, y: main.minY)
        }
        let below = CGRect(x: main.minX, y: main.maxY, width: size.width, height: size.height)
        if !displays.contains(where: { $0.intersects(below) }) {
            return CGPoint(x: main.minX, y: main.maxY - 1)
        }
        return CGPoint(x: -30_000, y: -30_000)
    }

    /// While a banner window is up, re-check it. Catches two things a single
    /// window-created event cannot: a second alert stacked into the same window,
    /// and a window that was recreated between events.
    private func startSweep() {
        guard sweepTimer == nil else { return }
        var idleTicks = 0
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, let appElement = self.appElement else { t.invalidate(); return }
                let windows = Self.attr(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
                if windows.isEmpty {
                    idleTicks += 1
                    // A couple of empty ticks before standing down, so the gap
                    // between one banner closing and the next opening does not
                    // restart the timer constantly.
                    if idleTicks >= 4 { t.invalidate(); self.sweepTimer = nil }
                    return
                }
                idleTicks = 0
                for window in windows { self.process(window: window) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
    }

    /// Identity is remembered only long enough to cover a banner's time on
    /// screen plus slack. Keeping it forever would mean a repeat alert from the
    /// same app — "Garage Door remained closed", every day — was silently
    /// swallowed as a duplicate.
    private func pruneSeen() {
        let cutoff = Date().addingTimeInterval(-120)
        seen = seen.filter { $0.value > cutoff }
    }

    // MARK: - Reading

    private static func collectBanners(_ element: AXUIElement,
                                       depth: Int,
                                       into out: inout [AXUIElement]) {
        guard depth < 12 else { return }
        if let subrole = attr(element, kAXSubroleAttribute) as? String,
           subrole == "AXNotificationCenterBanner" || subrole == "AXNotificationCenterBannerStack" {
            out.append(element)
            return   // a stack's children are its own rows, not separate alerts
        }
        for child in attr(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            collectBanners(child, depth: depth + 1, into: &out)
        }
    }

    /// Reads the fields from the banner's own labelled children rather than
    /// splitting its description.
    ///
    /// The description is "App, Title, Subtitle, Body" with no escaping, so
    /// splitting on ", " mangles any body containing a comma — the old parser
    /// turned "Body, with an awkward comma" into two fields. The children are
    /// identified `title`, `subtitle`, `body` and carry the exact text, and the
    /// app name is then whatever the description has left once that known suffix
    /// is removed.
    private static func read(_ banner: AXUIElement) -> SystemNotification? {
        let description = (attr(banner, kAXDescriptionAttribute) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var fields: [String: String] = [:]
        for child in attr(banner, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            guard let ident = attr(child, "AXIdentifier") as? String,
                  let value = attr(child, kAXValueAttribute) as? String,
                  !value.isEmpty else { continue }
            fields[ident] = value
        }

        let title    = fields["title"] ?? ""
        let subtitle = fields["subtitle"] ?? ""
        let body     = fields["body"] ?? ""

        let app = appName(from: description, title: title, subtitle: subtitle, body: body)

        let message = [subtitle, body]
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)

        guard !title.isEmpty || !message.isEmpty else { return nil }

        // The accessibility identifier is a per-notification id and is the right
        // identity while the banner is up. It is NOT stable across the database's
        // view of the same alert, which is why merging in the service keys on
        // content instead.
        let axID = attr(banner, "AXIdentifier") as? String ?? "\(app)|\(title)|\(message)"

        return SystemNotification(id: "ax:\(axID)",
                                  app: app.isEmpty ? "Notification" : app,
                                  message: message.isEmpty ? title : message,
                                  title: title,
                                  bundleID: "",
                                  deliveredAt: Date())
    }

    /// Strips the known fields off the end of the description; what remains is
    /// the posting app. Falls back to the first comma-separated component, which
    /// is what the description leads with in every sample observed.
    private static func appName(from description: String,
                                title: String, subtitle: String, body: String) -> String {
        let suffix = [title, subtitle, body].filter { !$0.isEmpty }.joined(separator: ", ")
        if !suffix.isEmpty, description.hasSuffix(suffix) {
            let cut = description.dropLast(suffix.count)
            return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        }
        return description.components(separatedBy: ", ").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
