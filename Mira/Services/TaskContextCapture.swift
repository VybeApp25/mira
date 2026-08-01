// TaskContextCapture.swift
// Freezes the user's working context AT THE INSTANT a background agent task is
// enqueued — so the worker never has to interrupt the user later to ask
// "which window?" / "what were you looking at?". See the Background Agentic Tasks
// architecture spec (§3 "context pre-capture").
//
// Two-phase capture keeps enqueue instant:
//   • captureFast()  — synchronous, sub-millisecond: front app, focused window,
//                      selected text, clipboard, browser URL. Frozen BEFORE the
//                      user moves on. Reuses ContextService (already AX/pasteboard).
//   • captureScreenshot() — async: the cursor display JPEG written to disk
//                      (a file path, never inlined — artifacts are files, §6),
//                      attached to the job a few hundred ms later.

import AppKit
import ApplicationServices

// MARK: - Snapshot model (persisted with the AgentJob)

struct TaskContextSnapshot: Codable, Equatable {
    let capturedAt: Date
    var frontAppName: String?
    var frontAppBundleId: String?
    var frontWindowTitle: String?
    var frontmostURL: String?
    var selectedText: String?
    var clipboardText: String?
    /// JPEG on disk (attached asynchronously). Never inlined to keep the job small.
    var screenshotPath: String?

    /// Compact block a worker can drop straight into its prompt so it grounds on
    /// what the user was doing without re-asking. Omits empty fields; trims text.
    func promptBlock(maxTextChars: Int = 400) -> String {
        func trim(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count > maxTextChars ? String(t.prefix(maxTextChars)) + "…" : t
        }
        var lines: [String] = ["[Context captured when you asked]"]
        if let a = frontAppName {
            lines.append("Active app: \(a)" + (frontWindowTitle.map { " — window “\($0)”" } ?? ""))
        }
        if let u = frontmostURL           { lines.append("Open URL: \(u)") }
        if let s = selectedText, !s.isEmpty  { lines.append("Selected text: \"\(trim(s))\"") }
        if let c = clipboardText, !c.isEmpty { lines.append("Clipboard: \"\(trim(c))\"") }
        if screenshotPath != nil          { lines.append("A screenshot of the screen at that moment is attached.") }
        return lines.count > 1 ? lines.joined(separator: "\n") : ""
    }
}

// MARK: - Capture service

@MainActor
final class TaskContextCapture {
    static let shared = TaskContextCapture()
    private init() {}

    /// Synchronous freeze of every field except the screenshot. Safe to call inline
    /// on the enqueue path — all reads are AX/pasteboard/NSWorkspace, sub-ms.
    func captureFast() -> TaskContextSnapshot {
        let ctx = ContextService.shared.capture()
        let app = NSWorkspace.shared.frontmostApplication
        return TaskContextSnapshot(
            capturedAt:       Date(),
            frontAppName:     ctx.activeApp,
            frontAppBundleId: app?.bundleIdentifier,
            frontWindowTitle: focusedWindowTitle(),
            frontmostURL:     ctx.frontmostURL?.absoluteString,
            selectedText:     ctx.selectedText,
            clipboardText:    ctx.clipboardText,
            screenshotPath:   nil)
    }

    /// Captures the cursor display as JPEG, writes it to disk, returns the path.
    /// Best-effort — returns nil (never throws) if Screen Recording isn't granted.
    func captureScreenshot(jobId: UUID) async -> String? {
        guard let screens = try? await ScreenCaptureService.captureAllDisplaysAsJPEG(),
              let shot = screens.first(where: { $0.isCursorScreen }) ?? screens.first else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiraTaskContext", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(jobId.uuidString).jpg")
        do {
            try shot.imageData.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }

    // MARK: - Focused window title via Accessibility

    /// Title of the frontmost app's focused window. Degrades to nil without AX trust.
    private func focusedWindowTitle() -> String? {
        guard AXIsProcessTrusted(),
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let appEl = AXUIElementCreateApplication(pid)
        var winRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let win = winRef else { return nil }
        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success else { return nil }
        let title = titleRef as? String
        return (title?.isEmpty == false) ? title : nil
    }
}
