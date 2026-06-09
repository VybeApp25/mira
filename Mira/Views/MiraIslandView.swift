import SwiftUI

// MARK: - Island shape (animatable)

/// Custom shape with independently animated top/bottom corner radii.
/// topRadius = 0 keeps the island flush with the physical notch hardware.
private struct IslandShape: Shape, Animatable {
    var topRadius:    CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let tR = clamp(topRadius,    rect)
        let bR = clamp(bottomRadius, rect)
        var p  = Path()
        p.move(to: CGPoint(x: rect.minX + tR, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tR, y: rect.minY))
        arc(&p, cx: rect.maxX - tR, cy: rect.minY + tR, r: tR, from: -90, to:   0)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bR))
        arc(&p, cx: rect.maxX - bR, cy: rect.maxY - bR, r: bR, from:   0, to:  90)
        p.addLine(to: CGPoint(x: rect.minX + bR, y: rect.maxY))
        arc(&p, cx: rect.minX + bR, cy: rect.maxY - bR, r: bR, from:  90, to: 180)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tR))
        arc(&p, cx: rect.minX + tR, cy: rect.minY + tR, r: tR, from: 180, to: 270)
        p.closeSubpath()
        return p
    }

    private func clamp(_ r: CGFloat, _ rect: CGRect) -> CGFloat {
        let limit = min(rect.width, rect.height) / 2
        return r < 0 ? 0 : (r > limit ? limit : r)
    }
    private func arc(_ p: inout Path, cx: CGFloat, cy: CGFloat, r: CGFloat, from: Double, to: Double) {
        guard r > 0 else { return }
        p.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                 startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
    }
}

// MARK: - Tab enum

enum IslandTab: Equatable { case chat, home, agents, briefing, projects, reliability }

// MARK: - Main island view

struct MiraIslandView: View {
    @ObservedObject var animController: AnimationController
    @ObservedObject var miraState:      MiraState
    @ObservedObject var taskStore:      AgentTaskStore
    @ObservedObject var overlay:        OverlayWindowController
    let capture:  ScreenCaptureService
    @ObservedObject var voice:     VoiceService
    @ObservedObject var wakeWord:  WakeWordService
    let geometry: NotchGeometry
    @ObservedObject private var engine = ProjectEngine.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Default to briefing on first expansion of the day; Chat every other time
    @State private var selectedTab: IslandTab = {
        let last   = UserDefaults.standard.object(forKey: "mira_last_briefing") as? Date
        let isNew  = last.map { !Calendar.current.isDateInToday($0) } ?? true
        return isNew ? .briefing : .chat
    }()
    @State private var showSettings = false
    @StateObject private var pillState = PillStateModel()

    private var isExpanded: Bool { animController.state == .expanded }

    // True whenever any non-idle visual indicator should appear in the collapsed pill.
    private var collapsedIndicatorActive: Bool {
        pillState.mode != .idle
    }

