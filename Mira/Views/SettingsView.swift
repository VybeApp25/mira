import SwiftUI
import Carbon
import AVFoundation

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
    @State private var showProposalMetrics = false
    @ObservedObject private var updater = UpdateService.shared
    @AppStorage(HoverPreferences.companionKey)   private var screenCompanionEnabled = true
    @AppStorage(HoverPreferences.sensitivityKey) private var sensitivityRaw = "balanced"
    @State private var hoverCategories: [String: CategoryStats] = [:]
    @ObservedObject private var hoverHistory = HoverHistoryStore.shared
    @State private var showHoverHistory = false
    @ObservedObject private var accentSvc  = AccentColorService.shared
    @State private var previewPlayer: AVAudioPlayer? = nil
    @State private var previewingVoice: MiraVoice? = nil
    @AppStorage("mira_point_follow_up_enabled") private var pointFollowUpEnabled = false
    @AppStorage("mira_cat_mode")           private var catMode           = false
    @AppStorage("mira_transparent_panes")  private var transparentPanes  = false
    @State private var micDevices:     [AVCaptureDevice] = []
    @State private var selectedMicUID: String = UserDefaults.standard.string(forKey: "mira_mic_uid") ?? ""
    @State private var micLevel:       Float  = 0.0
    @State private var micMonitor:     MicLevelMonitor? = nil
    @State private var misoKeyInput:     String = ""
    @State private var misoKeySaved:     Bool   = false
    @State private var selectedMisoVoice: MisoVoice = MisoVoice.saved
    @State private var orKeyInput:       String = ""
    @State private var orKeySaved:       Bool   = false
    @State private var agentFolderPath:  String = ""

    private static let defaultAgentFolder = NSHomeDirectory() + "/Desktop/Mira"

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
                        openRouterSection
                        Divider().background(Color.white.opacity(0.08))
                        accentColorSection
                        Divider().background(Color.white.opacity(0.08))
                        connectedAppsButton
                        Divider().background(Color.white.opacity(0.08))
                        shortcutsSection
                        Divider().background(Color.white.opacity(0.08))
                        screenCompanionSection
                        Divider().background(Color.white.opacity(0.08))
                        pointFollowUpSection
                        Divider().background(Color.white.opacity(0.08))
                        voiceSection
                        Divider().background(Color.white.opacity(0.08))
                        elevenLabsSection
                        Divider().background(Color.white.opacity(0.08))
                        microphoneSection
                        Divider().background(Color.white.opacity(0.08))
                        appearanceSection
                        Divider().background(Color.white.opacity(0.08))
                        memorySection
                        Divider().background(Color.white.opacity(0.08))
                        agentFolderSection
                        Divider().background(Color.white.opacity(0.08))
                        devToolsSection
                        Divider().background(Color.white.opacity(0.08))
                        usageSection
                        Divider().background(Color.white.opacity(0.08))
                        updatesSection
                        Divider().background(Color.white.opacity(0.08))
                        toolActivityButton
                    }
                    .padding(18)
                }
            }
        }
        .frame(width: 360, height: 760)
        .onAppear {
            keyInput = state.userAPIKey
            hoverCategories = HoverPreferences.shared.categories
            misoKeyInput = UserDefaults.standard.string(forKey: "mira_miso_key") ?? ""
            selectedMisoVoice = MisoVoice.saved
            orKeyInput = UserDefaults.standard.string(forKey: "mira_openrouter_key") ?? ""
            agentFolderPath = UserDefaults.standard.string(forKey: "mira_agent_folder") ?? Self.defaultAgentFolder
        }
        .sheet(isPresented: $showTraces)          { ToolTraceView() }
        .sheet(isPresented: $showIntegrations)    { IntegrationsView() }
        .sheet(isPresented: $showProposalMetrics) { ProposalMetricsView() }
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

    // MARK: - OpenRouter section

    @ViewBuilder
    private var openRouterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("OpenRouter Fallback", systemImage: "arrow.trianglehead.2.counterclockwise.rotate.90")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            let hasKey = !orKeyInput.isEmpty
                      || !(UserDefaults.standard.string(forKey: "mira_openrouter_key") ?? "").isEmpty

            if hasKey && orKeyInput.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green).font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fallback key active")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text("Retries via OpenRouter on 429 / 503 / 529.")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.40))
                    }
                    Spacer()
                    Button("Clear") {
                        UserDefaults.standard.removeObject(forKey: "mira_openrouter_key")
                        orKeyInput = ""
                        orKeySaved = false
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.green.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.20)))
                .cornerRadius(8)
            } else {
                SecureField("sk-or-v1-...", text: $orKeyInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10)))

                Button {
                    guard !orKeyInput.isEmpty else { return }
                    UserDefaults.standard.set(orKeyInput, forKey: "mira_openrouter_key")
                    orKeySaved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { orKeySaved = false }
                } label: {
                    Text(orKeySaved ? "Saved ✓" : "Save Key")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundColor(.white)
                        .background(accent)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Text("openrouter.ai/keys — fallback when Anthropic is rate-limited")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
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
                    HStack(spacing: 8) {
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
                        .frame(maxWidth: .infinity)

                        // Preview button — plays bundled voice sample if available
                        Button {
                            playVoicePreview(v)
                        } label: {
                            Image(systemName: previewingVoice == v ? "stop.fill" : "play.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(previewingVoice == v ? accent : .white.opacity(0.30))
                                .frame(width: 26, height: 26)
                                .background(Color.white.opacity(0.05))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text("OpenAI Realtime API · gpt-4o-realtime-preview")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.25))
        }
    }

    // MARK: - Miso TTS section

    @ViewBuilder
    private var elevenLabsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Miso TTS", systemImage: "waveform.badge.mic")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            let hasKey = !misoKeyInput.isEmpty || MisoTTSService.shared.isConfigured

            if hasKey && misoKeyInput.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green).font(.system(size: 14))
                    Text("API key active")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Button("Clear") {
                        UserDefaults.standard.removeObject(forKey: "mira_miso_key")
                        misoKeyInput = ""
                        misoKeySaved = false
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.green.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.20)))
                .cornerRadius(8)
            } else {
                SecureField("API key...", text: $misoKeyInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10)))

                Button {
                    guard !misoKeyInput.isEmpty else { return }
                    UserDefaults.standard.set(misoKeyInput, forKey: "mira_miso_key")
                    misoKeySaved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { misoKeySaved = false }
                } label: {
                    Text(misoKeySaved ? "Saved ✓" : "Save Key")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundColor(.white)
                        .background(accent)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Text("misolabs.ai — enter your API key when available")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
            }

            if MisoTTSService.shared.isConfigured || !misoKeyInput.isEmpty {
                VStack(spacing: 4) {
                    ForEach(MisoVoice.allCases) { v in
                        Button {
                            MisoVoice.saved = v
                            selectedMisoVoice = v
                        } label: {
                            HStack {
                                Text(v.label)
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.85))
                                Spacer()
                                if selectedMisoVoice == v {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(accent)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(selectedMisoVoice == v ? accent.opacity(0.10) : Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Miso TTS · miso-tts-8b · Tap speaker on any Mira message to read aloud")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
            }
        }
    }

    private func playVoicePreview(_ voice: MiraVoice) {
        if previewingVoice == voice {
            previewPlayer?.stop()
            previewPlayer = nil
            previewingVoice = nil
            return
        }
        previewPlayer?.stop()
        guard let url = Bundle.main.url(forResource: voice.previewResource, withExtension: "mp3"),
              let player = try? AVAudioPlayer(contentsOf: url) else {
            AudioCueService.shared.playAgentLaunch()
            return
        }
        player.prepareToPlay()
        previewPlayer = player
        previewingVoice = voice
        player.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + player.duration + 0.1) {
            if self.previewingVoice == voice { self.previewingVoice = nil }
        }
    }

    // MARK: - Accent color section

    @ViewBuilder
    private var accentColorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Accent Color", systemImage: "paintpalette.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 8) {
                ForEach(AccentColorService.options) { option in
                    let selected = accentSvc.selectedIndex == option.id
                    Button {
                        accentSvc.select(option.id)
                    } label: {
                        VStack(spacing: 4) {
                            Circle()
                                .fill(option.color)
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(selected ? 0.75 : 0), lineWidth: 2)
                                )
                                .scaleEffect(selected ? 1.12 : 1.0)
                                .animation(.spring(response: 0.22, dampingFraction: 0.72), value: selected)
                            Text(option.name)
                                .font(.system(size: 9, weight: selected ? .semibold : .regular))
                                .foregroundColor(selected ? .white.opacity(0.80) : .white.opacity(0.30))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: - Point Follow-Up section

    @ViewBuilder
    private var pointFollowUpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Point & Ask", systemImage: "cursorarrow.click.2")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Click to explain")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.80))
                    Text("Click anything on screen — Mira explains what you clicked.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $pointFollowUpEnabled)
                    .toggleStyle(.switch)
                    .tint(accent)
                    .labelsHidden()
                    .onChange(of: pointFollowUpEnabled) { _, enabled in
                        NotificationCenter.default.post(
                            name: NSNotification.Name("miraPointFollowUpToggled"),
                            object: enabled
                        )
                        if enabled { PointFollowUpService.shared.start() }
                        else       { PointFollowUpService.shared.stop()  }
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if pointFollowUpEnabled {
                Text("Requires Accessibility permission. Click events are processed on-device.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    // MARK: - Agent Folder section

    private var agentFolderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Agent Folder", systemImage: "folder.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 8) {
                Text(agentFolderPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Change…") { chooseAgentFolder() }
                    .font(.system(size: 11))
                    .foregroundColor(accent)
                    .buttonStyle(.plain)

                if agentFolderPath != Self.defaultAgentFolder {
                    Button("Reset") {
                        UserDefaults.standard.removeObject(forKey: "mira_agent_folder")
                        agentFolderPath = Self.defaultAgentFolder
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text("Agent-generated files are saved here unless you specify otherwise.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.30))
        }
    }

    private func chooseAgentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose where Mira saves agent output"
        panel.prompt = "Select Folder"
        if panel.runModal() == .OK, let url = panel.url {
            agentFolderPath = url.path
            UserDefaults.standard.set(url.path, forKey: "mira_agent_folder")
        }
    }

    // MARK: - Developer Tools section

    @State private var codexStatus: String = "Checking…"
    @State private var claudeCodeStatus: String = "Checking…"

    private var devToolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Developer Tools", systemImage: "terminal.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            VStack(spacing: 6) {
                devToolRow(label: "Codex CLI", status: codexStatus, installCmd: "npm install -g @openai/codex")
                devToolRow(label: "Claude Code", status: claudeCodeStatus, installCmd: "npm install -g @anthropic-ai/claude-code")
            }
        }
        .task { await checkDevTools() }
    }

    private func devToolRow(label: String, status: String, installCmd: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
            Spacer()
            Text(status)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(status.contains("v") || status.contains("installed")
                                 ? .green : .white.opacity(0.35))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @MainActor
    private func checkDevTools() async {
        async let codex = CodexService.shared.statusSummary()
        async let code  = checkClaudeCode()
        (codexStatus, claudeCodeStatus) = await (codex, code)
    }

    private func checkClaudeCode() async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.launchPath = "/bin/zsh"
                proc.arguments = ["-lc", "which claude >/dev/null 2>&1 && claude --version 2>/dev/null || echo 'not installed'"]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError  = pipe
                proc.launch()
                proc.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "not installed"
                cont.resume(returning: out.isEmpty ? "not installed" : out)
            }
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

    // MARK: - Tool activity + proposal metrics

    @ObservedObject private var traceStore    = ToolTraceStore.shared
    @ObservedObject private var proposalStore = ProposalStore.shared
    @ObservedObject private var engine        = ProjectEngine.shared

    private var toolActivityButton: some View {
        VStack(spacing: 10) {
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

            Button(action: { showProposalMetrics = true }) {
                HStack {
                    Label("Proposal Metrics", systemImage: "chart.bar.doc.horizontal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                    let total = proposalStore.globalProposalCount(for: engine.projects)
                    if total > 0 {
                        Text("\(total)")
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
    }

    // MARK: - Updates section

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mira \(updater.currentVersion)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                    Text(updater.lastCheckedString)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.32))
                }

                Spacer()

                Button("Check for Updates") {
                    updater.checkForUpdates()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(accent)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text("Build \(updater.buildNumber) · Updates delivered automatically")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.22))
        }
    }

    // MARK: - Microphone section

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Microphone", systemImage: "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            if micDevices.isEmpty {
                Text("No input devices found")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.28))
            } else {
                Picker("", selection: $selectedMicUID) {
                    ForEach(micDevices, id: \.uniqueID) { dev in
                        Text(dev.localizedName).tag(dev.uniqueID)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white)
                .onChange(of: selectedMicUID) { uid in
                    UserDefaults.standard.set(uid, forKey: "mira_mic_uid")
                }
            }

            // Live volume meter
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.07))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(levelColor(micLevel))
                            .frame(width: geo.size.width * CGFloat(min(micLevel, 1.0)))
                            .animation(.linear(duration: 0.05), value: micLevel)
                    }
                }
                .frame(height: 6)

                Button(micMonitor == nil ? "Test Mic" : "Stop") {
                    if micMonitor == nil {
                        let monitor = MicLevelMonitor(deviceUID: selectedMicUID.isEmpty ? nil : selectedMicUID) { level in
                            micLevel = level
                        }
                        micMonitor = monitor
                    } else {
                        micMonitor?.stop()
                        micMonitor = nil
                        micLevel   = 0
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(micMonitor == nil ? accent : .red.opacity(0.8))
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            micDevices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone],
                mediaType: .audio,
                position: .unspecified
            ).devices
        }
        .onDisappear {
            micMonitor?.stop()
            micMonitor = nil
            micLevel   = 0
        }
    }

    private func levelColor(_ level: Float) -> Color {
        level < 0.6 ? Color(red: 0.20, green: 0.84, blue: 0.29)
                    : Color(red: 1.0,  green: 0.60, blue: 0.20)
    }

    // MARK: - Appearance section (Cat Mode + Transparent panes)

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Appearance", systemImage: "paintbrush.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            // Transparent panes
            toggleRow(
                icon: "rectangle.fill",
                title: "Transparent panes",
                subtitle: "Frosted glass instead of solid background",
                binding: $transparentPanes
            )

            // Cat Mode
            toggleRow(
                icon: "pawprint.fill",
                title: "Cat mode 🐱",
                subtitle: "Mira responds with feline energy",
                binding: $catMode
            )
        }
    }

    private func toggleRow(icon: String, title: String, subtitle: String, binding: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }

            Spacer()

            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .scaleEffect(0.75)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Helpers

    private func saveKey() {
        state.userAPIKey = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        saved = true
        showOverride = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }
}
