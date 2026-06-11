import SwiftUI

// MARK: - Integration definition

struct Integration: Identifiable {
    let id: String          // Composio toolkit slug, lowercase
    let name: String
    let icon: String        // SF Symbol
    let color: Color
    let tagline: String     // one-line description shown in the row
}

private let integrations: [Integration] = [
    // Publishing
    Integration(id: "vercel",         name: "Vercel",           icon: "triangle.fill",
                color: Color(red: 0.90, green: 0.90, blue: 0.90),
                tagline: "Deploy websites instantly"),
    Integration(id: "netlify",        name: "Netlify",          icon: "bolt.fill",
                color: Color(red: 0.06, green: 0.83, blue: 0.68),
                tagline: "Deploy and host websites"),
    Integration(id: "github",         name: "GitHub",           icon: "chevron.left.forwardslash.chevron.right",
                color: Color(red: 0.90, green: 0.90, blue: 0.90),
                tagline: "Issues, PRs, and GitHub Pages"),
    // Productivity
    Integration(id: "gmail",          name: "Gmail",            icon: "envelope.fill",
                color: Color(red: 0.93, green: 0.26, blue: 0.21),
                tagline: "Read and send emails"),
    Integration(id: "googlecalendar", name: "Google Calendar",  icon: "calendar",
                color: Color(red: 0.17, green: 0.67, blue: 0.39),
                tagline: "View and create events"),
    Integration(id: "notion",         name: "Notion",           icon: "doc.text.fill",
                color: Color(red: 0.85, green: 0.85, blue: 0.85),
                tagline: "Read and write pages"),
    Integration(id: "slack",          name: "Slack",            icon: "bubble.left.fill",
                color: Color(red: 0.44, green: 0.12, blue: 0.59),
                tagline: "Send messages to channels"),
    Integration(id: "linear",         name: "Linear",           icon: "square.and.pencil",
                color: Color(red: 0.36, green: 0.35, blue: 0.94),
                tagline: "Track issues and projects"),
]

// MARK: - View

struct IntegrationsView: View {
    @Environment(\.dismiss) private var dismiss

    // slug → true if connected
    @State private var status: [String: Bool] = [:]
    @State private var loading = false
    @State private var connecting: String? = nil  // slug being connected right now
    @State private var errorMsg: String? = nil

    private let accent = Color(red: 0.29, green: 0.62, blue: 1.0)

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.12).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Divider().background(Color.white.opacity(0.08))

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        agentServiceBanner
                        Divider().background(Color.white.opacity(0.06)).padding(.horizontal, 18)

                        VStack(spacing: 6) {
                            ForEach(integrations) { integration in
                                integrationRow(integration)
                            }
                        }
                        .padding(18)

                        if let err = errorMsg {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundColor(.red.opacity(0.7))
                                .padding(.horizontal, 18)
                                .padding(.bottom, 12)
                        }
                    }
                }
            }
        }
        .frame(width: 360, height: 520)
        .task { await refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Connected Apps")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Spacer()
            if loading {
                ProgressView().progressViewStyle(.circular).scaleEffect(0.6).tint(accent)
            } else {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
            Button("Done") { dismiss() }
                .foregroundColor(accent)
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .padding(.leading, 12)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Agent service banner

    @State private var agentOnline = false

    private var agentServiceBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(agentOnline
                      ? Color(red: 0.20, green: 0.84, blue: 0.29)
                      : Color(red: 1.0, green: 0.80, blue: 0.20))
                .frame(width: 7, height: 7)
                .animation(.easeInOut(duration: 0.3), value: agentOnline)

            VStack(alignment: .leading, spacing: 1) {
                Text(agentOnline ? "Agent service ready" : "Agent service starting…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.80))
                Text("Connected apps are available in voice and text chat.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .task {
            // Poll until ready — it starts with the app so usually < 3s
            for _ in 0..<10 {
                if await AgentService.shared.checkHealth() { agentOnline = true; return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - Integration row

    private func integrationRow(_ item: Integration) -> some View {
        let connected = status[item.id] == true
        let isConnecting = connecting == item.id

        return HStack(spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(item.color.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(item.color)
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(item.tagline)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.40))
            }

            Spacer()

            // Status + action
            if isConnecting {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .tint(accent)
                    .frame(width: 70)
            } else if connected {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color(red: 0.20, green: 0.84, blue: 0.29))
                    Text("Connected")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(red: 0.20, green: 0.84, blue: 0.29))
                }
            } else {
                Button("Connect") {
                    Task { await connect(item) }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(connected
                        ? Color(red: 0.20, green: 0.84, blue: 0.29).opacity(0.25)
                        : Color.white.opacity(0.06))
        )
    }

    // MARK: - Actions

    private func refresh() async {
        loading = true
        errorMsg = nil
        do {
            let connected = try await AgentService.shared.connections()
            var map: [String: Bool] = [:]
            for id in integrations.map(\.id) { map[id] = connected.contains(id) }
            status = map
            IntegrationContextService.shared.update(connected: Set(connected))
        } catch {
            errorMsg = "Could not load connections — is the agent service running?"
        }
        loading = false
    }

    private func connect(_ item: Integration) async {
        connecting = item.id
        errorMsg = nil
        do {
            let url = try await AgentService.shared.connectAppURL(item.id)
            NSWorkspace.shared.open(url)
            // Poll for up to 60 s waiting for the OAuth flow to complete
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 s
                let connected = try await AgentService.shared.connections()
                if connected.contains(item.id) {
                    status[item.id] = true
                    IntegrationContextService.shared.update(connected: Set(connected))
                    break
                }
            }
        } catch {
            errorMsg = "Could not start connection for \(item.name). Is the agent service running?"
        }
        connecting = nil
    }
}
