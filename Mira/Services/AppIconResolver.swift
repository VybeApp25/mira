// AppIconResolver.swift
// The posting app's real icon for a notification, the way the native banner
// shows it — resolved from a bundle identifier when there is one, and from the
// display name when that is all the accessibility tree gives.
//
// WHY THIS IS NOT JUST NSWorkspace.icon(forFile:).
//
// Two traps, both found by testing the chain before wiring it up.
//
//   1. `fullPath(forApplication:)` MATCHES LOOSELY. Asked for "Pages" on this
//      Mac it returns "/Applications/Pages Creator Studio.app" — a different
//      program entirely. An icon is an identity claim, and a confidently wrong
//      one is worse than none: a message that looks like it came from Pages when
//      it did not is a bug you act on before you notice. Every name-based hit is
//      therefore verified against the resolved bundle before it is accepted.
//
//   2. NOT EVERY NOTIFICATION HAS AN APP ON THIS MAC. iPhone alerts mirrored
//      over Continuity come from apps that were never installed here — Vivint,
//      myQ, Snapchat, X. Checked for a cached icon macOS might keep for them:
//      the record blob carries only text (`titl`/`subt`/`body`), there is no
//      icon cache under the usernoted group container, and the banner exposes no
//      image element over accessibility. So there is genuinely nothing to read,
//      and those fall back to a monogram rather than a generic bell — at least
//      it distinguishes one app from another.

import AppKit
import SwiftUI

@MainActor
enum AppIconResolver {

    /// Resolved icons, including the misses. Caching nil matters as much as
    /// caching a hit: the fallbacks below touch the filesystem, and the strip
    /// re-renders on every tick of the rotation.
    private static var cache: [String: NSImage?] = [:]

    /// The posting app's icon, or nil when the app isn't on this Mac.
    static func icon(bundleID: String?, appName: String?) -> NSImage? {
        let key = "\(bundleID ?? "")|\(appName ?? "")"
        if let cached = cache[key] { return cached }
        let resolved = lookup(bundleID: bundleID, appName: appName)
        cache[key] = resolved
        return resolved
    }

    private static func lookup(bundleID: String?, appName: String?) -> NSImage? {
        // A bundle identifier is exact, so it is tried first and trusted.
        if let bundleID, !bundleID.isEmpty {
            // Notification Center namespaces some senders — "_system_center_:"
            // for system agents, "_web_center_:" for web push. The real
            // identifier is what follows the colon.
            let cleaned = bundleID.contains(":")
                ? String(bundleID.split(separator: ":", maxSplits: 1).last ?? "")
                : bundleID
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cleaned) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }

        guard let appName, !appName.isEmpty else { return nil }

        // A running app is unambiguous — the name came from the same list.
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame
        }), let icon = running.icon {
            return icon
        }

        // Installed but not running. Verified, because this is the loose matcher.
        if let path = NSWorkspace.shared.fullPath(forApplication: appName),
           bundleMatches(path: path, name: appName) {
            return NSWorkspace.shared.icon(forFile: path)
        }

        // Last resort: an exact filename in the usual places. No fuzziness here,
        // so no verification needed beyond the name itself.
        for directory in ["/Applications",
                          "/System/Applications",
                          "/System/Applications/Utilities",
                          "/Applications/Utilities",
                          NSHomeDirectory() + "/Applications"] {
            let path = directory + "/" + appName + ".app"
            if FileManager.default.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        }

        return nil
    }

    /// Does the bundle we landed on actually call itself what we asked for?
    /// Accepts either the file name or one of the bundle's own display names, so
    /// "Script Editor" still resolves while "Pages" no longer matches "Pages
    /// Creator Studio".
    private static func bundleMatches(path: String, name: String) -> Bool {
        let fileName = (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".app", with: "")
        if fileName.caseInsensitiveCompare(name) == .orderedSame { return true }

        guard let bundle = Bundle(path: path) else { return false }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = bundle.object(forInfoDictionaryKey: key) as? String,
               value.caseInsensitiveCompare(name) == .orderedSame {
                return true
            }
        }
        return false
    }

    /// Stable colour for an app with no icon, so Vivint and Snapchat at least
    /// stay visually distinct from each other and from themselves over time.
    /// Hashed by hand rather than with `hashValue`, which is seeded per process
    /// and would give the same app a different colour on every launch.
    static func monogramColor(for name: String) -> Color {
        var hash: UInt64 = 5381
        for byte in name.lowercased().utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return Color(hue: Double(hash % 360) / 360.0, saturation: 0.55, brightness: 0.80)
    }

    static func monogram(for name: String) -> String {
        let letter = name.trimmingCharacters(in: .whitespaces).first.map(String.init) ?? "?"
        return letter.uppercased()
    }
}

// MARK: - View

/// The posting app's icon, with a monogram fallback. Shared by the collapsed
/// strip and the notifications list so one alert looks the same in both.
struct NotificationAppIcon: View {

    let appName: String?
    var bundleID: String = ""
    /// Drawn when the app cannot be resolved AND there is no name to monogram.
    var fallbackSymbol: String = "bell.fill"
    var size: CGFloat = 14
    var tint: Color = .white.opacity(0.65)

    var body: some View {
        if let icon = AppIconResolver.icon(bundleID: bundleID, appName: appName) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else if let appName, !appName.isEmpty {
            Text(AppIconResolver.monogram(for: appName))
                .font(.system(size: size * 0.58, weight: .bold))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .fill(AppIconResolver.monogramColor(for: appName))
                )
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.72, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: size, height: size)
        }
    }
}
