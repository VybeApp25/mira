// BannerIconCapture.swift
// The real icon for an app that is NOT installed on this Mac, read out of the
// banner's own pixels.
//
// WHY THIS EXISTS. iPhone notifications mirrored over Continuity come from apps
// that were never installed here — Vivint, myQ, Snapchat, X. AppIconResolver
// can't help: there is no bundle to look up. And there is nothing else to read,
// which was checked rather than assumed:
//
//   • the usernoted record blob carries only `titl`/`subt`/`body`
//   • there is no icon cache under the usernoted group container
//   • enumerating EVERY accessibility attribute on a banner returns no image —
//     only text, geometry and a path
//
// Notification Center is nonetheless drawing that icon, so the pixels exist.
// This captures the banner window, crops to the banner's own AXFrame, and trims
// the leading square down to the icon.
//
// For the record, MacNotch does NOT do this — its binary resolves icons with
// URLForApplicationWithBundleIdentifier: and runningApplicationsWithBundleIdentifier:
// only, and reads the same usernoted database that has no mirrored rows at all.
// Its one ScreenCaptureKit call belongs to Snap Zones. So this is past parity,
// not catching up, and it is built to fail quietly back to a monogram.
//
// FRAGILITY, STATED PLAINLY. This depends on a private accessibility call to get
// the window id, on Screen Recording being granted, and on the icon occupying
// the leading square of the banner. The first two fail loudly enough to detect;
// the third is a layout assumption that a macOS release could change. Every step
// is therefore checked, and any failure returns nil rather than a wrong image —
// a confidently wrong icon is worse than none, because it misattributes who
// messaged you.

import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Private. Maps an accessibility element to its CoreGraphics window id; there
/// is no public equivalent, and ScreenCaptureKit needs the id to capture a
/// single window.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement,
                                   _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

@MainActor
final class BannerIconCapture: ObservableObject {

    static let shared = BannerIconCapture()

    /// Bumped when a capture lands, so views showing a monogram redraw with the
    /// real icon as soon as it arrives.
    @Published private(set) var generation = 0

    private var memory: [String: NSImage] = [:]
    /// Apps already tried this session. A miss is not retried on every banner —
    /// if the layout assumption is wrong it is wrong every time, and retrying
    /// would mean a screen capture per notification forever.
    private var attempted: Set<String> = []

    private lazy var cacheDirectory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Mira/NotificationIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private init() {}

    // MARK: - Lookup

