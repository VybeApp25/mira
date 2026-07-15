import Foundation
import AppKit
import ApplicationServices

// MARK: - AX Actuation (background "write" half)
//
// GroundingService/ContextService already READ the Accessibility tree
// (AXUIElementCopy*). This is the WRITE half: pressing buttons and setting
// field values through the Accessibility API so Mira can drive AX-capable apps
// WITHOUT moving the real cursor or activating the app.
//
// This is the prototype that answers the one architectural unknown for the
// autonomous-control direction: can we actuate a real app in the background,
// zero cursor movement? If yes, the AX path covers most native apps and the
// CGEvent cursor takeover (ComputerUseService) is only a fallback for AX-poor
// apps (Electron/games/canvas). See project_mira_autonomy_direction.
//
// Why this is "background": AXUIElementPerformAction / SetAttributeValue are
// delivered straight to the target element via its owning process — they do not
// go through .cghidEventTap (the shared HID stream), so the global pointer and
// keyboard focus are untouched. Another app can stay frontmost the whole time.

@MainActor
final class AXActuationService {
    static let shared = AXActuationService()
    private init() {}

    enum ActuationError: Error, CustomStringConvertible {
        case notTrusted
        case appNotRunning(String)
        case elementNotFound(String)
        case actionUnsupported(String)
        case notSettable(String)
        case setValueFailed(AXError)
        case timedOut(String)

        var description: String {
            switch self {
            case .notTrusted:               return "Accessibility permission not granted (AXIsProcessTrusted == false)."
            case .appNotRunning(let b):      return "No running app with bundle id \(b)."
            case .elementNotFound(let what): return "Could not find AX element: \(what)."
            case .actionUnsupported(let a):  return "Element does not advertise action \(a)."
            case .notSettable(let what):     return "AX element \(what) is not settable (read-only/disabled) — use cursor fallback."
            case .setValueFailed(let e):     return "AXUIElementSetAttributeValue failed: \(e.rawValue)."
            case .timedOut(let what):        return "AX messaging timed out talking to \(what) — app may be unresponsive."
            }
        }

        /// True when the failure means "AX can't do this here, route to the
        /// CGEvent cursor takeover" rather than a hard error.
        var isCursorFallbackSignal: Bool {
            switch self {
            case .elementNotFound, .actionUnsupported, .notSettable: return true
            case .notTrusted, .appNotRunning, .setValueFailed, .timedOut: return false
            }
        }
    }

    /// Bound on every AX message to a target app. Without this, a beachballing
    /// app makes AXUIElementCopy*/Set* block the caller indefinitely.
    private let messagingTimeoutSeconds: Float = 2.0

    // MARK: - Public actuation API

    /// Press a button (or any element advertising AXPress) found by its title /
    /// label, anywhere in the target app's element tree. Does not activate the app.
    func pressButton(titled title: String, inBundleID bundleID: String) throws {
        let root = try actuationRoot(forBundleID: bundleID)
        guard let el = firstElement(in: root, where: { e in
            Self.label(of: e) == title && self.advertises(kAXPressAction, on: e)
        }) else {
            throw ActuationError.elementNotFound("button titled \"\(title)\"")
        }
        guard advertises(kAXPressAction, on: el) else {
            throw ActuationError.actionUnsupported(kAXPressAction as String)
        }
        AXUIElementPerformAction(el, kAXPressAction as CFString)
    }

