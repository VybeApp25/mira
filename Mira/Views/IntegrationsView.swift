import SwiftUI

// MARK: - Integration definition

struct Integration: Identifiable {
    let id: String          // Composio toolkit slug
    let name: String
    let icon: String        // SF Symbol
    let color: Color
    let tagline: String
    let category: Category

    enum Category: String { case deploy = "Deploy", productivity = "Productivity", dev = "Dev" }
}

private let integrations: [Integration] = [
    Integration(id: "github",         name: "GitHub",           icon: "chevron.left.forwardslash.chevron.right",
                color: Color(red: 0.90, green: 0.90, blue: 0.90),
                tagline: "Issues, PRs, code review",          category: .dev),
    Integration(id: "vercel",         name: "Vercel",           icon: "triangle.fill",
                color: Color(red: 0.90, green: 0.90, blue: 0.90),
                tagline: "Deploy websites instantly",         category: .deploy),
    Integration(id: "netlify",        name: "Netlify",          icon: "bolt.fill",
                color: Color(red: 0.06, green: 0.83, blue: 0.68),
                tagline: "Deploy and host websites",          category: .deploy),
    Integration(id: "gmail",          name: "Gmail",            icon: "envelope.fill",
                color: Color(red: 0.93, green: 0.26, blue: 0.21),
                tagline: "Read and send emails",              category: .productivity),
    Integration(id: "googlecalendar", name: "Google Calendar",  icon: "calendar",
                color: Color(red: 0.17, green: 0.67, blue: 0.39),
                tagline: "View and create events",            category: .productivity),
    Integration(id: "googledrive",    name: "Google Drive",     icon: "folder.fill",
                color: Color(red: 0.25, green: 0.55, blue: 0.93),
                tagline: "Browse and share files",            category: .productivity),
    Integration(id: "googledocs",     name: "Google Docs",      icon: "doc.fill",
                color: Color(red: 0.25, green: 0.55, blue: 0.93),
                tagline: "Read and edit documents",           category: .productivity),
    Integration(id: "googlesheets",   name: "Google Sheets",    icon: "tablecells.fill",
                color: Color(red: 0.17, green: 0.67, blue: 0.39),
                tagline: "Read and update spreadsheets",      category: .productivity),
    Integration(id: "notion",         name: "Notion",           icon: "doc.text.fill",
                color: Color(red: 0.85, green: 0.85, blue: 0.85),
                tagline: "Read and write pages",              category: .productivity),
    Integration(id: "slack",          name: "Slack",            icon: "bubble.left.fill",
                color: Color(red: 0.44, green: 0.12, blue: 0.59),
                tagline: "Send messages to channels",         category: .productivity),
    Integration(id: "linear",         name: "Linear",           icon: "square.and.pencil",
                color: Color(red: 0.36, green: 0.35, blue: 0.94),
                tagline: "Track issues and projects",         category: .productivity),
    Integration(id: "airtable",       name: "Airtable",         icon: "square.grid.2x2.fill",
                color: Color(red: 1.0, green: 0.45, blue: 0.20),
                tagline: "Read and write bases, tables",      category: .productivity),
]

// MARK: - View

