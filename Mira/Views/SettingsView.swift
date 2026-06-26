import SwiftUI
import Carbon
import AVFoundation

struct SettingsView: View {
    @ObservedObject var state: MiraState
    // true when shown as the island's Settings tab: fill the tab area instead
    // of the fixed 360×760 sheet size (which center-clips inside the island
    // and pushes the nav bar off-screen), and make Done return to Home.
    var embedded: Bool = false
    @ObservedObject private var memory   = MemoryStore.shared
    @ObservedObject private var shortcuts = ShortcutStore.shared
    @ObservedObject private var realtime = RealtimeVoiceService.shared
    @ObservedObject private var account  = AccountService.shared
    @ObservedObject private var quota    = QuotaService.shared
    @Environment(\.dismiss) var dismiss
    @State private var keyInput      = ""
    @State private var saved         = false
    @State private var showOverride  = false
    @State private var selectedVoice: MiraVoice = MiraVoice.saved
    @State private var voiceSpeed:    Double     = MiraVoice.savedSpeed
    @State private var recording:    RecordingTarget? = nil
    @State private var keyMonitor:    Any? = nil
    @State private var showTraces        = false
    @State private var showIntegrations  = false
    @State private var showProposalMetrics = false
    @State private var showReliability     = false
    @State private var showKnowledgeImport = false
    @ObservedObject private var updater = UpdateService.shared
    @AppStorage(HoverPreferences.companionKey)   private var screenCompanionEnabled = true
    @AppStorage(HoverPreferences.sensitivityKey) private var sensitivityRaw = "balanced"
    @State private var hoverCategories: [String: CategoryStats] = [:]
    @ObservedObject private var hoverHistory = HoverHistoryStore.shared
    @State private var showHoverHistory = false
    @ObservedObject private var accentSvc  = AccentColorService.shared
    @ObservedObject private var voicePreview = VoicePreviewService.shared
    @AppStorage("mira_point_follow_up_enabled") private var pointFollowUpEnabled = false
    @AppStorage("mira_guide_cursor")       private var guideCursorEnabled = false
    @AppStorage("mira_autonomous_enabled") private var autonomousEnabled = false
    @AppStorage("mira_autonomous_confirm_risky") private var autonomousConfirmRisky = true
    @AppStorage("mira_autonomy_engine") private var autonomyEngine = "auto"
    @AppStorage("mira_draw_context_enabled") private var drawContextEnabled = true
    @AppStorage(WakeWordService.enabledKey) private var wakeWordEnabled = true
    @AppStorage("mira_codex_transport") private var codexTransport = "exec"
    @AppStorage("mira_cat_mode")           private var catMode           = false
    @AppStorage("mira_transparent_panes")  private var transparentPanes  = false
    @AppStorage(MiraIslandWindowManager.showInCaptureKey) private var showInCapture = false
    @AppStorage("mira_analytics_enabled")  private var analyticsEnabled  = true
    @AppStorage(BrowserService.preferredKey) private var preferredBrowser = ""
    @State private var installedBrowsers: [BrowserService.Browser] = []
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

    enum RecordingTarget {
        case voice, text, draw
        var defaultConfig: ShortcutConfig {
            switch self {
            case .voice: return .defaultVoice
            case .text:  return .defaultText
            case .draw:  return .defaultDraw
            }
        }
    }

    private let accent = DS.Colors.accent