    /// Set the value of the first text field/area matching `titled` (matched
    /// against the field's title, placeholder, or accessibility description). If
    /// `titled` is nil, the first writable text element is used. Focuses the
    /// element first (so apps that mirror value→model on focus behave), then sets
    /// its value. No cursor movement, no app activation.
    @discardableResult
    func setTextValue(_ value: String,
                      titled: String? = nil,
                      inBundleID bundleID: String) throws -> String {
        let root = try actuationRoot(forBundleID: bundleID)
        guard let el = firstElement(in: root, where: { e in
            guard let role = Self.role(of: e),
                  role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String)
            else { return false }
            guard let titled else { return true }
            return Self.label(of: e) == titled
        }) else {
            throw ActuationError.elementNotFound("text field \(titled.map { "\"\($0)\"" } ?? "(any)")")
        }

        // Settability check: a read-only/disabled field (or a label posing as a
        // text field) would otherwise fail silently and the write would *look*
        // like it landed. This is also the precise signal the router needs:
        // "AX can't write here → use the cursor."
        guard isSettable(kAXValueAttribute as CFString, on: el) else {
            throw ActuationError.notSettable("text field \(titled.map { "\"\($0)\"" } ?? "(any)")")
        }

        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let err = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFTypeRef)
        guard err == .success else { throw ActuationError.setValueFailed(err) }

        return readValue(of: el) ?? ""
    }

    /// Insert `text` at the caret of the SYSTEM-WIDE focused UI element — i.e.
    /// whatever text field the user is typing in right now, in ANY frontmost app.
    /// Unlike `setTextValue` (which replaces a whole field found by role under a
    /// specific app), this targets the live keyboard-focus element and inserts at
    /// the caret via kAXSelectedText, so existing content and cursor position are
    /// preserved. This is the primary path for dictate-anywhere. Returns false when
    /// the focused element doesn't expose a settable selection (AX-poor apps like
    /// Electron/Chromium canvases) — the caller then falls back to a paste.
    @discardableResult
    func insertTextAtSystemFocus(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let sysWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sysWide, messagingTimeoutSeconds)

        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(sysWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return false
        }
        let el = focused as! AXUIElement

        // Setting kAXSelectedText replaces the current selection (or inserts at the
        // caret when the selection is empty) — the exact semantics dictation wants.
        guard isSettable(kAXSelectedTextAttribute as CFString, on: el) else { return false }
        let err = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return err == .success
    }

    /// Read back a text element's current value — used to verify a write landed.
    func readTextValue(titled: String? = nil, inBundleID bundleID: String) throws -> String {
        let root = try actuationRoot(forBundleID: bundleID)
        guard let el = firstElement(in: root, where: { e in
            guard let role = Self.role(of: e),
                  role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String)
            else { return false }
            guard let titled else { return true }
            return Self.label(of: e) == titled
        }) else {
            throw ActuationError.elementNotFound("text field \(titled.map { "\"\($0)\"" } ?? "(any)")")
        }
        return readValue(of: el) ?? ""
    }

    /// Screen frame (top-left origin, CGEvent-compatible) of the first element
    /// bearing `label`. Works even when the element does NOT support AXPress /
    /// settable AXValue — many "AX-poor" apps still expose element *geometry*.
    /// This is the router's cursor-fallback locator: find the rect via AX, then
    /// CGEvent-click its center, no vision grounding needed.
    func screenFrame(ofLabeled label: String, inBundleID bundleID: String) throws -> CGRect {
        let root = try actuationRoot(forBundleID: bundleID)
        guard let el = firstElement(in: root, where: { Self.label(of: $0) == label }) else {
            throw ActuationError.elementNotFound("element labeled \"\(label)\"")
        }
        guard let frame = Self.frame(of: el) else {
            throw ActuationError.elementNotFound("on-screen frame for \"\(label)\"")
        }
        return frame
    }

    // MARK: - Element resolution

    /// Root AX element for a running app, addressed by pid (NOT activated).
    /// Applies a messaging timeout so an unresponsive target can't hang the
    /// caller — the timeout set on the application element governs every message
    /// sent to elements in its subtree.
    private func appElement(forBundleID bundleID: String) throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw ActuationError.notTrusted }
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else {
            throw ActuationError.appNotRunning(bundleID)
        }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, messagingTimeoutSeconds)
        return app
    }

    /// The element to search under for a background actuation. Prefers the app's
    /// main window (and then its focused window) so we target the document the
    /// user means — not a stray field in a minimized/background window or a
    /// hidden palette. Falls back to the whole app element if no window is
    /// exposed (some agent/menu-bar apps have none).
    private func actuationRoot(forBundleID bundleID: String) throws -> AXUIElement {
        let app = try appElement(forBundleID: bundleID)
        for attr in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] as [CFString] {
            var ref: AnyObject?
            if AXUIElementCopyAttributeValue(app, attr, &ref) == .success,
               let win = ref, CFGetTypeID(win) == AXUIElementGetTypeID() {
                return (win as! AXUIElement)
            }
        }
        return app
    }

    /// Depth-first search of the AX tree for the first element matching `predicate`.
    /// Depth-capped to keep deep/recursive trees (web content) bounded.
    private func firstElement(in root: AXUIElement,
                              maxDepth: Int = 40,
                              where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        if predicate(root) { return root }
        guard maxDepth > 0 else { return nil }
        for child in children(of: root) {
            if let hit = firstElement(in: child, maxDepth: maxDepth - 1, where: predicate) {
                return hit
            }
        }
        return nil
    }

    private func children(of el: AXUIElement) -> [AXUIElement] {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
              let kids = ref as? [AXUIElement] else { return [] }
        return kids
    }

    // MARK: - Element introspection

    private func advertises(_ action: String, on el: AXUIElement) -> Bool {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(el, &actions) == .success,
              let names = actions as? [String] else { return false }
        return names.contains(action)
    }

    private func isSettable(_ attribute: CFString, on el: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(el, attribute, &settable) == .success
        else { return false }
        return settable.boolValue
    }

    private func readValue(of el: AXUIElement) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    /// Top-left-origin screen rect of an element from kAXPosition + kAXSize.
    /// AX position is already top-left origin, matching CGEvent global coords.
    private static func frame(of el: AXUIElement) -> CGRect? {
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, CFGetTypeID(posVal) == AXValueGetTypeID(),
              let sizeVal = sizeRef, CFGetTypeID(sizeVal) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size  = CGSize.zero
        AXValueGetValue((posVal as! AXValue), .cgPoint, &point)
        AXValueGetValue((sizeVal as! AXValue), .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func role(of el: AXUIElement) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    /// Best human-readable label for an element: title, then description, then
    /// the title of a linked title-element. Matches how users name buttons/fields.
    private static func label(of el: AXUIElement) -> String? {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute,
                     kAXPlaceholderValueAttribute] as [CFString] {
            var ref: AnyObject?
            if AXUIElementCopyAttributeValue(el, attr, &ref) == .success,
               let s = ref as? String, !s.isEmpty { return s }
        }
        return nil
    }

    // MARK: - Capability inspection (router input)
    //
    // The actuation router asks, per app: "can AX drive this in the background,
    // or must I fall back to the CGEvent cursor takeover?" This answers that with
    // a single bounded traversal of the app's main window, reporting whether the
    // app exposes anything pressable and any *writable* text field. The real-world
    // coverage line (which apps are AX-poor) falls out of running this across apps.

    struct ActuationCapability {
        let bundleID: String
        let isRunning: Bool
        let hasAXWindow: Bool      // exposed a main/focused window to scope to
        let hasPressable: Bool     // ≥1 element advertising AXPress
        let hasWritableText: Bool  // ≥1 text field whose AXValue is settable

        /// Coarse routing verdict for this app right now.
        var route: String {
            if !isRunning              { return "unavailable (not running)" }
            if hasWritableText         { return "AX background (write + press)" }
            if hasPressable            { return "AX background (press only — writes need cursor)" }
            if hasAXWindow             { return "cursor fallback (AX tree too thin)" }
            return "cursor fallback (no AX window)"
        }

        var summary: String {
            """
            CAPABILITY (\(bundleID))
              running:        \(isRunning ? "yes" : "no")
              AX window:      \(hasAXWindow ? "yes" : "no")
              pressable:      \(hasPressable ? "yes" : "no")
              writable text:  \(hasWritableText ? "yes" : "no")
              route:          \(route)
            """
        }
    }

    func inspectCapability(forBundleID bundleID: String) -> ActuationCapability {
        guard AXIsProcessTrusted(),
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil,
              let app = try? appElement(forBundleID: bundleID) else {
            return ActuationCapability(bundleID: bundleID, isRunning: false,
                                       hasAXWindow: false, hasPressable: false,
                                       hasWritableText: false)
        }
        let root = (try? actuationRoot(forBundleID: bundleID)) ?? app
        let hasWindow = [kAXMainWindowAttribute, kAXFocusedWindowAttribute].contains { attr in
            var ref: AnyObject?
            return AXUIElementCopyAttributeValue(app, attr as CFString, &ref) == .success
                && ref.map { CFGetTypeID($0) == AXUIElementGetTypeID() } == true
        }
        var pressable = false
        var writable = false
        _ = firstElement(in: root) { e in
            if !pressable, self.advertises(kAXPressAction, on: e) { pressable = true }
            if !writable, let role = Self.role(of: e),
               role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String),
               self.isSettable(kAXValueAttribute as CFString, on: e) { writable = true }
            return pressable && writable   // stop early once both confirmed
        }
        return ActuationCapability(bundleID: bundleID, isRunning: true,
                                   hasAXWindow: hasWindow, hasPressable: pressable,
                                   hasWritableText: writable)
    }

    // MARK: - Background actuation probe (de-risking entry point)
    //
    // Proves the slice end-to-end against a real, running app WITHOUT touching the
    // cursor. Call from a debug menu / lldb. Returns a human-readable result.
    // Default target is TextEdit: open a document first, then run this while a
    // DIFFERENT app is frontmost — the text should appear in TextEdit's document
    // even though it never came forward and the pointer never moved.
    func runBackgroundActuationProbe(bundleID: String = "com.apple.TextEdit",
                                     marker: String = "Mira background write ✅") -> String {
        guard AXIsProcessTrusted() else {
            return "FAIL: Accessibility not trusted — grant Mira access in System Settings › Privacy & Security › Accessibility."
        }
        let frontBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let cursorBefore = NSEvent.mouseLocation
        do {
            let wrote = try setTextValue(marker, inBundleID: bundleID)
            let cursorAfter = NSEvent.mouseLocation
            let frontAfter = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            let cursorMoved = abs(cursorBefore.x - cursorAfter.x) > 0.5
                           || abs(cursorBefore.y - cursorAfter.y) > 0.5
            let stoleFocus = frontBefore != frontAfter
            return """
                PROBE RESULT (\(bundleID))
                  wrote value:     \(wrote.isEmpty ? "(empty — read-back failed)" : "\"\(wrote)\"")
                  cursor moved:    \(cursorMoved ? "YES ⚠️" : "no ✅")
                  frontmost app:   \(frontBefore) → \(frontAfter) \(stoleFocus ? "⚠️ stole focus" : "✅ unchanged")
                  verdict:         \(!cursorMoved && !stoleFocus && !wrote.isEmpty ? "BACKGROUND ACTUATION CONFIRMED" : "needs review")
                """
        } catch {
            return "FAIL: \(error)"
        }
    }
}
