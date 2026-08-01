// SnapZoneModule.swift
// MacNotch's Snap Zones: drag a window toward the top of the screen and layout
// tiles appear in the notch — halves, thirds, quarters, maximize. Release over a
// tile and the window snaps there. The parity audit scored this ❌ (zero hits for
// SnapZone anywhere) and called it "the single most-demoed feature".
//
// Detection is POLLED, not a global NSEvent monitor. HoverTrackingManager already
// documents why: macOS silently blocks global monitors under Input Monitoring
// restrictions, and a window manager that stops working with no error is worse
// than one that was never built. Polling NSEvent.mouseLocation plus
// pressedMouseButtons needs no additional permission and cannot be silently
// disabled.
//
// Repositioning needs Accessibility. Note that unlike Bluetooth's TCC domain,
// AX does NOT terminate the app when untrusted — it just fails, so this degrades
// to an inert panel rather than a crash. The module says so rather than silently
// doing nothing.

import SwiftUI
import AppKit
import ApplicationServices
import Combine

// MARK: - Zones

enum SnapZone: String, CaseIterable, Identifiable {
    case maximize
    case leftHalf, rightHalf, topHalf, bottomHalf
    case leftThird, centerThird, rightThird
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .maximize:    return "Maximize"
        case .leftHalf:    return "Left Half"
        case .rightHalf:   return "Right Half"
        case .topHalf:     return "Top Half"
        case .bottomHalf:  return "Bottom Half"
        case .leftThird:   return "Left Third"
        case .centerThird: return "Center Third"
        case .rightThird:  return "Right Third"
        case .topLeft:     return "Top Left"
        case .topRight:    return "Top Right"
        case .bottomLeft:  return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }

    /// Fractional rect within the screen's visible frame, in top-left terms.
    var fraction: CGRect {
        switch self {
        case .maximize:    return CGRect(x: 0,     y: 0,   width: 1,     height: 1)
        case .leftHalf:    return CGRect(x: 0,     y: 0,   width: 0.5,   height: 1)
        case .rightHalf:   return CGRect(x: 0.5,   y: 0,   width: 0.5,   height: 1)
        case .topHalf:     return CGRect(x: 0,     y: 0,   width: 1,     height: 0.5)
        case .bottomHalf:  return CGRect(x: 0,     y: 0.5, width: 1,     height: 0.5)
        case .leftThird:   return CGRect(x: 0,     y: 0,   width: 1.0/3, height: 1)
        case .centerThird: return CGRect(x: 1.0/3, y: 0,   width: 1.0/3, height: 1)
        case .rightThird:  return CGRect(x: 2.0/3, y: 0,   width: 1.0/3, height: 1)
        case .topLeft:     return CGRect(x: 0,     y: 0,   width: 0.5,   height: 0.5)
        case .topRight:    return CGRect(x: 0.5,   y: 0,   width: 0.5,   height: 0.5)
        case .bottomLeft:  return CGRect(x: 0,     y: 0.5, width: 0.5,   height: 0.5)
        case .bottomRight: return CGRect(x: 0.5,   y: 0.5, width: 0.5,   height: 0.5)
        }
    }
}

// MARK: - Service

@MainActor
final class SnapZoneService: ObservableObject {

    static let shared = SnapZoneService()

    /// True while a window drag has reached the trigger band at the top.
    @Published private(set) var isArmed = false
    /// Tile the cursor is currently over, if any.
    @Published var hoveredZone: SnapZone?
    /// Name of the window being dragged, for the panel's header.
    @Published private(set) var draggedWindowTitle: String?

    /// User's chosen tiles. MacNotch allows up to 10, minimum 1.
    @Published var enabledZones: [SnapZone] = [
        .maximize, .leftHalf, .rightHalf,
        .leftThird, .centerThird, .rightThird,
        .topLeft, .topRight, .bottomLeft, .bottomRight
    ]

    /// How far from the top edge a drag must reach to arm the tiles.
    private static let triggerBand: CGFloat = 6

    // Tile geometry, shared with the view so hit-testing and drawing cannot
    // disagree. The row is centred on screen.
    static let tileW:   CGFloat = 46
    static let tileGap: CGFloat = 7