    /// Which settings groups are expanded. Collapsed-by-default keeps the panel
    /// scannable (6 category headers) instead of one long 17-section scroll.
    @State private var expandedGroups: Set<String> = ["General"]

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.12).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().background(Color.white.opacity(0.08))

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        settingsGroup("General", icon: "gearshape.fill") {
                            accountSection
                            keySection
                            openRouterSection
                            accentColorSection
                            appearanceSection
                            updatesSection
                        }
                        settingsGroup("Voice & Audio", icon: "waveform") {
                            voiceSection
                            elevenLabsSection
                            microphoneSection
                        }
                        settingsGroup("Screen & Guidance", icon: "rectangle.dashed") {
                            screenCompanionSection
                            pointFollowUpSection
                            guideCursorSection
                            autonomousSection
                        }
                        settingsGroup("Shortcuts", icon: "keyboard") {
                            shortcutsSection
                            browserSection
                        }
                        settingsGroup("Agents & Memory", icon: "brain.head.profile") {
                            connectedAppsButton
                            knowledgeImportButton
                            agentFolderSection
                            memorySection
                        }
                        settingsGroup("Advanced", icon: "wrench.and.screwdriver.fill") {
                            privacySection
                            devToolsSection
                            usageSection
                            toolActivityButton
                        }
                    }
                    .padding(18)
                }
            }
        }
        .frame(
            width:  embedded ? nil : 360,
            height: embedded ? nil : 760
        )
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
        .sheet(isPresented: $showReliability)     { ReliabilityDashboardView() }
        // In the island tab, a fixed-size sheet overflows the panel's hover zone:
        // moving the cursor down to lower rows leaves the zone and auto-collapses
        // the island (dropping back to Settings). Embed it in-tab instead so the
        // list scrolls within the panel and the cursor never exits the zone.
        // The standalone Settings window (embedded == false) still uses a sheet.
        .sheet(isPresented: Binding(get: { showKnowledgeImport && !embedded },
                                    set: { showKnowledgeImport = $0 })) {
            KnowledgeImportView()
        }
        .overlay {
            if embedded && showKnowledgeImport {
                KnowledgeImportView(embedded: true, onClose: { showKnowledgeImport = false })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    // MARK: - Collapsible group

    /// A tappable category header that expands to reveal its settings sections.
    /// Replaces the old flat 17-section scroll with 6 scannable groups.
    @ViewBuilder
    private func settingsGroup<Content: View>(_ title: String, icon: String,
                                              @ViewBuilder _ content: () -> Content) -> some View {
        let isOpen = expandedGroups.contains(title)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                    if isOpen { expandedGroups.remove(title) } else { expandedGroups.insert(title) }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(accent)
                        .frame(width: 18)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.30))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 18) {
                    content()
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.06), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Spacer()
            Button("Done") {
                if embedded {
                    // dismiss() is a no-op outside a sheet — go back to Home
                    NotificationCenter.default.post(name: .miraTabSelected, object: IslandTab.home)
                } else {
                    dismiss()
                }
            }
            .foregroundColor(accent)
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Account section

    @ViewBuilder
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Account", systemImage: "person.crop.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            if account.isSignedIn {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.currentUser?.displayName ?? "Signed in")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        if let e = account.currentUser?.email {
                            Text(e)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                    }
                    Spacer()
                    Button("Sign Out") { account.signOut() }
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                        .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.green.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.20)))
                .cornerRadius(8)
            } else {
                Text("Sign in to use Mira — chat, voice, and agents run through Mira's secure backend.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                AuthView(compact: true)
            }
        }
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

    private var browserSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Web Browser", systemImage: "safari")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            VStack(alignment: .leading, spacing: 6) {
                Text("Open searches & web pages in")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.80))
                Picker("", selection: $preferredBrowser) {
                    Text("System default").tag("")
                    ForEach(installedBrowsers) { browser in
                        Text(browser.name).tag(browser.bundleID)
                    }
                }
                .labelsHidden()
                Text("When you ask for live scores, news, or anything on the web, Mira opens this browser to the page and reads it back to you.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .onAppear { installedBrowsers = BrowserService.shared.installedBrowsers() }
    }

    @ViewBuilder
    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Keyboard Shortcuts", systemImage: "keyboard")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            shortcutRow(label: "Talk to Mira",   config: $shortcuts.voice, target: .voice)
            shortcutRow(label: "Text Mira",      config: $shortcuts.text,  target: .text)
            shortcutRow(label: "Draw on screen", config: $shortcuts.draw,  target: .draw)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Always-on voice")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.80))
                    Text("Hands-free listening that lives in the closed notch. Interrupt Mira while she talks when you're on headphones/AirPods.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { realtime.isAlwaysOnActive },
                    set: { _ in NotificationCenter.default.post(name: .miraToggleAlwaysOn, object: nil) }
                ))
                .toggleStyle(.switch)
                .tint(accent)
                .labelsHidden()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\u{201C}Hey Mira\u{201D} wake word")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.80))
                    Text("Listen in the background for \u{201C}Hey Mira\u{201D} and start a voice session hands-free.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $wakeWordEnabled)
                    .toggleStyle(.switch)
                    .tint(accent)
                    .labelsHidden()
                    .onChange(of: wakeWordEnabled) {
                        NotificationCenter.default.post(name: .miraToggleWakeWord, object: nil)
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

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

            if config.wrappedValue != target.defaultConfig {
                Button(action: {
                    stopRecording()
                    config.wrappedValue = target.defaultConfig
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
                    .onChange(of: screenCompanionEnabled) {
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
            // Use the base character (ignoring modifiers) — Control-modified keys make
            // `event.characters` return a non-printable control char (Ctrl+V → "\u{16}"),
            // which would store an invisible displayKey and a broken binding.
            guard let raw = event.charactersIgnoringModifiers,
                  let scalar = raw.unicodeScalars.first,
                  scalar.value >= 0x20, scalar.value != 0x7F else { return event }
            config.wrappedValue = ShortcutConfig(keyCode: UInt32(event.keyCode),
                                                  carbonMods: carbonMods,
                                                  displayKey: raw.uppercased())
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

                        // Preview button — synthesizes the voice live via OpenAI
                        // TTS (every voice speaks the same line).
                        Button {
                            voicePreview.toggle(v)
                        } label: {
                            Group {
                                if voicePreview.loadingVoice == v {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: voicePreview.playingVoice == v ? "stop.fill" : "play.fill")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(voicePreview.playingVoice == v ? accent : .white.opacity(0.30))
                                }
                            }
                            .frame(width: 26, height: 26)
                            .background(Color.white.opacity(0.05))
                            .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Speed slider
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Speed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))
                    Spacer()
                    Text(voiceSpeed == 1.0 ? "Normal" : String(format: "%.2gx", voiceSpeed))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(accent)
                }
                Slider(value: $voiceSpeed, in: 0.5...2.0, step: 0.25) {
                    EmptyView()
                }
                .accentColor(accent)
                .onChange(of: voiceSpeed) { _, newVal in
                    RealtimeVoiceService.shared.setSpeed(newVal)
                }
            }
            .padding(.top, 6)

            Text("OpenAI Realtime API · gpt-4o-realtime-preview · Tap ▶ to hear a sample")
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

    // MARK: - Guide Cursor section

    @ViewBuilder
    private var guideCursorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Lessons", systemImage: "graduationcap")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Guide my cursor to each step")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.80))
                    Text("During a lesson, Mira glides your pointer to the highlighted control. It never clicks — you still do that.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $guideCursorEnabled)
                    .toggleStyle(.switch)
                    .tint(accent)
                    .labelsHidden()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: - Autonomous mode section

    @ViewBuilder
    private var autonomousSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Autonomous", systemImage: "bolt.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            // Tasks-left meter (autonomy quota). Server-authoritative when signed
            // in; local estimate otherwise.
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(quota.tasksLeftText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                    Text("\(quota.planName) plan\(quota.lastWasOffline ? " · offline estimate" : "")")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                }
                Spacer()
                if quota.limit >= 0 {
                    Text("\(max(quota.remaining, 0))")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundColor(quota.remaining <= 0 ? .orange : accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .task { await quota.refreshQuota() }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Let Mira do it for me")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.80))
                    Text("In a lesson, Mira clicks each grounded step itself instead of waiting for you. It really controls your Mac.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $autonomousEnabled)
                    .toggleStyle(.switch)
                    .tint(accent)
                    .labelsHidden()
                    .onChange(of: autonomousEnabled) { _, enabled in
                        // Bring Mira's MCP server up/down with autonomy so Codex can
                        // (or can't) call back into Mira's tools.
                        if enabled { MiraMCPServer.shared.start() }
                        else { MiraMCPServer.shared.stop() }
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if autonomousEnabled {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Confirm risky actions")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.80))
                        Text("Pause before anything irreversible (send, delete, buy, submit…) so you decide. Off = fully hands-off.")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.35))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $autonomousConfirmRisky)
                        .toggleStyle(.switch)
                        .tint(accent)
                        .labelsHidden()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Draw on screen for context")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.80))
                        Text("Hold the Draw shortcut (\(shortcuts.draw.displayString)) or the voice key to sketch on your screen — Mira uses the marks to know where to act or what you mean.")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.35))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $drawContextEnabled)
                        .toggleStyle(.switch)
                        .tint(accent)
                        .labelsHidden()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Control engine")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.80))
                    Picker("", selection: $autonomyEngine) {
                        Text("Auto").tag("auto")
                        Text("Codex").tag("codex")
                        Text("Claude").tag("claude")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text({
                        switch autonomyEngine {
                        case "codex":  return "Always use OpenAI Codex's computer-use plugin. It enforces its own app safety limits."
                        case "claude": return "Always use Claude vision — screenshots and clicks/types via the cursor."
                        default:       return "Mira picks the best engine for each task and retries on the other if one can't finish. Recommended."
                        }
                    }())
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Codex transport")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.80))
                    Picker("", selection: $codexTransport) {
                        Text("Per task").tag("exec")
                        Text("Warm session").tag("mcp")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(codexTransport == "mcp"
                         ? "Keep one Codex session warm (no cold start) and remember context across follow-ups. Experimental — falls back to per-task if it can't start."
                         : "Start a fresh Codex for each task. Most reliable. Recommended.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Label("Mira controls your Mac autonomously. Watch it, and use Stop to halt at any time. Targeting isn't fully reliability-hardened yet — it can mis-click.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.7))
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

    private var knowledgeImportButton: some View {
        Button(action: { showKnowledgeImport = true }) {
            HStack {
                Label("Import Knowledge", systemImage: "person.text.rectangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                if let sources = UserKnowledgeStore.shared.knowledge?.importedFrom, !sources.isEmpty {
                    Text("\(sources.count) source\(sources.count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(red: 0.20, green: 0.84, blue: 0.29))
                } else {
                    Text("Set up")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.25))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.20))
            }
        }
        .buttonStyle(.plain)
    }

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
    @ObservedObject private var telemetry     = TelemetryService.shared

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

            Button(action: { showReliability = true }) {
                HStack {
                    Label("Reliability", systemImage: "scope")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.20))
                }
            }
            .buttonStyle(.plain)

            // Lessons now live in their own "Learn" tab (LessonsTabView), so they
            // aren't buried at the bottom of this long settings scroll.
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
                .onChange(of: selectedMicUID) { _, uid in
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

            // Show the notch island in screenshots & screen recordings (for demos).
            // Off by default so Mira's chrome stays out of the user's captures.
            toggleRow(
                icon: "record.circle",
                title: "Show in screen recordings",
                subtitle: "Let the Mira island appear in screenshots & screen captures (for demos)",
                binding: $showInCapture
            )
            .onChange(of: showInCapture) {
                NotificationCenter.default.post(name: .miraShowInCaptureChanged, object: nil)
            }
        }
    }

    // Analytics opt-out (Privacy Policy §6). Off = PostHogService sends nothing,
    // including identify/PII — the flag is read directly in PostHogService.send.
    private var privacySection: some View {
        VStack(spacing: 6) {
            toggleRow(
                icon: "chart.bar.xaxis",
                title: "Share usage analytics",
                subtitle: "Anonymous product analytics to improve Mira. Turn off to send nothing.",
                binding: $analyticsEnabled
            )
            Button {
                NSWorkspace.shared.open(URL(string: "https://rdbljrbjsmbfqwwpwwvn.supabase.co/storage/v1/object/public/releases/privacy.html")!)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                    Text("Privacy Policy")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.25))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            Button {
                NSWorkspace.shared.open(URL(string: "https://rdbljrbjsmbfqwwpwwvn.supabase.co/storage/v1/object/public/releases/terms.html")!)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                    Text("Terms of Service")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.25))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
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
