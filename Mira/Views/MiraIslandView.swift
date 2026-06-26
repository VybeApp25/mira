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

enum IslandTab: Equatable { case home, agents, learn, settings, crons, labs }

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
    @ObservedObject private var engine   = ProjectEngine.shared
    @ObservedObject private var pointTo  = PointToService.shared
    // Observe the voice service DIRECTLY so listening/speaking drive the collapsed
    // pill even when the island is closed. (miraState.realtimeState is only mirrored
    // by IslandChatView, which exists only while expanded — so in always-on/closed
    // notch the voice state never reached the pill. PointToService worked because it's
    // observed directly here, which is why "Pointing" opened the notch but voice didn't.)
    @ObservedObject private var realtime = RealtimeVoiceService.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedTab: IslandTab = .home
    @StateObject private var pillState = PillStateModel()
    // Agent flight burst — pulsing ring that fires on job launch
    @State private var showBurst       = false
    @State private var burstScale: CGFloat = 1.0
    @State private var burstOpacity: Double = 0.0
    // Live accent color
    @ObservedObject private var accentSvc = AccentColorService.shared

    private var isExpanded: Bool { animController.state == .expanded }

    // True whenever any non-idle visual indicator should appear in the collapsed pill.
    // Also true while the PointToService cursor is in flight so the pill stays wide.
    private var collapsedIndicatorActive: Bool {
        pillState.mode != .idle || pointTo.isActive
    }

    // Widen the pill when active. Narrower for pure voice states (animation only, no text badge).
    private var pillW: CGFloat {
        if isExpanded { return AnimationController.expandedW }
        guard collapsedIndicatorActive else { return geometry.notchWidth }
        return geometry.notchWidth + (hasCollapsedText ? 120 : 54)
    }

    // A short state label for the collapsed pill (shown in the drop strip BELOW the
    // physical notch — see collapsedDropH). nil when idle.
    private var voiceModeLabel: String? {
        switch pillState.mode {
        case .listening: return "Listening"
        case .thinking:  return "Thinking"
        case .working:   return "Working"
        case .speaking:  return "Speaking"
        case .idle:      return nil
        }
    }
    private var hasCollapsedText: Bool {
        !hudVM.statusText.isEmpty || !taskStore.tasks.isEmpty || pointTo.isActive || voiceModeLabel != nil
    }
    // The physical notch occludes the top `notchHeight`, so collapsed content can't
    // render there. When active we grow the pill DOWNWARD and place the indicator +
    // label in this strip below the cutout (Dynamic-Island style).
    private var collapsedDropH: CGFloat { (!isExpanded && collapsedIndicatorActive) ? 34 : 0 }
    // Settings/agents/crons are content-dense — give them the tall panel.
    private var expandedHeight: CGFloat {
        selectedTab == .home ? AnimationController.expandedH
                             : AnimationController.expandedTallH
    }
    private var pillH: CGFloat { isExpanded ? expandedHeight : geometry.notchHeight + collapsedDropH }
    private var topR:  CGFloat { isExpanded ? AnimationController.expandedTopR : AnimationController.collapsedTopR }
    private var botR:  CGFloat { isExpanded ? AnimationController.expandedBotR : AnimationController.collapsedBotR }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.ignoresSafeArea()
            // State-aware ambient glow behind the collapsed pill.
            // Color shifts with voice state: blue=listening, violet=thinking, teal=speaking/idle.
            if !isExpanded && !reduceMotion {
                NotchAmbientGlow(pillMode: pillState.mode, width: pillW, height: pillH)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.40), value: pillState.mode)
            }
            pill
        }
        .onReceive(NotificationCenter.default.publisher(for: .miraTabSelected)) { notif in
            if let tab = notif.object as? IslandTab {
                withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
            } else if let str = notif.userInfo?["tab"] as? String {
                switch str {
                case "agents": withAnimation(.easeInOut(duration: 0.15)) { selectedTab = .agents }
                case "labs":   withAnimation(.easeInOut(duration: 0.15)) { selectedTab = .labs   }
                default:       withAnimation(.easeInOut(duration: 0.15)) { selectedTab = .home   }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .miraShowLabsClipboard)) { _ in
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = .labs }
        }
        // Keep the hover zone in sync with the per-tab panel height — without
        // this, moving the cursor into the lower half of a tall tab collapses it.
        .onChange(of: selectedTab) { _, _ in
            animController.currentExpandedH = expandedHeight
            NotificationCenter.default.post(name: .miraIslandHeightChanged, object: nil)
        }
        // Opt out of the macOS safe-area inset (menu bar height ≈ 33pt).
        // Without this the pill is pushed ~33pt below the notch, leaving a gap.
        .ignoresSafeArea()
        // Sync existing RealtimeState → PillStateModel (debounced)
        .onChange(of: miraState.realtimeState) { _, new in
            if case .error = new { pillState.postEvent(.error) }
            pillState.syncFromRealtime(new, isListening: voice.isListening, isLoading: miraState.isLoading)
        }
        // Drive the collapsed pill straight from the voice service so always-on
        // listening/speaking animate the closed notch (the miraState mirror above only
        // runs while the panel is expanded). Idempotent with it when both fire.
        .onChange(of: realtime.state) { _, new in
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
        .onReceive(NotificationCenter.default.publisher(for: .miraAgentFlightLaunched)) { _ in
            fireAgentBurst()
        }
    }

    private func fireAgentBurst() {
        guard !reduceMotion else { return }
        burstScale   = 1.0
        burstOpacity = 0.60
        showBurst    = true
        withAnimation(.easeOut(duration: 0.55)) {
            burstScale   = 2.8
            burstOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.60) { showBurst = false }
    }

    // MARK: - Pill container

    @AppStorage("mira_transparent_panes") private var transparentPanes = false

    private var pill: some View {
        ZStack {
            if isExpanded {
                if transparentPanes {
                    DS.Colors.background.opacity(0.75)
                        .background(.ultraThinMaterial)
                } else {
                    DS.Colors.background
                }
            } else {
                // Pure black matches the hardware notch exactly — any off-black creates a visible seam.
                Color.black
            }
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
            // Collapsed: centered in the pill (HeyClicky NotchActivitySurface placement).
            // Expanded:  top-right area of nav bar (88 pt from trailing to clear gear/mic).
            // Collapsed: the live waveform sits in the LEFT EAR beside the cutout (at
            // notch height) — glanceable like the iPhone Dynamic Island. The cutout
            // can't be drawn on; the ear is empty menu-bar space next to it. The text
            // label drops just below (collapsedContent). Expanded: top-right of nav bar.
            SharedStatusView(pillState: pillState, isCompact: !isExpanded)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: isExpanded ? .topTrailing : .topLeading)
                .padding(.trailing, isExpanded ? 88 : 0)
                .padding(.leading, isExpanded ? 0 : 14)
                .padding(.top, isExpanded ? 12 : 7)
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
        // Glass border on expanded panel — mirrors HeyClicky's NotchSilhouetteBorderShape.
        .overlay(
            IslandShape(topRadius: topR, bottomRadius: botR)
                .stroke(Color.white.opacity(isExpanded ? 0.08 : 0), lineWidth: 0.5)
        )
        // NotchGlowView — colored ring border when collapsed + active
        .overlay(
            IslandShape(topRadius: topR, bottomRadius: botR)
                .stroke(
                    collapsedAccent.opacity(!isExpanded && collapsedIndicatorActive && !reduceMotion ? 0.38 : 0),
                    lineWidth: 1.2
                )
                .blur(radius: 2)
                .allowsHitTesting(false)
        )
        // Agent launch burst ring
        .overlay(
            Group {
                if showBurst {
                    IslandShape(topRadius: botR, bottomRadius: botR)
                        .stroke(collapsedAccent.opacity(burstOpacity), lineWidth: 2.5)
                        .scaleEffect(burstScale)
                        .allowsHitTesting(false)
                }
            }
        )
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

    // Supplementary left-side badge when an agent task or cursor action is active.
    // Voice states (listening/thinking/speaking) show no text — the centered animation speaks.
    private var collapsedContent: some View {
        HStack(spacing: 0) {
            Group {
                if !hudVM.statusText.isEmpty {
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
                        .background(DS.Colors.accent)
                        .clipShape(Capsule())
                        .transition(.opacity)
                } else if pointTo.isActive {
                    HStack(spacing: 5) {
                        Image(systemName: "triangle.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(miraTeale)
                            .rotationEffect(.degrees(90))
                        Text("Pointing")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(miraTeale.opacity(0.85))
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.80, anchor: .leading)))
                } else if let label = voiceModeLabel {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(collapsedAccent.opacity(0.9))
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
        }
        // Centered in the drop strip BELOW the physical notch (top of the pill is
        // occluded by the camera cutout); the waveform lives in the ear above-left.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 14)
        .padding(.bottom, 9)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: hudVM.statusText)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: taskStore.tasks.count)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: pointTo.isActive)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: voiceModeLabel)
    }

    private var collapsedAccent: Color {
        switch pillState.mode {
        case .listening: return DS.Colors.accent
        case .thinking:  return miraViolet
        case .working:   return miraViolet
        case .speaking:  return miraTeale
        case .idle:      return miraTeale
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
                SidecarSuggestionBanner()
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
            let accent = DS.Colors.accent
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
                        selectedTab = .home
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
                .agentHUDPillChrome()
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
                    selectedTab = .home
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
        .background(DS.Colors.background)
    }

    private func hoverSummaryBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.fill")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.accent.opacity(0.6))
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
            navTab(icon: "house.fill",         label: "Home",     tab: .home)
            navTab(icon: "cpu.fill",           label: "Agents",   tab: .agents)
            navTab(icon: "sparkles",           label: "Labs",     tab: .labs)
            navTab(icon: "graduationcap.fill", label: "Learn",    tab: .learn)
            navTab(icon: "clock.fill",         label: "Crons",    tab: .crons)
            navTab(icon: "gearshape.fill",     label: "Settings", tab: .settings)

            Spacer()

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

            if !miraState.isPro {
                Text("\(miraState.dailyUsageCount)/\(MiraState.freeLimit)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
                    .padding(.trailing, 2)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private func navTab(icon: String, label: String, tab: IslandTab) -> some View {
        let selected = selectedTab == tab
        let accent   = DS.Colors.accent
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
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }


    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .home:
            IslandChatView(
                miraState: miraState,
                overlay:   overlay,
                capture:   capture,
                voice:     voice,
                wakeWord:  wakeWord
            )
        case .agents:
            AgentsTabView(
                taskStore: taskStore,
                miraState: miraState,
                overlay:   overlay,
                capture:   capture,
                voice:     voice
            )
        case .labs:
            LabsTabView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .learn:
            LessonsTabView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .crons:
            CronsTabView()
        case .settings:
            SettingsView(state: miraState, embedded: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            .fill(DS.Colors.accent)
            .frame(width: 6, height: 6)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.50).repeatForever(autoreverses: true)) {
                    opacity = 1.0
                }
            }
    }
}

