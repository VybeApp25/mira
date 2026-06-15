import Cocoa
import CoreGraphics
import ScreenCaptureKit

// Low-level macOS input simulation for Computer Use.
// Screenshots are returned at logical (point) resolution so Claude's
// coordinate space matches what CGEvent expects for mouse positioning.

@MainActor
final class ComputerUseService {
    static let shared = ComputerUseService()
    private init() {}

    var displayWidth:  Int { Int(NSScreen.main?.frame.width  ?? 1440) }
    var displayHeight: Int { Int(NSScreen.main?.frame.height ?? 900)  }

    // MARK: - Screenshot

    // Captures the main display at logical (point) resolution.
    // Uses the same SCK pipeline as ScreenCaptureService, excluding Mira's own windows.
    func screenshot() async -> Data? {
        guard let img = try? await captureLogicalImage() else { return nil }
        guard let tiff = img.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff),
              let png  = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }

    // Crop the main display screenshot to a rect (AppKit bottom-left coordinates).
    func screenshotCropped(to rect: CGRect) async -> NSImage? {
        guard let img = try? await captureLogicalImage() else { return nil }
        let h = img.size.height
        let flipped = CGRect(x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cropped = cg.cropping(to: flipped) else { return img }
        return NSImage(cgImage: cropped, size: rect.size)
    }

    private func captureLogicalImage() async throws -> NSImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "ComputerUse", code: 0, userInfo: [NSLocalizedDescriptionKey: "No display"])
        }
        let ownBundle  = Bundle.main.bundleIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundle }
        let filter     = SCContentFilter(display: display, excludingWindows: ownWindows)

        let config     = SCStreamConfiguration()
        // Use logical (point) resolution so coordinates match CGEvent expectations.
        config.width   = displayWidth
        config.height  = displayHeight
        config.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return NSImage(cgImage: cgImage, size: NSSize(width: displayWidth, height: displayHeight))
    }

    // MARK: - Mouse

    func click(x: Int, y: Int, button: String = "left") {
        let pt = CGPoint(x: x, y: y)
        let (dt, ut, mb): (CGEventType, CGEventType, CGMouseButton) =
            button == "right"  ? (.rightMouseDown, .rightMouseUp, .right)  :
            button == "middle" ? (.otherMouseDown,  .otherMouseUp,  .center) :
                                 (.leftMouseDown,   .leftMouseUp,   .left)
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: dt, mouseCursorPosition: pt, mouseButton: mb)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: ut, mouseCursorPosition: pt, mouseButton: mb)?.post(tap: .cghidEventTap)
    }

    func doubleClick(x: Int, y: Int) {
        multiClick(x: x, y: y, count: 2)
    }

    func tripleClick(x: Int, y: Int) {
        multiClick(x: x, y: y, count: 3)
    }

    private func multiClick(x: Int, y: Int, count: Int64) {
        let pt  = CGPoint(x: x, y: y)
        let src = CGEventSource(stateID: .hidSystemState)
        for cs in 1...count {
            let d = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)
            let u = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,   mouseCursorPosition: pt, mouseButton: .left)
            d?.setIntegerValueField(.mouseEventClickState, value: cs)
            u?.setIntegerValueField(.mouseEventClickState, value: cs)
            d?.post(tap: .cghidEventTap)
            u?.post(tap: .cghidEventTap)
        }
    }

    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int) {
        let s = CGPoint(x: fromX, y: fromY), e = CGPoint(x: toX, y: toY)
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,    mouseCursorPosition: s, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: e, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,      mouseCursorPosition: e, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    func moveMouse(x: Int, y: Int) {
        let pt = CGPoint(x: x, y: y)
        CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// Smoothly glide the cursor from its current spot to (x, y) WITHOUT clicking.
    /// Used by the teaching system to *guide* the user's pointer to a grounded
    /// target — Mira points, the human still performs the action. Posts only
    /// `.mouseMoved` events; never a button-down, so it can't operate anything.
    func glideMouse(toX: Int, toY: Int, steps: Int = 14, totalSeconds: Double = 0.28) async {
        let from = cursorPosition()
        let dx = Double(toX - from.x), dy = Double(toY - from.y)
        let n   = max(1, steps)
        let per = UInt64((totalSeconds / Double(n)) * 1_000_000_000)
        for i in 1...n {
            let t = Double(i) / Double(n)
            let e = 1 - pow(1 - t, 3)   // ease-out: decelerate onto the target
            moveMouse(x: from.x + Int(dx * e), y: from.y + Int(dy * e))
            try? await Task.sleep(nanoseconds: per)
        }
    }

    func cursorPosition() -> (x: Int, y: Int) {
        let loc = NSEvent.mouseLocation
        let h   = NSScreen.main?.frame.height ?? 900
        return (Int(loc.x), Int(h - loc.y))
    }

    // MARK: - Scroll

    func scroll(x: Int, y: Int, direction: String, amount: Int) {
        moveMouse(x: x, y: y)
        var v: Int32 = 0, h: Int32 = 0
        switch direction {
        case "up":    v =  Int32(amount)
        case "down":  v = -Int32(amount)
        case "left":  h = -Int32(amount)
        case "right": h =  Int32(amount)
        default: break
        }
        CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
                units: .line, wheelCount: 2, wheel1: v, wheel2: h, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    // MARK: - Type

    func type(text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for scalar in text.unicodeScalars {
            var ch = UniChar(scalar.value)
            let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            d?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
            u?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
            d?.post(tap: .cghidEventTap)
            u?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Key combos ("cmd+c", "shift+return", "escape", etc.)

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0,  "b": 11, "c": 8,  "d": 2,  "e": 14, "f": 3,  "g": 5,
        "h": 4,  "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45,
        "o": 31, "p": 35, "q": 12, "r": 15, "s": 1,  "t": 17, "u": 32,
        "v": 9,  "w": 13, "x": 7,  "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
        "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        "return": 36, "enter": 36, "tab": 48, "space": 49,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119,
        "pageup": 116, "pagedown": 121,
        "up": 126, "down": 125, "left": 123, "right": 124,
        "f1": 122, "f2": 120, "f3": 99,  "f4": 118, "f5": 96,
        "f6": 97,  "f7": 98,  "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]

    func key(combination: String) {
        var parts = combination.lowercased().components(separatedBy: "+")
        let keyName = parts.removeLast().trimmingCharacters(in: .whitespaces)

        var flags: CGEventFlags = []
        for mod in parts {
            switch mod.trimmingCharacters(in: .whitespaces) {
            case "ctrl",  "control":          flags.insert(.maskControl)
            case "cmd",   "command", "super": flags.insert(.maskCommand)
            case "opt",   "option",  "alt":   flags.insert(.maskAlternate)
            case "shift":                     flags.insert(.maskShift)
            default: break
            }
        }

        let keyCode = Self.keyCodes[keyName] ?? 0
        let src = CGEventSource(stateID: .hidSystemState)
        if let d = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
            d.flags = flags; d.post(tap: .cghidEventTap)
        }
        if let u = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            u.flags = flags; u.post(tap: .cghidEventTap)
        }
    }
}