    // Widen the pill to fit label + indicator when active.
    private var pillW: CGFloat {
        if isExpanded { return AnimationController.expandedW }
        return collapsedIndicatorActive ? geometry.notchWidth + 110 : geometry.notchWidth
    }
    private var pillH: CGFloat { isExpanded ? AnimationController.expandedH : geometry.notchHeight }
    private var topR:  CGFloat { isExpanded ? AnimationController.expandedTopR : AnimationController.collapsedTopR }
    private var botR:  CGFloat { isExpanded ? AnimationController.expandedBotR : AnimationController.collapsedBotR }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.ignoresSafeArea()
            pill
        }
        .onReceive(NotificationCenter.default.publisher(for: .miraTabSelected)) { notif in
            if let tab = notif.object as? IslandTab {
                withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
            }
        }
        // Opt out of the macOS safe-area inset (menu bar height ≈ 33pt).
        // Without this the pill is pushed ~33pt below the notch, leaving a gap.
        .ignoresSafeArea()
        .sheet(isPresented: $showSettings) {
            SettingsView(state: miraState)
        }
        // Sync existing RealtimeState → PillStateModel (debounced)
        .onChange(of: miraState.realtimeState) { _, new in
            if case .error = new { pillState.postEvent(.error) }
            pillState.syncFromRealtime(new, isListening: voice.isListening, isLoading: miraState.isLoading)
        }
        .onChange(of: voice.isListening) { _, new in
            if new { pillState.postEvent(.listening) }
            pillState.syncFromRealtime(miraState.realtimeState, isListening: new, isLoading: miraState.isLoading)
        }
        .onChange(of: miraState.isLoading) { _, new in
            pillState.syncFromRealtime(miraState.realtimeState, isListening: voice.isListening, isLoading: new)
        }
        .onChange(of: animController.hudMode) { _, new in
            if new == .done    { pillState.postEvent(.complete) }
            if new == .blocked { pillState.postEvent(.error)    }
        }
        .onReceive(NotificationCenter.default.publisher(for: .miraActivateVoice)) { _ in
            pillState.postEvent(.shortcut)
        }
        .onReceive(NotificationCenter.default.publisher(for: .miraActivateText)) { _ in
            pillState.postEvent(.shortcut)
        }
    }

    // MARK: - Pill container

    private var pill: some View {
        ZStack {
            Color.black
            if isExpanded {
                expandedContent
                    .opacity(animController.contentVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.14), value: animController.contentVisible)
            } else {
                collapsedContent
                    .opacity(animController.contentVisible ? 0 : 1)
                    .animation(.easeInOut(duration: 0.10), value: animController.contentVisible)
            }

            // Always-mounted SharedStatusView — never recreated on expand/collapse because it
            // lives at a stable ZStack slot above the content branches.
            // Collapsed: trailing edge, vertically centered.
            // Expanded:  top-right area of nav bar (88 pt from trailing to clear gear/mic).
            SharedStatusView(pillState: pillState, isCompact: !isExpanded)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: isExpanded ? .topTrailing : .trailing)
                .padding(.trailing, isExpanded ? 88 : 12)
                .padding(.top, isExpanded ? 12 : 0)
                .allowsHitTesting(false)
                .animation(
                    reduceMotion ? .easeInOut(duration: 0.10)
                                 : .spring(response: 0.32, dampingFraction: 0.78),
                    value: isExpanded
                )

            // Event toast — bottom of expanded pill only
            VStack {
                Spacer()
                EventToastView(event: pillState.event)
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isExpanded ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: isExpanded)
            .animation(.spring(response: 0.25, dampingFraction: 0.80), value: pillState.event)
            .allowsHitTesting(false)
        }
        .frame(width: pillW, height: pillH)
        .clipShape(IslandShape(topRadius: topR, bottomRadius: botR))
        // Colored halo under the pill when an active state is present; fades when idle.
        .shadow(
            color: isExpanded
                ? .black.opacity(0.70)
                : collapsedAccent.opacity(collapsedIndicatorActive && !reduceMotion ? 0.45 : 0),
            radius: isExpanded ? 20 : 10,
            x: 0,
            y: isExpanded ? 22 : 6
        )
        .animation(
            reduceMotion
                ? .easeInOut(duration: 0.10)
                : (isExpanded
                    ? .spring(response: 0.40, dampingFraction: 0.74, blendDuration: 0)
                    : .spring(response: 0.30, dampingFraction: 0.82, blendDuration: 0)),
            value: isExpanded
        )
        // Animate the width change when the collapsed indicator activates/deactivates.
        .animation(
            reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78),
            value: collapsedIndicatorActive
        )
    }

    // MARK: - Collapsed pill
    // When idle the pill is pure black — indistinguishable from the hardware notch.
    // Only active states (voice, agent) render a visible indicator.

    @ObservedObject private var hudVM = HUDViewModel.shared

    // Human-readable label for the active state shown on the left of the collapsed pill.
    private var collapsedStateLabel: String? {
        switch miraState.realtimeState {
        case .connecting:              return "Connecting"
        case .recording:               return "Listening"
        case .transcribing:            return "Processing"
        case .thinking:                return "Thinking"
        case .speaking:                return "Speaking"
        case .error:                   return nil
        case .idle:
            if voice.isListening   { return "Listening" }
            if miraState.isLoading { return "Thinking"  }
            return nil
        }
    }

    private var collapsedContent: some View {
        HStack(spacing: 0) {
            // Left: active state label, or HUD status text, or agent badge when idle
            Group {
                if let label = collapsedStateLabel {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                } else if !hudVM.statusText.isEmpty {
                    Text(hudVM.statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.80))
                        .lineLimit(1)
                        .transition(.opacity)
                } else if !taskStore.tasks.isEmpty {
                    Text("\(taskStore.tasks.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color(red: 0.29, green: 0.62, blue: 1.0))
                        .clipShape(Capsule())
                        .transition(.opacity)
                }
            }
            // SharedStatusView provides the right-side animated indicator (in the ZStack overlay)
        }
        .padding(.horizontal, 12)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: miraState.realtimeState)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: miraState.isLoading)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: voice.isListening)
    }

    private var collapsedAccent: Color {
        switch pillState.mode {
        case .thinking: return miraViolet
        case .working:  return miraViolet
        case .speaking: return miraTeale
        case .idle:     return miraTeale
        }
    }

    // MARK: - Expanded layout

    private var expandedContent: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                navBar
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 0.5)
                if let summary = miraState.hoverSummary {
                    hoverSummaryBar(summary)
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 0.5)
                }
                continuationBanner
                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Phase 2: HUD overlay — sits on top of tabs, invisible when idle
            hudOverlay
        }
    }

    // MARK: - Phase 10: Continuation banner

    @ViewBuilder
    private var continuationBanner: some View {
        if let project = engine.pendingContinuation {
            let accent = Color(red: 0.29, green: 0.62, blue: 1.0)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(accent.opacity(0.15))
                            .frame(width: 22, height: 22)
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(accent)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Continue \(project.name)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.90))
                            .lineLimit(1)
                        HStack(spacing: 3) {
                            Text(project.relativeTime)
                            if !project.checkpoints.isEmpty {
                                Text("·")
                                Text("\(project.checkpoints.count) checkpoint\(project.checkpoints.count == 1 ? "" : "s")")
                            }
                            if let session = project.lastCompletedSession {
                                Text("·")
                                Text(session.persona.displayName)
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.32))
                    }
                    Spacer()
                    Button {
                        let prompt = ProjectEngine.shared.buildResumePrompt(for: project)
                        engine.dismissContinuation()
                        selectedTab = .chat
                        NotificationCenter.default.post(
                            name: .miraChipPromptSelected,
                            object: nil,
                            userInfo: ["prompt": prompt]
                        )
                    } label: {
                        Text("Resume")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(accent)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(accent.opacity(0.14))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button { engine.dismissContinuation() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.22))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(.easeInOut(duration: 0.18), value: engine.pendingContinuation != nil)
        }
    }

    // MARK: - HUD overlay (Phase 2, additive)

    @ViewBuilder
    private var hudOverlay: some View {
        let hudService  = HUDService.shared
        let chipService = ActionChipService.shared

        switch animController.hudMode {
        case .idle:
            EmptyView()

        case .running:
            AgentHUDView(hud: hudService)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: animController.hudMode)

        case .done:
            // Fix 1: use the stored AgentResult so summary is never "Done."
            let result = animController.currentResult ?? AgentResult(
                summary:     hudService.updates.last?.message ?? "Done.",
                doneTitle:   hudService.activeProjectName ?? "Task Complete",
                artifacts:   [],
                nextActions: chipService.chips,
                checkpointId: nil,
                projectId:   nil
            )
            AgentResultView(
                result: result,
                chipService: chipService,
                onChipTapped: { prompt in
                    // Fix 3: route chip prompt into the chat tab
                    selectedTab = .chat
                    animController.clearHUD()
                    NotificationCenter.default.post(
                        name: .miraChipPromptSelected,
                        object: nil,
                        userInfo: ["prompt": prompt]
                    )
                }
            )
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: animController.hudMode)

        case .blocked:
            blockedOverlay
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: animController.hudMode)
        }
    }

    // MARK: - Blocked overlay (Fix 5)

    private var blockedOverlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 1.0, green: 0.75, blue: 0.20))
                Text("Blocked")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                Button { animController.clearHUD() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.30))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().background(Color.white.opacity(0.07))

            Text(HUDService.shared.currentMessage)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.80))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.top, 10)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func hoverSummaryBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.fill")
                .font(.system(size: 10))
                .foregroundColor(Color(red: 0.29, green: 0.62, blue: 1.0).opacity(0.6))
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.78))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                miraState.hoverSummary = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.22))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    // MARK: - Inline nav bar

    private var navBar: some View {
        HStack(spacing: 4) {
            // Left group — primary tabs
            navTab(icon: "message.fill",  label: "Chat",     tab: .chat)
            navTab(icon: "folder.fill",   label: "Projects", tab: .projects)
            navTab(icon: "sparkles",      label: "Today",    tab: .briefing)
            navTab(icon: "house.fill",    label: "Home",     tab: .home)
            navTab(icon: "cpu",           label: "Agents",   tab: .agents)
            navTab(icon: "chart.bar.fill", label: "Stats",   tab: .reliability)

            Spacer()

            // Right group — HUD controls + status + utilities
            if voice.isListening {
                HStack(spacing: 3) {
                    Circle().fill(Color.red).frame(width: 5, height: 5)
                    Text(voice.liveTranscript.isEmpty ? "Listening" : voice.liveTranscript)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
            }

            // Stop — shown whenever HUD has an active route
            if hudVM.state.isActive {
                Button { hudVM.send(.cancelRequested) } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(red: 1.0, green: 0.35, blue: 0.35))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop agent")
            }

            // Mute toggle
            Button { hudVM.send(.muteToggled(hudVM.state != .muted)) } label: {
                Image(systemName: hudVM.state == .muted ? "mic.slash.fill" : "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(hudVM.state == .muted
                        ? Color(red: 1.0, green: 0.35, blue: 0.35)
                        : .white.opacity(0.30))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hudVM.state == .muted ? "Unmute microphone" : "Mute microphone")

            if !miraState.isPro {
                Text("\(miraState.dailyUsageCount)/\(MiraState.freeLimit)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
                    .padding(.trailing, 4)
                    .accessibilityLabel("Usage: \(miraState.dailyUsageCount) of \(MiraState.freeLimit) daily requests")
            }

            utilBtn(icon: "gearshape") { showSettings = true }
                .accessibilityLabel("Open settings")
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
    }

    /// Renders as "icon + label" pill when selected, plain icon button when not.
    private func navTab(icon: String, label: String, tab: IslandTab) -> some View {
        let selected = selectedTab == tab
        let accent   = Color(red: 0.29, green: 0.62, blue: 1.0)
        return Button {
            withAnimation(reduceMotion
                ? .easeInOut(duration: 0.10)
                : .spring(response: 0.25, dampingFraction: 0.80)
            ) { selectedTab = tab }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: selected ? 11 : 12, weight: .semibold))
                    .accessibilityHidden(true)
                if selected {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                }
            }
            .foregroundColor(selected ? .white : .white.opacity(0.35))
            .padding(.horizontal, selected ? 10 : 7)
            .padding(.vertical, 5)
            .background(selected ? accent.opacity(0.22) : Color.clear)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Switch to \(label) tab")
    }

    private func utilBtn(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.35))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .briefing:
            BriefingView()
        case .chat:
            IslandChatView(
                miraState: miraState,
                overlay:   overlay,
                capture:   capture,
                voice:     voice,
                wakeWord:  wakeWord
            )
        case .home:
            HomeTabView(miraState: miraState)
        case .projects:
            CombinedProjectsView(
                animController: animController,
                onResume: { prompt in
                    selectedTab = .chat
                    NotificationCenter.default.post(
                        name: .miraChipPromptSelected,
                        object: nil,
                        userInfo: ["prompt": prompt]
                    )
                }
            )
        case .agents:
            AgentsTabView(
                taskStore: taskStore,
                miraState: miraState,
                overlay:   overlay,
                capture:   capture,
                voice:     voice
            )
        case .reliability:
            ReliabilityDashboardView()
        }
    }
}