    /// Which tile the cursor is over, computed from the row's known geometry.
    ///
    /// This is NOT done with SwiftUI `.onHover`, which was the first attempt and
    /// was wrong: hover events do not fire reliably while the mouse button is
    /// held, so during the drag that matters the highlight went stale and release
    /// applied whichever tile last received an event — measured landing a window
    /// in bottomRight after releasing over leftHalf. Hit-testing the cursor
    /// against the row is deterministic and works mid-drag.
    ///
    /// Horizontal position alone selects the tile, matching how the row reads
    /// during a drag; requiring precise vertical aim inside a 34pt tile would
    /// make the gesture fussy.
    func zone(at location: CGPoint) -> SnapZone? {
        guard let screen = NSScreen.main, !enabledZones.isEmpty else { return nil }
        let n = CGFloat(enabledZones.count)
        let total = n * Self.tileW + (n - 1) * Self.tileGap
        let startX = screen.frame.midX - total / 2
        guard location.x >= startX, location.x <= startX + total else { return nil }
        let idx = Int((location.x - startX) / (Self.tileW + Self.tileGap))
        guard idx >= 0, idx < enabledZones.count else { return nil }
        return enabledZones[idx]
    }
    private var timer: Timer?
    private var wasPressed = false
    private var dragStart: CGPoint?
    private var draggedWindow: AXUIElement?

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        disarm()
    }

    // MARK: - Polling

    private func tick() {
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        let loc = NSEvent.mouseLocation      // Cocoa coords, origin bottom-left

        defer { wasPressed = pressed }

        // Press began — remember where, so a click at the top doesn't arm.
        if pressed && !wasPressed {
            dragStart = loc
            draggedWindow = nil
            return
        }

        // Release — snap if armed over a tile.
        if !pressed && wasPressed {
            if isArmed, let zone = hoveredZone { apply(zone) }
            disarm()
            return
        }

        guard pressed, let start = dragStart else {
            if isArmed { disarm() }
            return
        }

        // A drag, not a click: require real movement before arming, or every
        // click on a title bar near the top would pop the tiles open.
        let moved = hypot(loc.x - start.x, loc.y - start.y) > 12
        guard moved else { return }

        guard let screen = NSScreen.main else { return }
        let atTop = loc.y >= screen.frame.maxY - Self.triggerBand

        if atTop && !isArmed {
            arm()
        } else if !atTop && isArmed {
            disarm()
        }

        // Track the hovered tile from the cursor while armed, so release always
        // applies what the highlight was showing.
        if isArmed {
            let z = zone(at: loc)
            if z != hoveredZone { hoveredZone = z }
        }
    }

    private func arm() {
        guard AXIsProcessTrusted() else { return }
        draggedWindow = Self.frontmostWindow()
        draggedWindowTitle = draggedWindow.flatMap(Self.title(of:))
        // Only arm for a window we can actually move — arming with nothing to
        // snap would promise an action that silently fails on release.
        guard draggedWindow != nil else { return }
        isArmed = true
        NotchModuleRegistry.shared.select("snap")
        NotificationCenter.default.post(name: .miraSnapZonesArmed, object: nil)
    }

    private func disarm() {
        isArmed = false
        hoveredZone = nil
        draggedWindowTitle = nil
        dragStart = nil
        draggedWindow = nil
        NotificationCenter.default.post(name: .miraSnapZonesDisarmed, object: nil)
    }

    // MARK: - Applying

    func apply(_ zone: SnapZone) {
        guard let window = draggedWindow ?? Self.frontmostWindow(),
              let screen = NSScreen.main else { return }

        let vf = screen.visibleFrame
        let f = zone.fraction

        // AX uses top-left origin with y growing DOWN, while NSScreen uses
        // bottom-left with y growing up. Converting through the full frame
        // height (not visibleFrame) is what keeps windows off the menu bar.
        let originY = screen.frame.maxY - vf.maxY
        let target = CGRect(
            x: vf.minX + f.origin.x * vf.width,
            y: originY + f.origin.y * vf.height,
            width:  f.width  * vf.width,
            height: f.height * vf.height
        )

        var pos = CGPoint(x: target.minX, y: target.minY)
        var size = CGSize(width: target.width, height: target.height)

        // Size before position, then position again: some apps clamp a move
        // against their CURRENT size, so setting position first can land the
        // window short and leave it misplaced.
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        if let posValue = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    // MARK: - AX helpers

    private static func frontmostWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success
        else { return nil }
        return (window as! AXUIElement?)
    }

    private static func title(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}

