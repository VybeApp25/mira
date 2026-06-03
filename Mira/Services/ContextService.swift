// ContextService.swift
// Aggregates live Mac context for injection into Mira's session instructions.
// Sources: active app, frontmost browser URL, selected text (AX), clipboard, battery.
//
// Selected text requires Accessibility permission:
//   System Settings › Privacy & Security › Accessibility → add Mira.
// Browser URL requires Apple Events permission (prompted automatically on first use).

import AppKit
import ApplicationServices
import IOKit.ps

// MARK: - Context snapshot

struct MiraContext {
    let activeApp:        String?
    let frontmostURL:     URL?
    let selectedText:     String?
    let clipboardText:    String?
    let batteryPercent:   Int?
    let batteryCharging:  Bool
    let currentDate:      Date
}

// MARK: - Service

@MainActor
final class ContextService {

    static let shared = ContextService()
    private init() {}

    // MARK: - Capture

    /// Synchronous snapshot of all available context. AppleScript (browser URL) may
    /// add ~50–100ms but is called on the main actor only at turn boundaries.
    func capture() -> MiraContext {
        MiraContext(
            activeApp:       frontmostAppName(),
            frontmostURL:    frontmostBrowserURL(),
            selectedText:    selectedText(),
            clipboardText:   clipboardText(),
            batteryPercent:  battery()?.percent,
            batteryCharging: battery()?.charging ?? false,
            currentDate:     Date()
        )
    }

    /// Condensed text block for the system prompt. Trims to maxChars to control token cost.
    func buildPromptBlock(max maxChars: Int = 800) -> String {
        let ctx = capture()
        var lines: [String] = ["[Mac Context]"]

        if let app = ctx.activeApp            { lines.append("Active App: \(app)") }
        if let url = ctx.frontmostURL         { lines.append("URL: \(url.absoluteString)") }

        if let sel = ctx.selectedText, !sel.isEmpty {
            let s = sel.count > 400 ? String(sel.prefix(400)) + "…" : sel
            lines.append("Selected: \(s)")
        }
        if let clip = ctx.clipboardText, !clip.isEmpty {
            let c = clip.count > 300 ? String(clip.prefix(300)) + "…" : clip
            lines.append("Clipboard: \(c)")
        }
        if let pct = ctx.batteryPercent {
            lines.append("Battery: \(pct)% (\(ctx.batteryCharging ? "charging" : "on battery"))")
        }

        let fmt = Date.FormatStyle().month(.abbreviated).day().hour().minute()
        lines.append("Time: \(ctx.currentDate.formatted(fmt))")

        let result = lines.joined(separator: "\n")
        return result.count <= maxChars ? result : String(result.prefix(maxChars))
    }

    // MARK: - Active app

    private func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    // MARK: - Browser URL (Safari / Chrome / Arc / Firefox via AppleScript)

    private func frontmostBrowserURL() -> URL? {
        guard let app = NSWorkspace.shared.frontmostApplication?.localizedName else { return nil }
        let script: String
        switch true {
        case app.contains("Safari"):
            script = #"tell application "Safari" to return URL of current tab of front window"#
        case app.contains("Chrome"):
            script = #"tell application "Google Chrome" to return URL of active tab of front window"#
        case app.contains("Arc"):
            script = #"tell application "Arc" to return URL of active tab of front window"#
        case app.contains("Firefox"):
            script = #"tell application "Firefox" to return URL of active tab of front window"#
        case app.contains("Brave"):
            script = #"tell application "Brave Browser" to return URL of active tab of front window"#
        default:
            return nil
        }
        var err: NSDictionary?
        guard let urlStr = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue,
              err == nil else { return nil }
        return URL(string: urlStr)
    }

    // MARK: - Clipboard

    private func clipboardText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    // MARK: - Selected text via Accessibility API

    private func selectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(system,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focused = focusedRef else { return nil }

        var selRef: AnyObject?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement,
                                            kAXSelectedTextAttribute as CFString,
                                            &selRef) == .success else { return nil }
        let text = selRef as? String
        return (text?.isEmpty == false) ? text : nil
    }

    // MARK: - Battery status via IOKit

    private func battery() -> (percent: Int, charging: Bool)? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        guard let first = list.first,
              let desc  = IOPSGetPowerSourceDescription(info, first)
                  .takeUnretainedValue() as? [String: Any] else { return nil }
        let pct      = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let onBattery = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
        return (pct, !onBattery)
    }
}
