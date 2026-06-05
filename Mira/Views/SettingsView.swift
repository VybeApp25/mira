import SwiftUI
import Carbon

struct SettingsView: View {
    @ObservedObject var state: MiraState
    @ObservedObject private var memory   = MemoryStore.shared
    @ObservedObject private var shortcuts = ShortcutStore.shared
    @Environment(\.dismiss) var dismiss
    @State private var keyInput      = ""
    @State private var saved         = false
    @State private var showOverride  = false
    @State private var selectedVoice: MiraVoice = MiraVoice.saved
    @State private var recording:    RecordingTarget? = nil
    @State private var keyMonitor:    Any? = nil
    @State private var showTraces        = false
    @State private var showIntegrations  = false
    @AppStorage(HoverPreferences.companionKey)   private var screenCompanionEnabled = true
    @AppStorage(HoverPreferences.sensitivityKey) private var sensitivityRaw = "balanced"
    @State private var hoverCategories: [String: CategoryStats] = [:]
    @ObservedObject private var hoverHistory = HoverHistoryStore.shared
    @State private var showHoverHistory = false

    enum RecordingTarget { case voice, text }

    private let accent = Color(red: 0.29, green: 0.62, blue: 1.0)

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.12).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().background(Color.white.opacity(0.08))

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        keySection
                        Divider().background(Color.white.opacity(0.08))
                        connectedAppsButton
                        Divider().background(Color.white.opacity(0.08))
                        shortcutsSection
                        Divider().background(Color.white.opacity(0.08))
                        screenCompanionSection
                        Divider().background(Color.white.opacity(0.08))
                        voiceSection
                        Divider().background(Color.white.opacity(0.08))
                        memorySection
                        Divider().background(Color.white.opacity(0.08))
                        usageSection
                        Divider().background(Color.white.opacity(0.08))
                        toolActivityButton
                    }
                    .padding(18)
                }
            }
        }
        .frame(width: 360, height: 720)
        .onAppear {
            keyInput = state.userAPIKey
            hoverCategories = HoverPreferences.shared.categories
        }
        .sheet(isPresented: $showTraces)        { ToolTraceView() }
        .sheet(isPresented: $showIntegrations)  { IntegrationsView() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Spacer()
            Button("Done") { dismiss() }
                .foregroundColor(accent)
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - API key section

    @ViewBuilder
    private var keySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("API Key", systemImage: "key.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            if state.usingBundledKey {
                // Bundled key is active — show green status, offer override
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bundled key active")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text("No setup needed — you're good to go.")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.40))
                    }
                    Spacer()
                    Button(showOverride ? "Cancel" : "Override") {
                        showOverride.toggle()
                        if !showOverride { keyInput = "" }
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.green.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.20)))
                .cornerRadius(8)

                if showOverride {
                    overrideField
                }
            } else if state.hasKey {
                // User's own key is active
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(accent)
                        .font(.system(size: 12))
                    Text("Custom key active")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                    Button("Clear") {
                        state.userAPIKey = ""
                        keyInput = ""
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .buttonStyle(.plain)
                }
                overrideField
            } else {
                // No bundled key configured
                overrideField
                Text("Get a key at console.anthropic.com")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.30))
            }
        }
    }

    private var overrideField: some View {
        VStack(spacing: 8) {
            SecureField("sk-ant-api03-...", text: $keyInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)
                .padding(10)
                .background(Color.white.opacity(0.06))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10)))

            Button(action: saveKey) {
                Text(saved ? "Saved ✓" : "Save Key")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundColor(.white)
                    .background(accent)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Shortcuts section

    @ViewBuilder
    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Keyboard Shortcuts", systemImage: "keyboard")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            shortcutRow(label: "Talk to Mira", config: $shortcuts.voice, target: .voice)
            shortcutRow(label: "Text Mira",    config: $shortcuts.text,  target: .text)

            if recording != nil {
                Text("Press a key combo — Esc to cancel. Requires ⌃, ⌥, or ⌘.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.28))
            }
        }
        .onDisappear { stopRecording() }
    }

    private func shortcutRow(label: String, config: Binding<ShortcutConfig>, target: RecordingTarget) -> some View {
        let isRecording = recording == target
        return HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.80))
            Spacer()
            Button(action: { isRecording ? stopRecording() : startRecording(target, config: config) }) {
                Text(isRecording ? "Press shortcut…" : config.wrappedValue.displayString)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(isRecording ? accent.opacity(0.7) : .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isRecording
                                ? accent.opacity(0.15)
                                : Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isRecording ? accent.opacity(0.5) : Color.white.opacity(0.10))
                    )
                    .animation(.easeInOut(duration: 0.15), value: isRecording)
            }
            .buttonStyle(.plain)

            if config.wrappedValue != (target == .voice ? .defaultVoice : .defaultText) {
                Button(action: {
                    stopRecording()
                    config.wrappedValue = target == .voice ? .defaultVoice : .defaultText
                }) {
                    Image(systemName: "arrow.uturn.left")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.25))
                }
                .buttonStyle(.plain)
                .help("Restore default")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Screen Companion section

    private var currentSensitivity: HoverSensitivity {
        HoverSensitivity(rawValue: sensitivityRaw) ?? .balanced
    }

    @ViewBuilder
    private var screenCompanionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Screen Companion", systemImage: "eye")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            // Permission badge
            if false { // permission is checked live by SCK; CGPreflightScreenCaptureAccess is unreliable on Sequoia
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Screen Recording not granted")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                        Text("Hover insights won't work without it.")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.40))
                    }
                    Spacer()
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                    .font(.system(size: 11))
                    .foregroundColor(accent)
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.20)))
                .cornerRadius(8)
            }

            // Toggle
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Smart hover insights")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.80))
                    Text("Mira watches your cursor and surfaces insights as you work.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $screenCompanionEnabled)
                    .toggleStyle(.switch)
                    .tint(accent)
                    .labelsHidden()
                    .onChange(of: screenCompanionEnabled) { _ in
                        NotificationCenter.default.post(name: .miraScreenCompanionChanged, object: nil)
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Sensitivity
            if screenCompanionEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sensitivity")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.40))

                    HStack(spacing: 6) {
                        ForEach(HoverSensitivity.allCases, id: \.rawValue) { s in
                            let selected = s == currentSensitivity
                            Button {
                                sensitivityRaw = s.rawValue
                                HoverPreferences.shared.sensitivity = s
                            } label: {
                                VStack(spacing: 2) {
                                    Text(s.label)
                                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                                        .foregroundColor(selected ? .white : .white.opacity(0.45))
                                    Text(s.subtitle)
                                        .font(.system(size: 9))
                                        .foregroundColor(selected ? accent.opacity(0.7) : .white.opacity(0.25))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(selected ? accent.opacity(0.15) : Color.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(selected ? accent.opacity(0.4) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Engagement bars
            let matureCategories = hoverCategories
                .filter { $0.value.shown >= 4 }
                .sorted { $0.value.engagementScore > $1.value.engagementScore }

            if !matureCategories.isEmpty {
                VStack(spacing: 4) {
                    ForEach(matureCategories, id: \.key) { category, stats in
                        HStack(spacing: 8) {
                            Text(category)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.55))
                                .frame(width: 72, alignment: .leading)

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.white.opacity(0.07))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(engagementColor(stats.engagementScore))
                                        .frame(width: geo.size.width * stats.engagementScore)
                                }
                            }
                            .frame(height: 5)

                            Text("\(Int(stats.engagementScore * 100))%")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.35))
                                .frame(width: 32, alignment: .trailing)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button("Reset engagement stats") {
                    HoverPreferences.shared.resetStats()
                    hoverCategories = [:]
                }
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
                .buttonStyle(.plain)
            }

            // Hover history
            if !hoverHistory.entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { showHoverHistory.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Text("Recent Insights")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.white.opacity(0.40))
                                Image(systemName: showHoverHistory ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.25))
                                Text("\(hoverHistory.entries.count)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.25))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.white.opacity(0.07))
                                    .clipShape(Capsule())
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if showHoverHistory {
                            Button("Clear") { hoverHistory.clear() }
                                .font(.system(size: 11))
                                .foregroundColor(.red.opacity(0.6))
                                .buttonStyle(.plain)
                        }
                    }

                    if showHoverHistory {
                        VStack(spacing: 3) {
                            ForEach(hoverHistory.entries) { entry in
                                hoverEntryRow(entry)
                            }
                        }
                    }
                }
            }
        }
    }

    private func hoverEntryRow(_ entry: HoverEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.80))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let app = entry.appName {
                        Text(app)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.30))
                    }
                    if let reason = entry.reason {
                        Text("· \(reason)")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.25))
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            Text(relativeTime(entry.timestamp))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.20))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s/60)m" }
        return "\(s/3600)h"
    }

    private func engagementColor(_ score: Double) -> Color {
        switch score {
        case 0.60...: return Color(red: 0.20, green: 0.84, blue: 0.29)
        case 0.30...: return Color(red: 1.0,  green: 0.75, blue: 0.20)
        default:      return Color.white.opacity(0.25)
        }
    }

    // MARK: - Shortcut recording

    private func startRecording(_ target: RecordingTarget, config: Binding<ShortcutConfig>) {
        stopRecording()
        recording = target
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            // Escape cancels
            if Int(event.keyCode) == kVK_Escape { stopRecording(); return nil }

            let mods = event.modifierFlags.intersection([.control, .option, .command, .shift])
            guard !mods.isEmpty else { return event }  // require at least one modifier

            let carbonMods = ShortcutConfig.carbonMods(from: mods)
            let key = event.characters?.uppercased() ?? "?"
            config.wrappedValue = ShortcutConfig(keyCode: UInt32(event.keyCode),
                                                  carbonMods: carbonMods,
                                                  displayKey: key)
            stopRecording()
            return nil  // consume
        }
    }

    private func stopRecording() {
        recording = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    // MARK: - Voice section

    @ViewBuilder
    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Mira Voice", systemImage: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            VStack(spacing: 4) {
                ForEach(MiraVoice.allCases) { v in
                    Button {
                        MiraVoice.saved = v
                        selectedVoice = v
                        NotificationCenter.default.post(name: .miraVoiceChanged, object: nil)
                    } label: {
                        HStack {
                            Text(v.label)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.85))
                            Spacer()
                            if selectedVoice == v {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(accent)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(selectedVoice == v ? accent.opacity(0.10) : Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("OpenAI Realtime API · gpt-4o-realtime-preview")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.25))
        }
    }

    // MARK: - Memory section

    @ViewBuilder
    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Memory", systemImage: "brain")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                if !memory.memories.isEmpty {
                    Button("Clear All") { memory.clear() }
                        .font(.system(size: 11))
                        .foregroundColor(.red.opacity(0.7))
                        .buttonStyle(.plain)
                }
            }

            // Confidence breakdown
            if !memory.memories.isEmpty {
                HStack(spacing: 12) {
                    memStatBadge(memory.memories.count, label: "total", color: .white.opacity(0.4))
                    memStatBadge(memory.memories.filter { $0.confidenceTier == .high   }.count,
                                 label: "high",   color: Color(red: 0.20, green: 0.84, blue: 0.29))
                    memStatBadge(memory.memories.filter { $0.confidenceTier == .medium }.count,
                                 label: "medium", color: Color(red: 1.0,  green: 0.75, blue: 0.20))
                    memStatBadge(memory.memories.filter { $0.confidenceTier == .low    }.count,
                                 label: "low",    color: Color(red: 0.75, green: 0.75, blue: 0.75))
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color.white.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if memory.memories.isEmpty {
                Text("No memories yet. Mira will learn your preferences over time.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.28))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 3) {
                    ForEach(memory.memories.sorted { $0.confidence > $1.confidence }) { mem in
                        memoryRow(mem)
                    }
                }
            }
        }
    }

    private func memoryRow(_ mem: Memory) -> some View {
        HStack(spacing: 8) {
            Image(systemName: mem.category.icon)
                .font(.system(size: 10))
                .foregroundColor(confidenceColor(mem))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(mem.key.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.80))
                Text(mem.value)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            }

            Spacer()

            // Confidence bar
            RoundedRectangle(cornerRadius: 2)
                .fill(confidenceColor(mem).opacity(0.25))
                .frame(width: 36, height: 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(confidenceColor(mem))
                        .frame(width: 36 * mem.confidence, height: 4),
                    alignment: .leading
                )

            Button { memory.delete(id: mem.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.25))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func memStatBadge(_ count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count) \(label)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.50))
        }
    }

    private func confidenceColor(_ mem: Memory) -> Color {
        switch mem.confidenceTier {
        case .high:   return Color(red: 0.20, green: 0.84, blue: 0.29)
        case .medium: return Color(red: 1.0,  green: 0.75, blue: 0.20)
        case .low:    return Color(red: 0.75, green: 0.75, blue: 0.75)
        }
    }

    // MARK: - Usage section

    private var usageSection: some View {
        HStack {
            Label("Usage today", systemImage: "chart.bar.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            Spacer()
            Text(state.usingBundledKey ? "Unlimited" : "\(state.dailyUsageCount) / \(MiraState.freeLimit)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(state.usingBundledKey ? .green : .white.opacity(0.5))
        }
    }

    // MARK: - Connected Apps

    @State private var connectedCount:  Int?    = nil
    @AppStorage("mira_composio_entity") private var composioEntity = "default"

    private var connectedAppsButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { showIntegrations = true }) {
                HStack {
                    Label("Connected Apps", systemImage: "puzzlepiece.extension.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                    if let n = connectedCount {
                        Text(n == 0 ? "None" : "\(n) connected")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(n == 0 ? .white.opacity(0.25) : Color(red: 0.20, green: 0.84, blue: 0.29))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.20))
                }
            }
            .buttonStyle(.plain)
            .task {
                connectedCount = (try? await AgentService.shared.connections())?.count
            }

            // Composio entity ID — change only if you use a custom entity in your Composio dashboard
            HStack(spacing: 6) {
                Text("Entity")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                TextField("default", text: $composioEntity)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    // MARK: - Tool activity

    @ObservedObject private var traceStore = ToolTraceStore.shared

    private var toolActivityButton: some View {
        Button(action: { showTraces = true }) {
            HStack {
                Label("Tool Activity", systemImage: "waveform.badge.clock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                if !traceStore.traces.isEmpty {
                    Text("\(traceStore.traces.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.20))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func saveKey() {
        state.userAPIKey = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        saved = true
        showOverride = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }
}
