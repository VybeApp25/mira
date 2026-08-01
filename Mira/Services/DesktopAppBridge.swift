// DesktopAppBridge.swift
// Drives the user's own Claude Desktop and ChatGPT desktop apps, using the
// session they are already signed into.
//
// WHY THIS EXISTS RATHER THAN AN API CALL. The point is the user's own account
// and their own plan — no key, no proxy, no second bill. There is no public API
// that lets a third-party app act as a signed-in consumer Claude or ChatGPT
// user, so the only route to "their account" is the app they are already logged
// into. That means UI automation, and this file should be read as automation of
// someone else's app, with all that implies.
//
// THE UNLOCK IS THE NON-OBVIOUS PART. Both apps are Chromium/Electron, and
// Electron keeps its accessibility tree COLLAPSED until an assistive client asks
// for it. Measured on this Mac before and after setting AXManualAccessibility on
// the application element:
//
//     Claude Desktop:  13 nodes, 0 text, 0 web areas   ->  57 nodes, 6 static
//                                                          texts, 2 web areas
//
// Without that flag the tree is a stub and every selector in the world finds
// nothing — which is exactly how this would look "impossible" if probed once and
// abandoned. The flag is per-process and has to be re-set when the app restarts.
//
// WHAT IS ASYMMETRIC TODAY, measured, both apps sitting on their launch screen:
//
//   • ChatGPT exposes an AXTextArea whose value IS settable — it can be written
//     to directly.
//   • Claude Desktop exposes readable text but NO text field, so composing there
//     needs focus-plus-keystrokes rather than a value write.
//
// So `send` tries the clean path and falls back to typing, and reports which it
// used instead of pretending they are the same. Reading replies back is NOT
// solved here: ChatGPT exposed no static text at all in the same probe, and
// guessing at a selector that happened to work once is how this kind of code
// starts lying. That step belongs to Mira's vision path until the tree proves
// stable enough to trust.

import AppKit
import ApplicationServices

@MainActor
final class DesktopAppBridge: ObservableObject {

    static let shared = DesktopAppBridge()

    enum App: String, CaseIterable {
        case claude  = "Claude"
        case chatgpt = "ChatGPT"

        var bundleID: String {
            switch self {
            case .claude:  return "com.anthropic.claudefordesktop"
            case .chatgpt: return "com.openai.chat"
            }
        }

        var displayName: String {
            switch self {
            case .claude:  return "Claude"
            case .chatgpt: return "ChatGPT"
            }
        }
    }

    enum SendResult: Equatable {
        /// Written straight into the composer's value.
        case wrote
        /// Composer wasn't settable, so the text was typed into it.
        case typed
        case appNotInstalled
        case appNotRunning
        case noComposerFound
        case notTrusted
    }

    private init() {}

    // MARK: - Presence

    func isInstalled(_ app: App) -> Bool { url(for: app) != nil }

    private func url(for app: App) -> URL? {
        if let byID = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            return byID
        }
        let path = "/Applications/\(app.rawValue).app"
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    private func running(_ app: App) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == app.bundleID || $0.localizedName == app.rawValue
        }
    }

    func isRunning(_ app: App) -> Bool { running(app) != nil }

    // MARK: - Launch

    /// Bring the app up and make its UI readable. Returns once it is running, or
    /// nil if it isn't installed.
    @discardableResult
    func open(_ app: App, activate: Bool = true) async -> NSRunningApplication? {
        guard let appURL = url(for: app) else { return nil }

        if let already = running(app) {
            if activate { already.activate() }
            unlockAccessibility(for: already)
            return already
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        let launched = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        guard let launched else { return nil }

        // Electron builds its accessibility tree lazily and only after the flag
        // is set, so both the wait and the retry matter — asking once, straight
        // after launch, reliably sees the stub tree.
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            unlockAccessibility(for: launched)
            if !windows(of: launched).isEmpty { break }
        }
        return launched
    }

    /// Ask Chromium to expose its real accessibility tree.
    ///
    /// Per-process and lost on relaunch, so this is called on every open rather
    /// than once at setup. Harmless to repeat.
    private func unlockAccessibility(for app: NSRunningApplication) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    // MARK: - Sending

    /// Put `prompt` into the app's composer and submit it.
    ///
    /// Does NOT wait for or read a reply — see the file header for why that is
    /// deliberately not attempted here.
    func send(_ prompt: String, to app: App, submit: Bool = true) async -> SendResult {
        guard AXIsProcessTrusted() else { return .notTrusted }
        guard isInstalled(app) else { return .appNotInstalled }
        guard let running = await open(app) else { return .appNotRunning }

        // Give a freshly-focused window a moment; typing into an app that is
        // still animating forward loses the first characters.
        try? await Task.sleep(nanoseconds: 400_000_000)

        guard let composer = findComposer(in: running) else { return .noComposerFound }

        AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(composer, kAXValueAttribute as CFString, &settable)

        if settable.boolValue {
            AXUIElementSetAttributeValue(composer, kAXValueAttribute as CFString, prompt as CFTypeRef)
            if submit { pressReturn() }
            return .wrote
        }

        // No settable value — Claude Desktop's composer is in this shape. Type
        // it instead, which needs the field genuinely focused first.
        type(prompt)
        if submit { pressReturn() }
        return .typed
    }

    // MARK: - Tree

    private func windows(of app: NSRunningApplication) -> [AXUIElement] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success
        else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    /// The message box, as opposed to the sidebar search field.
    ///
    /// Both apps put a search field in the same window, and it is usually FIRST
    /// in the tree — picking the first text field finds search and silently
    /// sends the user's prompt into a filter box. So a text AREA wins over a
    /// text FIELD, and anything describing itself as search is rejected outright.
    private func findComposer(in app: NSRunningApplication) -> AXUIElement? {
        var areas: [AXUIElement] = []
        var fields: [AXUIElement] = []
        for window in windows(of: app) {
            collectEditable(window, depth: 0, areas: &areas, fields: &fields)
        }
        return areas.first ?? fields.first
    }

    private func collectEditable(_ element: AXUIElement,
                                 depth: Int,
                                 areas: inout [AXUIElement],
                                 fields: inout [AXUIElement]) {
        guard depth < 25 else { return }

        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""

        if role == "AXTextArea" || role == "AXTextField" {
            var descValue: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descValue)
            let description = (descValue as? String ?? "").lowercased()
            if !description.contains("search") {
                if role == "AXTextArea" { areas.append(element) } else { fields.append(element) }
            }
        }

        var childValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childValue)
        for child in (childValue as? [AXUIElement]) ?? [] {
            collectEditable(child, depth: depth + 1, areas: &areas, fields: &fields)
        }
    }

    // MARK: - Keystrokes

    private func type(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for chunk in text.chunked(20) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { continue }
            var utf16 = Array(chunk.utf16)
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            usleep(6_000)
        }
    }

    private func pressReturn() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
    }
}

private extension String {
    /// Long strings posted as one Unicode event get truncated by some apps.
    func chunked(_ size: Int) -> [String] {
        guard count > size else { return [self] }
        var out: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            out.append(String(self[index..<end]))
            index = end
        }
        return out
    }
}