    /// Cached icon for an app, from memory or from a previous session's capture.
    /// Disk-backed deliberately: an app that notifies you once a day would
    /// otherwise show a monogram every launch until it happened to notify again.
    func icon(for appName: String) -> NSImage? {
        if let cached = memory[appName] { return cached }
        let url = fileURL(for: appName)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url) else { return nil }
        memory[appName] = image
        return image
    }

    private func fileURL(for appName: String) -> URL {
        let safe = appName.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cacheDirectory.appendingPathComponent("\(safe).png")
    }

    // MARK: - Capture

    /// Try to lift `appName`'s icon out of the banner currently on screen.
    /// Cheap to call: returns immediately unless this app is genuinely unknown.
    func captureIfNeeded(appName: String, window: AXUIElement, banner: AXUIElement) {
        guard !appName.isEmpty else { return }
        guard icon(for: appName) == nil else { return }
        guard !attempted.contains(appName) else { return }
        attempted.insert(appName)

        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &windowID) == .success, windowID != 0 else { return }

        Task { await self.performCapture(appName: appName, windowID: windowID, banner: banner) }
    }

    private func performCapture(appName: String, windowID: CGWindowID, banner: AXUIElement) async {
        // The banner slides in from the right, and at window-creation it is still
        // OUTSIDE the window's own bounds — capturing immediately gets empty
        // space. Wait for its x to stop moving rather than sleeping a guessed
        // interval, which would be wrong on a slower machine.
        guard let frame = await settledFrame(of: banner) else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)   // false: the window may be parked off screen
            guard let target = content.windows.first(where: { $0.windowID == windowID }) else { return }

            let config = SCStreamConfiguration()
            config.width  = Int(target.frame.width * 2)
            config.height = Int(target.frame.height * 2)
            config.showsCursor = false
            let shot = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: target),
                configuration: config)

            let scale = CGFloat(shot.width) / target.frame.width
            let relative = CGRect(x: (frame.origin.x - target.frame.origin.x) * scale,
                                  y: (frame.origin.y - target.frame.origin.y) * scale,
                                  width: frame.width * scale,
                                  height: frame.height * scale)
            guard relative.minX >= 0, relative.minY >= 0,
                  relative.maxX <= CGFloat(shot.width), relative.maxY <= CGFloat(shot.height),
                  let bannerImage = shot.cropping(to: relative),
                  let iconImage = Self.extractIcon(from: bannerImage,
                                                   pointHeight: frame.height) else { return }

            let image = NSImage(cgImage: iconImage,
                                size: NSSize(width: iconImage.width / 2, height: iconImage.height / 2))
            memory[appName] = image
            generation &+= 1

            if let data = NSBitmapImageRep(cgImage: iconImage).representation(using: .png, properties: [:]) {
                try? data.write(to: fileURL(for: appName))
            }
        } catch {
            // Screen Recording not granted, or the window went away. Either way
            // the monogram stands; nothing to report to the user mid-notification.
        }
    }

    /// Polls the banner's frame until it stops moving, then returns it.
    private func settledFrame(of banner: AXUIElement) async -> CGRect? {
        var previousX = CGFloat.greatestFiniteMagnitude
        for _ in 0..<40 {
            let frame = Self.frame(of: banner)
            if frame != .zero, abs(frame.origin.x - previousX) < 0.5 { return frame }
            previousX = frame.origin.x
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success,
              let value else { return .zero }
        var rect = CGRect.zero
        AXValueGetValue(value as! AXValue, .cgRect, &rect)
        return rect
    }

    // MARK: - Extraction

    /// Finds the icon inside a captured banner.
    ///
    /// The icon occupies the leading square. Trimming to its actual content
    /// rather than assuming fixed insets means a taller banner — one carrying a
    /// "TIME SENSITIVE" header, say — still yields the icon and not a slab of
    /// background with the icon adrift in it.
    ///
    /// The scan band skips the rounded corners: they come back OPAQUE BLACK in
    /// the capture, not transparent, so including them made the trim select the
    /// entire square. That was the first version, and it silently "worked".
    private static func extractIcon(from banner: CGImage, pointHeight: CGFloat) -> CGImage? {
        guard let data = banner.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let bytesPerRow = banner.bytesPerRow
        let bytesPerPixel = banner.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return nil }

        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
            let offset = y * bytesPerRow + x * bytesPerPixel
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]),
                    bytesPerPixel > 3 ? Int(bytes[offset + 3]) : 255)
        }

        let height = banner.height
        guard banner.width > height else { return nil }

        // The banner's own fill, sampled from the trailing edge — past the icon
        // and past the text.
        let background = pixel(banner.width - 12, height / 2)
        func isContent(_ p: (Int, Int, Int, Int)) -> Bool {
            p.3 > 40 && abs(p.0 - background.0) + abs(p.1 - background.1) + abs(p.2 - background.2) > 40
        }

        // SCAN IN POINTS, NOT IN FRACTIONS OF THE BANNER.
        //
        // The first version scanned the leading square — width equal to the
        // banner's height — on the assumption the icon scales with the banner.
        // It does not: the icon stays about 38pt whatever the alert's height,
        // so on a tall banner (a Time Sensitive alert carries an extra header
        // row) the square reached well into the message text.
        //
        // Measured on real captures: 11 of 17 icons collected in a day of normal
        // use were overshoots — Burger King at 181x159, X at 181x150, TikTok at
        // 120x93 containing the icon plus "St…" and two heart glyphs. Only six
        // were clean. A fraction of the height cannot fix that; a fixed point
        // window can.
        let scale = CGFloat(height) / max(pointHeight, 1)
        let xLow  = Int(8 * scale)
        let xHigh = min(banner.width, Int(54 * scale))
        let yLow  = max(0, Int((pointHeight - 46) / 2 * scale))
        let yHigh = min(height, height - yLow)
        guard xHigh > xLow, yHigh > yLow else { return nil }
        var minX = height, maxX = 0, minY = height, maxY = 0
        for y in yLow..<yHigh {
            for x in xLow..<xHigh where isContent(pixel(x, y)) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY else { return nil }

        var width = maxX - minX + 1
        let tall = maxY - minY + 1

        // App icons are square. A wider result means the trim still caught
        // something to the right of it, so clamp back to a square anchored at
        // the icon's own left edge rather than returning the overshoot.
        if width > tall { width = tall }

        // Tightened from 1.4, which passed the 1.29 TikTok overshoot. Near-square
        // only: a wrong icon misattributes who messaged you, so a miss (and a
        // monogram) is the better failure.
        let ratio = Double(width) / Double(tall)
        guard ratio > 0.85, ratio < 1.18, width > height / 5 else { return nil }

        return banner.cropping(to: CGRect(x: minX, y: minY, width: width, height: tall))
    }
}