// MARK: - State-aware ambient glow

// Color-shifting bloom halo behind the collapsed pill — mirrors HeyClicky's CornerGlowLayer.
// Uses a raised-cosine squared (gamma) curve so the glow breathes organically.
// Color shifts with voice state: blue=listening, violet=thinking, teal=speaking/idle.
private struct NotchAmbientGlow: View {
    let pillMode: PillMode
    let width:    CGFloat
    let height:   CGFloat

    private var glowColor: Color {
        switch pillMode {
        case .idle, .speaking: return miraTeale
        case .listening, .working: return DS.Colors.accent
        case .thinking: return miraViolet
        }
    }
    private var baseOpacity: CGFloat {
        switch pillMode {
        case .idle: return 0.04
        case .listening: return 0.10
        case .working: return 0.08
        case .thinking: return 0.10
        case .speaking: return 0.12
        }
    }
    private var peakOpacity: CGFloat {
        switch pillMode {
        case .idle: return 0.11
        case .listening: return 0.20
        case .working: return 0.16
        case .thinking: return 0.20
        case .speaking: return 0.22
        }
    }

    var body: some View {
        let c = glowColor
        let b = baseOpacity
        let p = peakOpacity
        return TimelineView(.animation(minimumInterval: 1.0 / 8.0)) { ctx in
            let t     = ctx.date.timeIntervalSinceReferenceDate
            let raw   = CGFloat((cos(t / 3.4 * .pi * 2) + 1) / 2)
            let bloom = raw * raw
            RoundedRectangle(cornerRadius: height / 2 + 10)
                .fill(
                    RadialGradient(
                        colors: [
                            c.opacity(b + bloom * p),
                            c.opacity(0),
                        ],
                        center:      .center,
                        startRadius: 0,
                        endRadius:   max(width, height) * 0.70
                    )
                )
                .frame(width: width + 52, height: height + 30)
                .blur(radius: 7)
        }
    }
}

// MARK: - Press-scale button style (HeyClicky's NotchTabPressButtonStyle)

private struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}
