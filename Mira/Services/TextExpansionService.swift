import AppKit
import Carbon

// Monitors keystrokes via CGEventTap. When a sequence ending in Space or Return
// matches a registered shortcut (e.g. ";em"), it deletes the typed shortcut and
// types the expansion instead using CGEvent keystroke injection.
//
// Requires Accessibility permission — Mira already requests this.

final class TextExpansionService: ObservableObject {
    static let shared = TextExpansionService()

    private let udKey = "mira.textExpansions"
    @Published private(set) var expansions: [TextExpansion] = []

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var buffer = ""
    private let maxBuffer = 64

    private init() { load() }

    // MARK: - Public API

    func start() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let svc = Unmanaged<TextExpansionService>.fromOpaque(refcon).takeUnretainedValue()
                return svc.handle(event: event)
            },
            userInfo: Unmanaged.passRetained(self).toOpaque()
        )

        guard let tap = eventTap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    func add(_ expansion: TextExpansion) {
        expansions.removeAll { $0.shortcut == expansion.shortcut }
        expansions.append(expansion)
        save()
    }

    func remove(id: UUID) {
        expansions.removeAll { $0.id == id }
        save()
    }

    func update(_ expansion: TextExpansion) {
        if let i = expansions.firstIndex(where: { $0.id == expansion.id }) {
            expansions[i] = expansion
            save()
        }
    }

    // MARK: - Event handler

    private func handle(event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags   = event.flags

        // Ignore modified presses (⌘ / ⌃ / ⌥)
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        if !flags.intersection(modifiers).isEmpty {
            buffer = ""
            return Unmanaged.passRetained(event)
        }

        // Backspace: trim buffer
        if keyCode == 51 {
            if !buffer.isEmpty { buffer.removeLast() }
            return Unmanaged.passRetained(event)
        }

        // Space (49) / Return (36) / Tab (48) — check for expansion trigger
        if keyCode == 49 || keyCode == 36 || keyCode == 48 {
            if let match = expansions.first(where: { buffer.hasSuffix($0.shortcut) }) {
                let deleteCount = match.shortcut.count
                let expansion   = match.expansion
                buffer = ""
                Task { @MainActor in self.expand(expansion, deletingChars: deleteCount) }
                return nil  // swallow the trigger key
            }
            buffer = ""
            return Unmanaged.passRetained(event)
        }

        // Escape / arrow keys: reset buffer
        if keyCode == 53 || (keyCode >= 123 && keyCode <= 126) {
            buffer = ""
            return Unmanaged.passRetained(event)
        }

        // Accumulate character
        if let ch = unicodeChar(from: event) {
            buffer.append(ch)
            if buffer.count > maxBuffer { buffer.removeFirst(buffer.count - maxBuffer) }
        }

        return Unmanaged.passRetained(event)
    }

    @MainActor
    private func expand(_ text: String, deletingChars: Int) {
        let src = CGEventSource(stateID: .combinedSessionState)

        // Delete the typed shortcut characters
        for _ in 0..<deletingChars {
            CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true)?.post(tap: .cgSessionEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false)?.post(tap: .cgSessionEventTap)
        }

        // Put expansion on clipboard and ⌘V into target app
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        board.clearContents()
        board.setString(text, forType: .string)

        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        cmdDown?.flags = .maskCommand
        cmdDown?.post(tap: .cgSessionEventTap)
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        cmdUp?.flags = .maskCommand
        cmdUp?.post(tap: .cgSessionEventTap)

        // Restore previous clipboard content after paste lands
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            board.clearContents()
            if let s = saved { board.setString(s, forType: .string) }
        }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(expansions) {
            UserDefaults.standard.set(data, forKey: udKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let saved = try? JSONDecoder().decode([TextExpansion].self, from: data)
        else { return }
        expansions = saved
    }
}

// MARK: - Unicode character from CGEvent

private func unicodeChar(from event: CGEvent) -> Character? {
    var actualLength: Int = 0
    var buffer = [UniChar](repeating: 0, count: 4)
    buffer.withUnsafeMutableBufferPointer { ptr in
        event.keyboardGetUnicodeString(
            maxStringLength: 4,
            actualStringLength: &actualLength,
            unicodeString: ptr.baseAddress!
        )
    }
    guard actualLength > 0 else { return nil }
    let str = String(utf16CodeUnits: Array(buffer.prefix(actualLength)), count: actualLength)
    return str.first
}