// MARK: - Combined Projects View (Library + Dev Projects)

private struct CombinedProjectsView: View {
    @ObservedObject var animController: AnimationController
    var onResume: (String) -> Void

    @State private var mode: ProjectsMode = .library

    private let accent = Color(red: 0.29, green: 0.62, blue: 1.0)

    enum ProjectsMode { case library, devProjects, workspace }

    var body: some View {
        VStack(spacing: 0) {
            // Segmented control
            HStack(spacing: 0) {
                modeButton("Library",   mode: .library)
                modeButton("Projects",  mode: .devProjects)
                modeButton("Dashboard", mode: .workspace)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)

            switch mode {
            case .library:
                AgentOutputsView()
            case .devProjects:
                ProjectsTabView(animController: animController, onResume: onResume)
            case .workspace:
                WorkspaceDashboardView()
            }
        }
    }

    private func modeButton(_ title: String, mode: ProjectsMode) -> some View {
        let selected = self.mode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { self.mode = mode }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .white.opacity(0.90) : .white.opacity(0.38))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(selected ? Color.white.opacity(0.10) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Live audio bars

private struct LiveBars: View {
    var color: Color = Color.red.opacity(0.80)

    // Organic waveform: 5 bars with varied heights/delays so the shape looks alive.
    private static let maxHeights: [CGFloat] = [7,  12, 16, 10,  6]
    private static let delays:     [Double]  = [0.00, 0.14, 0.07, 0.21, 0.10]
    private static let durations:  [Double]  = [0.38, 0.44, 0.36, 0.42, 0.40]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Bar(delay:    Self.delays[i],
                    maxH:     Self.maxHeights[i],
                    duration: Self.durations[i],
                    color:    color)
            }
        }
    }

    private struct Bar: View {
        let delay:    Double
        let maxH:     CGFloat
        let duration: Double
        let color:    Color
        @State private var h: CGFloat = 3
        var body: some View {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 2.5, height: h)
                .onAppear {
                    withAnimation(
                        .easeInOut(duration: duration)
                        .repeatForever(autoreverses: true)
                        .delay(delay)
                    ) { h = maxH }
                }
        }
    }
}

