import SwiftUI

@MainActor
final class AccentColorService: ObservableObject {
    static let shared = AccentColorService()

    struct Option: Identifiable {
        let id: Int
        let name: String
        let r: Double; let g: Double; let b: Double
        var color: Color { Color(red: r, green: g, blue: b) }
    }

    static let options: [Option] = [
        Option(id: 0, name: "Blue",   r: 0.29, g: 0.62, b: 1.00),
        Option(id: 1, name: "Teal",   r: 0.05, g: 0.80, b: 0.75),
        Option(id: 2, name: "Violet", r: 0.62, g: 0.50, b: 0.92),
        Option(id: 3, name: "Rose",   r: 1.00, g: 0.35, b: 0.55),
        Option(id: 4, name: "Amber",  r: 1.00, g: 0.75, b: 0.20),
        Option(id: 5, name: "Green",  r: 0.20, g: 0.84, b: 0.29),
    ]

    private let defaultsKey = "mira_accent_color_index"
    @Published private(set) var selectedIndex: Int
    var color: Color { Self.options[selectedIndex].color }

    private init() {
        let saved = UserDefaults.standard.integer(forKey: "mira_accent_color_index")
        selectedIndex = saved < Self.options.count ? saved : 0
    }

    func select(_ index: Int) {
        guard index >= 0, index < Self.options.count else { return }
        selectedIndex = index
        UserDefaults.standard.set(index, forKey: defaultsKey)
        NotificationCenter.default.post(name: .miraAccentColorChanged, object: nil)
    }
}