struct IntegrationsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var status:       [String: Bool] = [:]
    @State private var loading               = false
    @State private var connecting:   String? = nil
    @State private var disconnecting: String? = nil
    @State private var confirmDisconnect: Integration? = nil
    @State private var errorMsg:     String? = nil
    @State private var searchText            = ""
    @State private var agentOnline           = false

    private let accent = DS.Colors.accent
    private let green  = Color(red: 0.20, green: 0.84, blue: 0.29)

    // MARK: - Computed lists

    private var filtered: [Integration] {
        guard !searchText.isEmpty else { return integrations }
        return integrations.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.tagline.localizedCaseInsensitiveContains(searchText)
        }
    }
    private var active:    [Integration] { filtered.filter { status[$0.id] == true } }
    private var available: [Integration] { filtered.filter { status[$0.id] != true } }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.12).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().background(Color.white.opacity(0.08))
                agentBanner
                Divider().background(Color.white.opacity(0.06))
                searchBar
                Divider().background(Color.white.opacity(0.06))

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        if !active.isEmpty {
                            sectionHeader("Active", count: active.count)
                            VStack(spacing: 5) {
                                ForEach(active) { integrationRow($0) }
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                        }

                        if !available.isEmpty {
                            sectionHeader("Available", count: nil)
                            VStack(spacing: 5) {
                                ForEach(available) { integrationRow($0) }
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 16)
                        }

                        if filtered.isEmpty {
                            Text("No integrations match \"\(searchText)\"")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.30))
                                .padding(.top, 32)
                        }

                        if let err = errorMsg {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundColor(.red.opacity(0.70))
                                .padding(.horizontal, 14)
                                .padding(.bottom, 12)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .frame(width: 360, height: 560)
        .confirmationDialog(
            "Disconnect \(confirmDisconnect?.name ?? "")?",
            isPresented: Binding(get: { confirmDisconnect != nil },
                                 set: { if !$0 { confirmDisconnect = nil } }),
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                guard let item = confirmDisconnect else { return }
                confirmDisconnect = nil
                Task { await disconnect(item) }
            }
            Button("Cancel", role: .cancel) { confirmDisconnect = nil }
        } message: {
            Text("Mira will no longer be able to access \(confirmDisconnect?.name ?? "") until you reconnect.")
        }
        .task { await refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Integrations")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Spacer()
            if loading {
                ProgressView().progressViewStyle(.circular).scaleEffect(0.6).tint(accent)
            } else {
                Button { Task { await refresh() } } label: {
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

    // MARK: - Agent banner

    private var agentBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(agentOnline ? green : Color(red: 1.0, green: 0.80, blue: 0.20))
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

            if agentOnline {
                let connCount = status.values.filter { $0 }.count
                if connCount > 0 {
                    Text("\(connCount) connected")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(green.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .task {
            for _ in 0..<10 {
                if await AgentService.shared.checkHealth() { agentOnline = true; return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.30))
            TextField("Search apps…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.05))
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.30))
                .kerning(0.8)
            if let n = count {
                Text("\(n)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(green.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    // MARK: - Integration row

    private func integrationRow(_ item: Integration) -> some View {
        let connected    = status[item.id] == true
        let isConnecting = connecting == item.id
        let isDisconnecting = disconnecting == item.id

        return HStack(spacing: 11) {
            // App icon badge
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(item.color.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(item.color)
            }

            // Name + tagline
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(item.tagline)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.38))
            }

            Spacer()

            // Action / status
            if isConnecting || isDisconnecting {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.55)
                    .tint(accent)
                    .frame(width: 72)
            } else if connected {
                HStack(spacing: 5) {
                    Circle()
                        .fill(green)
                        .frame(width: 6, height: 6)
                    Text("Connected")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(green)
                    Button {
                        confirmDisconnect = item
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white.opacity(0.25))
                            .frame(width: 18, height: 18)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button("Connect") {
                    Task { await connect(item) }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(accent)
                .padding(.horizontal, 13)
                .padding(.vertical, 5)
                .background(accent.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(accent.opacity(0.25), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(connected ? green.opacity(0.05) : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(connected ? green.opacity(0.18) : Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Actions

    private func refresh() async {
        loading = true; errorMsg = nil
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
        connecting = item.id; errorMsg = nil
        AudioCueService.shared.playConnectionQuestion()
        do {
            let url = try await AgentService.shared.connectAppURL(item.id)
            NSWorkspace.shared.open(url)
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let connected = try await AgentService.shared.connections()
                if connected.contains(item.id) {
                    status[item.id] = true
                    IntegrationContextService.shared.update(connected: Set(connected))
                    AudioCueService.shared.playAgentComplete()
                    break
                }
            }
        } catch {
            errorMsg = "Could not connect \(item.name). Is the agent service running?"
        }
        connecting = nil
    }

    private func disconnect(_ item: Integration) async {
        disconnecting = item.id; errorMsg = nil
        do {
            try await AgentService.shared.disconnect(item.id)
            status[item.id] = false
            let stillConnected = status.filter { $0.value }.map(\.key)
            IntegrationContextService.shared.update(connected: Set(stillConnected))
        } catch {
            errorMsg = "Could not disconnect \(item.name)."
        }
        disconnecting = nil
    }
}

// MARK: - Integration suggestion banner

/// Shown in chat when a composio-backed route fires but the toolkit isn't connected.
struct IntegrationSuggestionBanner: View {
    let name: String
    let slug: String
    let onConnect: () -> Void
    let onDismiss: () -> Void

    private let accent = DS.Colors.accent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 13))
                .foregroundColor(accent)

            VStack(alignment: .leading, spacing: 1) {
                Text("Connect \(name)?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Text("Unlock this task by connecting \(name) in Settings.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.40))
            }

            Spacer()

            Button("Connect") { onConnect() }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .buttonStyle(.plain)

            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.25))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(accent.opacity(0.07))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accent.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