// MARK: - Collapsed state indicators

/// Four amber dots that bounce up/down in a staggered wave — used for thinking states.
private struct ThinkingBubbles: View {
    private let delays: [Double] = [0.00, 0.13, 0.26, 0.39]
    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<4, id: \.self) { i in
                Bubble(delay: delays[i])
            }
        }
    }
    private struct Bubble: View {
        let delay: Double
        @State private var up = false
        var body: some View {
            Circle()
                .fill(Color(red: 1.0, green: 0.75, blue: 0.20))
                .frame(width: 5, height: 5)
                .offset(y: up ? -3.5 : 3.5)
                .onAppear {
                    withAnimation(
                        .easeInOut(duration: 0.38)
                        .repeatForever(autoreverses: true)
                        .delay(delay)
                    ) { up = true }
                }
        }
    }
}

private struct CollapsedRecordingDot: View {
    @State private var opacity: Double = 1.0
    var body: some View {
        Circle()
            .fill(Color(red: 0.20, green: 0.84, blue: 0.29))
            .frame(width: 6, height: 6)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.60).repeatForever(autoreverses: true)) {
                    opacity = 0.3
                }
            }
    }
}

private struct CollapsedConnectingDot: View {
    @State private var opacity: Double = 0.3
    var body: some View {
        Circle()
            .fill(Color(red: 0.29, green: 0.62, blue: 1.0))
            .frame(width: 6, height: 6)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.50).repeatForever(autoreverses: true)) {
                    opacity = 1.0
                }
            }
    }
}
