import SwiftUI
import AppKit

private let surface = Color(red: 0.11, green: 0.11, blue: 0.13)
private let accent  = Color(red: 0.29, green: 0.62, blue: 1.0)

// Shared across HomeTabView and MiraState
let cursorColorOptions: [(name: String, color: Color)] = [
    ("Blue",   Color(red: 0.29, green: 0.62, blue: 1.0)),
    ("Purple", Color(red: 0.75, green: 0.35, blue: 0.95)),
    ("Green",  Color(red: 0.20, green: 0.84, blue: 0.29)),
    ("Red",    Color(red: 1.00, green: 0.27, blue: 0.23)),
    ("Orange", Color(red: 1.00, green: 0.62, blue: 0.04)),
    ("White",  Color.white),
]

struct HomeTabView: View {
    @ObservedObject var miraState: MiraState

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                cursorSection
                integrationsSection
            }
            .padding(16)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Cursor color

    private var cursorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Cursor Color", icon: "cursorarrow.rays")

            HStack(spacing: 10) {
                ForEach(cursorColorOptions, id: \.name) { option in
                    colorSwatch(option)
                }
            }
        }
    }

    private func colorSwatch(_ option: (name: String, color: Color)) -> some View {
        let isSelected = miraState.cursorColorName == option.name
        return Button(action: { miraState.cursorColorName = option.name }) {
            ZStack {
                Circle()
                    .fill(option.color)
                    .frame(width: 28, height: 28)
                    .shadow(color: option.color.opacity(0.5), radius: isSelected ? 6 : 0)
                if isSelected {
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: 34, height: 34)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.2), value: isSelected)
    }

    // MARK: - Integrations

    private var integrationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Active Integrations", icon: "link")

            VStack(spacing: 6) {
                integrationRow("Gmail",           icon: "envelope.fill",   colorHex: 0xEA4335, app: "GMAIL")
                integrationRow("Google Calendar", icon: "calendar",        colorHex: 0x4285F4, app: "GOOGLECALENDAR")
                integrationRow("Notion",          icon: "doc.text.fill",   colorHex: 0xFFFFFF, app: "NOTION")
                integrationRow("Slack",           icon: "message.fill",    colorHex: 0x4A154B, app: "SLACK")
            }
        }
    }

    private func integrationRow(_ name: String, icon: String, colorHex: UInt, app: String) -> some View {
        let connected = miraState.connectedApps.contains(app)
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(hex: colorHex).opacity(0.15))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: colorHex))
            }

            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.8))

            Spacer()

            if connected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(red: 0.20, green: 0.84, blue: 0.29))
                    .labelStyle(.iconOnly)
            } else {
                Button("Connect") {
                    Task { await connectApp(app) }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(accent)
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(surface)
        .cornerRadius(10)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(0.4))
    }

    private func connectApp(_ app: String) async {
        do {
            let url = try await AgentService.shared.connectAppURL(app)
            NSWorkspace.shared.open(url)
            miraState.connectedApps.insert(app)
        } catch {
            // surface error in future
        }
    }
}

// MARK: - Color hex helper

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double(hex         & 0xFF) / 255,
            opacity: alpha
        )
    }
}
