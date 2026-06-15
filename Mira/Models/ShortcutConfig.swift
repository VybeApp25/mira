import AppKit
import Carbon

// MARK: - Config

struct ShortcutConfig: Codable, Equatable {
    var keyCode:    UInt32
    var carbonMods: UInt32   // Carbon modifier flags (controlKey | optionKey etc.)
    var displayKey: String   // single character shown in UI, e.g. "V"

    static let defaultVoice = ShortcutConfig(
        keyCode:    UInt32(kVK_ANSI_V),
        carbonMods: UInt32(controlKey | optionKey),
        displayKey: "V"
    )
    static let defaultText = ShortcutConfig(
        keyCode:    UInt32(kVK_ANSI_T),
        carbonMods: UInt32(controlKey | optionKey),
        displayKey: "T"
    )

    /// Human-readable display string, e.g. "⌃⌥V"
    var displayString: String {
        var s = ""
        if carbonMods & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonMods & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonMods & UInt32(cmdKey)     != 0 { s += "⌘" }
        if carbonMods & UInt32(shiftKey)   != 0 { s += "⇧" }
        return s + displayKey.uppercased()
    }

    /// A binding is usable only if it has a real key character and at least one modifier.
    /// Rejects legacy corrupted configs whose displayKey is empty or a non-printable
    /// control character (caused by recording with `event.characters` under Control).
    var isValid: Bool {
        guard carbonMods != 0 else { return false }
        guard let scalar = displayKey.unicodeScalars.first else { return false }
        return scalar.value >= 0x20 && scalar.value != 0x7F
    }

    /// Returns self if valid, otherwise the supplied fallback.
    func validated(default fallback: ShortcutConfig) -> ShortcutConfig {
        isValid ? self : fallback
    }

    /// Convert NSEvent.ModifierFlags → Carbon modifier bitmask.
    static func carbonMods(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey)  }
        if flags.contains(.command) { m |= UInt32(cmdKey)     }
        if flags.contains(.shift)   { m |= UInt32(shiftKey)   }
        return m
    }
}

// MARK: - Store

/// UserDefaults-backed singleton holding the two configurable shortcuts.
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    @Published var voice: ShortcutConfig { didSet { persist() } }
    @Published var text:  ShortcutConfig { didSet { persist() } }

    private init() {
        voice = Self.load("mira_shortcut_voice")?.validated(default: .defaultVoice) ?? .defaultVoice
        text  = Self.load("mira_shortcut_text")?.validated(default: .defaultText)  ?? .defaultText
    }

    // MARK: - Private

    private func persist() {
        Self.save("mira_shortcut_voice", voice)
        Self.save("mira_shortcut_text",  text)
        NotificationCenter.default.post(name: .miraShortcutsChanged, object: nil)
    }

    private static func save(_ key: String, _ config: ShortcutConfig) {
        UserDefaults.standard.set(try? JSONEncoder().encode(config), forKey: key)
    }

    private static func load(_ key: String) -> ShortcutConfig? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ShortcutConfig.self, from: data)
    }
}