extension Notification.Name {
    static let miraSnapZonesArmed    = Notification.Name("miraSnapZonesArmed")
    static let miraSnapZonesDisarmed = Notification.Name("miraSnapZonesDisarmed")
}

// MARK: - Module

@MainActor
final class SnapZoneModule: NotchModule, ObservableObject {

    let id    = "snap"
    let title = "Snap Zones"
    let icon  = "rectangle.split.2x2"

    /// Short and wide — a row of tiles, matching the audit's note that MacNotch's
    /// Snap Zones panel is one of its shortest.
    let heightLevel: NotchHeightLevel = .compact
    let allowsTallMode = false

    private let service = SnapZoneService.shared
    private var cancellables = Set<AnyCancellable>()

    var subtitle: NotchHeaderSubtitle? {
        guard let t = service.draggedWindowTitle, !t.isEmpty else { return nil }
        return NotchHeaderSubtitle(text: t, isPill: true)
    }

    init() {
        service.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func didAppear() {
        // Matches MacNotch: while you are configuring zones, snapping is
        // suspended so a drag does not fight the editor — and the header says
        // so, because a feature that is deliberately inert and silent is
        // indistinguishable from a broken one.
        PreviewModeService.shared.begin(feature: "Snap Zones", suspended: "Snap inactive")
        SnapZoneService.shared.stop()
    }

    func didDisappear() {
        PreviewModeService.shared.end(feature: "Snap Zones")
        SnapZoneService.shared.start()
    }

    func makeContent() -> AnyView { AnyView(SnapZoneModuleView(service: service)) }
}

// MARK: - View

private struct SnapZoneModuleView: View {

    @ObservedObject var service: SnapZoneService
    @ObservedObject private var accentSvc = AccentColorService.shared

    private var accent: Color { accentSvc.color }

    var body: some View {
        VStack(spacing: 0) {
            if !AXIsProcessTrusted() {
                permissionPrompt
            } else {
                tiles
            }
        }
        .padding(.top, NotchModuleShellView.headerHeight)
        .background(Color.black)
    }

    private var tiles: some View {
        HStack(spacing: SnapZoneService.tileGap) {
            ForEach(service.enabledZones) { zone in
                tile(zone)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity)
    }

    private func tile(_ zone: SnapZone) -> some View {
        let hovered = service.hoveredZone == zone
        return Button {
            // Clicking works too, for when you just want to place the frontmost
            // window without dragging it anywhere.
            service.apply(zone)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                // Miniature of the resulting layout — the tile shows what you get
                // rather than naming it, which is why a row of these reads at a
                // glance mid-drag.
                GeometryReader { geo in
                    let f = zone.fraction
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(hovered ? accent : accent.opacity(0.55))
                        .frame(width:  max(3, f.width  * geo.size.width),
                               height: max(3, f.height * geo.size.height))
                        .offset(x: f.origin.x * geo.size.width,
                                y: f.origin.y * geo.size.height)
                }
                .padding(4)
            }
            .frame(width: SnapZoneService.tileW, height: 34)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(hovered ? accent : Color.white.opacity(0.10),
                                  lineWidth: hovered ? 1.5 : 1)
            )
            .scaleEffect(hovered ? 1.06 : 1.0)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: hovered)
        }
        .buttonStyle(.plain)
        .help(zone.label)
        .accessibilityLabel(zone.label)
    }

    private var permissionPrompt: some View {
        VStack(spacing: 5) {
            Image(systemName: "lock")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.30))
            Text("Accessibility access needed")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
            Text("Snap Zones moves windows, which macOS gates behind Accessibility.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }
}
