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

    // MARK: - Reading a reply

    enum ReadResult: Equatable {
        case reply(String)
        /// The app exposes no readable text — ChatGPT's case today.
        case notReadable
        case timedOut
    }

    /// Send `prompt` and return what the app answers.
    ///
    /// READS BY DIFFING, not by selectors. The alternative — find the last
    /// message bubble and read it — needs a guess about which node is a reply,
    /// and a wrong guess does not fail, it returns the WRONG TEXT attributed to
    /// the model. Snapshotting every string before sending and taking what is
    /// new afterwards cannot make that mistake: whatever appeared, appeared
    /// because of this prompt.
    func ask(_ prompt: String, app: App, timeout: TimeInterval = 90) async -> ReadResult {
        guard let running = await open(app) else { return .notReadable }

        let before = staticTexts(of: running)
        // Nothing readable at all before we even start — ChatGPT exposes zero
        // static text, so there is no point sending and then waiting 90s to
        // discover we cannot read the answer.
        if before.isEmpty, app == .chatgpt { return .notReadable }

        let sent = await send(prompt, to: app)
        guard sent == .wrote || sent == .typed else { return .notReadable }

        // Poll until the text stops growing. A reply streams in, so "there is
        // new text" is not the same as "it has finished" — it has to be stable
        // before it is worth returning.
        let deadline = Date().addingTimeInterval(timeout)
        var lastJoined = ""
        var stableCount = 0

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 700_000_000)

            let now = staticTexts(of: running)
            let fresh = now.subtracting(before).filter { $0.count > 1 && $0 != prompt }

            // PREFER THE SCREEN-READER ANNOUNCEMENT. Claude Desktop publishes
            // "You said: …", "Claude responded: …" and "Claude finished the
            // response" for assistive clients. That last one is an exact
            // completion signal, and "Claude responded:" is the reply itself
            // with no guessing.
            //
            // This matters more than it sounds: the first version returned every
            // new string ordered by length, and the LONGEST was "Claude is AI
            // and can make mistakes. Please double-check responses." — the
            // disclaimer, not the answer. Measured, not hypothesised.
            if let announced = fresh.first(where: { $0.hasPrefix(Self.replyPrefix) }) {
                let reply = String(announced.dropFirst(Self.replyPrefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !reply.isEmpty {
                    // The done marker is the fast path when it is there — but it
                    // is TRANSIENT. Observed: it was present on one run and gone
                    // by the equivalent poll on the next, because the app posts
                    // it once and drops it. Requiring it meant a correct reply
                    // sat in hand while the loop ran to its 90s timeout, so
                    // stability decides too.
                    if fresh.contains(Self.doneMarker) { return .reply(reply) }
                    if reply == lastJoined {
                        stableCount += 1
                        if stableCount >= 2 { return .reply(reply) }
                    } else {
                        stableCount = 0
                        lastJoined = reply
                    }
                    continue
                }
            }

            // Fallback: no announcement (a future build, or ChatGPT once it
            // exposes text). Drop known chrome, then take what's left.
            let cleaned = fresh
                .filter { candidate in
                    !Self.chrome.contains { candidate.hasPrefix($0) }
                }
                .sorted { $0.count > $1.count }
            let joined = cleaned.joined(separator: "\n")

            if joined.isEmpty { continue }
            if joined == lastJoined {
                stableCount += 1
                // Two quiet polls in a row: streaming has stopped.
                if stableCount >= 2 { return .reply(joined) }
            } else {
                stableCount = 0
                lastJoined = joined
            }
        }
        return lastJoined.isEmpty ? .timedOut : .reply(lastJoined)
    }

    /// Claude Desktop's assistive announcements, captured from the live tree.
    private static let replyPrefix = "Claude responded: "
    private static let doneMarker  = "Claude finished the response"

    /// Strings that appear alongside a reply but are not the reply. Every one of
    /// these was observed in a real round trip — including the session-limit
    /// notice, which is unrelated to the answer and would otherwise be reported
    /// as part of it.
    private static let chrome: [String] = [
        "Claude is AI and can make mistakes",
        "Use the up and down arrow keys",
        "Track tools and referenced files",
        "You said: ",
        "Claude finished the response",
        "You’ve used ",
        "You've used ",
        " of your session limit"
    ]

    /// Every string the app is currently displaying. A Set because position in
    /// the tree is not stable across renders, and only membership matters here.
    private func staticTexts(of app: NSRunningApplication) -> Set<String> {
        var out = Set<String>()
        for window in windows(of: app) { collectText(window, depth: 0, into: &out) }
        return out
    }

    private func collectText(_ element: AXUIElement, depth: Int, into out: inout Set<String>) {
        guard depth < 30, out.count < 4000 else { return }

        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        if (roleValue as? String) == "AXStaticText" {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
            if let text = value as? String, !text.isEmpty { out.insert(text) }
        }

        var childValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childValue)
        for child in (childValue as? [AXUIElement]) ?? [] {
            collectText(child, depth: depth + 1, into: &out)
        }
    }

    /// Whether this app's replies can be read at all, so a caller can route to
    /// vision instead of waiting for text that will never arrive.
    func isReadable(_ app: App) -> Bool {
        guard let running = running(app) else { return false }
        return !staticTexts(of: running).isEmpty
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
