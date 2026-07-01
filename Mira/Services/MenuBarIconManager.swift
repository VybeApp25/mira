import Cocoa

// MARK: - MenuBarIconManager
//
// Utility #4: a Hidden-Bar-style menu-bar icon manager. Two extra NSStatusItems
// (a chevron toggle + a blank "spacer") let the user hide clutter from the REAL
// system menu bar in place -- no custom overlay window. Same public-API trick
// used by Hidden Bar / Vanilla: macOS lays out NSStatusItems right-to-left and
// silently clips whichever don't fit. Expanding the spacer's `.length` pushes
// everything to its LEFT off the visible bar; shrinking it gives that space
// back. The user must Cmd-drag their own icons so hideable ones sit left of
// the spacer and always-visible ones sit right of the toggle -- see
// menuBarIconManagerSection in SettingsView.swift for the in-app copy
// explaining this.

@MainActor
final class MenuBarIconManager: ObservableObject {
    static let shared = MenuBarIconManager()

    static let enabledKey = "mira_menubar_enabled"
    private let hiddenKey = "mira_menubar_hidden_v1"

    /// Master on/off — creates/destroys the two status items live.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }

    /// true = icons left of the spacer are currently squeezed off the bar.
    @Published private(set) var isHidden: Bool {
        didSet { UserDefaults.standard.set(isHidden, forKey: hiddenKey) }
    }

    private var toggleItem: NSStatusItem?
    private var spacerItem: NSStatusItem?

    // Revealed width is wide enough to draw a faint divider glyph — the spacer
    // used to be fully invisible at 1pt, which made it easy to Cmd-drag an icon
    // a pixel onto the wrong side of the (invisible) hide boundary and think
    // hiding was broken when really the icon just never crossed it.
    private static let revealedSpacerLength: CGFloat = 10
    private static let hiddenSpacerLength:   CGFloat = 10_000

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        isHidden  = UserDefaults.standard.object(forKey: hiddenKey) != nil
            ? UserDefaults.standard.bool(forKey: hiddenKey)
            : true   // default true: hiding is the point of enabling
    }

    /// Call once at launch; recreates the items live if left enabled last session.
    func startIfEnabled() { if isEnabled { start() } }

    func start() {
        guard toggleItem == nil else { return }   // idempotent

        // Toggle first, spacer second: macOS positions earlier-created status
        // items closer to the right edge (near the clock), later items further
        // left. Creating these AFTER StatusBarController's own icon (see
        // AppDelegate.swift) keeps Mira's icon to the right of the toggle, so
        // hiding never hides the icon needed to turn this feature back off.
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = toggle.button {
            btn.image = chevronImage()
            btn.imagePosition = .imageOnly
            btn.action = #selector(handleToggleClick)
            btn.target = self
        }
        toggleItem = toggle

        let spacer = NSStatusBar.system.statusItem(
            withLength: isHidden ? Self.hiddenSpacerLength : Self.revealedSpacerLength)
        spacer.button?.title = ""
        spacer.button?.image = dividerImage()
        spacer.button?.imagePosition = .imageOnly
        spacerItem = spacer

        NSLog("[Mira][MenuBar] start() isHidden=%@ spacer.length=%.0f (requested %.0f)",
              isHidden ? "true" : "false", spacer.length,
              isHidden ? Self.hiddenSpacerLength : Self.revealedSpacerLength)
    }

    func stop() {
        if let t = toggleItem { NSStatusBar.system.removeStatusItem(t) }
        if let s = spacerItem { NSStatusBar.system.removeStatusItem(s) }
        toggleItem = nil
        spacerItem = nil
    }

    @objc private func handleToggleClick() { NSLog("[Mira][MenuBar] chevron clicked"); toggle() }

    func toggle() {
        isHidden.toggle()
        let requested = isHidden ? Self.hiddenSpacerLength : Self.revealedSpacerLength
        spacerItem?.length = requested
        spacerItem?.button?.image = isHidden ? nil : dividerImage()
        toggleItem?.button?.image = chevronImage()
        // Read the length straight back — if AppKit silently clamped/ignored the
        // request, this log line is the smoking gun (requested vs. actual differ).
        NSLog("[Mira][MenuBar] toggle() -> isHidden=%@ requested=%.0f actual=%.0f",
              isHidden ? "true" : "false", requested, spacerItem?.length ?? -1)
    }

    /// Hidden: chevron points LEFT ("pull the hidden icons back in").
    /// Revealed: chevron points RIGHT ("push them back out").
    private func chevronImage() -> NSImage? {
        let name = isHidden ? "chevron.left" : "chevron.right"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Toggle hidden menu bar icons")
        img?.isTemplate = true
        return img
    }

    /// Faint vertical divider drawn in the revealed (10pt) spacer so the hide
    /// boundary is a visible target to Cmd-drag icons against, not a guess.
    private func dividerImage() -> NSImage? {
        let img = NSImage(size: NSSize(width: 10, height: 16), flipped: false) { rect in
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSBezierPath(rect: NSRect(x: rect.midX - 0.5, y: 1, width: 1, height: rect.height - 2)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
