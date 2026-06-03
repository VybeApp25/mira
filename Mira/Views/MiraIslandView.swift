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

enum IslandTab: Equatable { case chat, home, agents }

// MARK: - Main island view

struct MiraIslandView: View {
    @ObservedObject var animController: AnimationController
    @ObservedObject var miraState:      MiraState
    @ObservedObject var taskStore:      AgentTaskStore
    @ObservedObject var overlay:        OverlayWindowController
    let capture:  ScreenCaptureService
    @ObservedObject var voice:     VoiceService
    let geometry: NotchGeometry

    @State private var selectedTab: IslandTab = .chat
    @State private var showSettings = false

    private var isExpanded: Bool { animController.state == .expanded }

    private var pillW: CGFloat { isExpanded ? AnimationController.expandedW : geometry.notchWidth  }
    private var pillH: CGFloat { isExpanded ? AnimationController.expandedH : geometry.notchHeight }
    private var topR:  CGFloat { isExpanded ? AnimationController.expandedTopR : AnimationController.collapsedTopR }
    private var botR:  CGFloat { isExpanded ? AnimationController.expandedBotR : AnimationController.collapsedBotR }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.ignoresSafeArea()
            pill
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(state: miraState)
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
        }
        .frame(width: pillW, height: pillH)
        .clipShape(IslandShape(topRadius: topR, bottomRadius: botR))
        .shadow(color: isExpanded ? .black.opacity(0.70) : .clear, radius: 20, x: 0, y: 22)
        .animation(
            isExpanded
                ? .spring(response: 0.40, dampingFraction: 0.74, blendDuration: 0)
                : .spring(response: 0.30, dampingFraction: 0.82, blendDuration: 0),
            value: isExpanded
        )
    }

    // MARK: - Collapsed pill

    private var collapsedContent: some View {
        HStack(spacing: 7) {
            Image(systemName: "eye.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(red: 0.29, green: 0.62, blue: 1.0))
            if voice.isListening { LiveBars() }
            if !taskStore.tasks.isEmpty {
                Text("\(taskStore.tasks.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Color(red: 0.29, green: 0.62, blue: 1.0))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Expanded layout

    private var expandedContent: some View {
        VStack(spacing: 0) {
            navBar
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 0.5)
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Inline nav bar

    private var navBar: some View {
        HStack(spacing: 2) {
            // Left group — primary tabs
            navTab(icon: "message.fill", label: "Chat",   tab: .chat)
            navTab(icon: "house.fill",   label: "Home",   tab: .home)
            navTab(icon: "cpu",          label: "Agents", tab: .agents)

            Spacer()

            // Right group — status + utilities
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

            if !miraState.isPro {
                Text("\(miraState.dailyUsageCount)/\(MiraState.freeLimit)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
                    .padding(.trailing, 4)
            }

            utilBtn(icon: "gearshape") { showSettings = true }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
    }

    /// Renders as "icon + label" pill when selected, plain icon button when not.
    private func navTab(icon: String, label: String, tab: IslandTab) -> some View {
        let selected = selectedTab == tab
        let accent   = Color(red: 0.29, green: 0.62, blue: 1.0)
        return Button { withAnimation(.spring(response: 0.25, dampingFraction: 0.80)) { selectedTab = tab } } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: selected ? 11 : 12, weight: .semibold))
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
        case .chat:
            IslandChatView(
                miraState: miraState,
                overlay:   overlay,
                capture:   capture,
                voice:     voice
            )
        case .home:
            HomeTabView(miraState: miraState)
        case .agents:
            AgentsTabView(
                taskStore: taskStore,
                miraState: miraState,
                overlay:   overlay,
                capture:   capture,
                voice:     voice
            )
        }
    }
}

// MARK: - Live audio bars

private struct LiveBars: View {
    var body: some View {
        HStack(spacing: 2) {
            Bar(delay: 0.00); Bar(delay: 0.12); Bar(delay: 0.24)
        }
    }
    private struct Bar: View {
        let delay: Double
        @State private var h: CGFloat = 4
        var body: some View {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.red.opacity(0.80))
                .frame(width: 3, height: h)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.40).repeatForever(autoreverses: true).delay(delay)) { h = 14 }
                }
        }
    }
}
