import SwiftUI

// MARK: - FrostedGlass ViewModifier
// Port of the interactive-frosted-glass-card React component (MIT) to SwiftUI.
// Shared across FloatingAgentChipView, ResponseCardView, and any future cards.
// Defined here (compiled into the target) so all Views can use .frostedGlass().

private struct GlassCardSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct FrostedGlass: ViewModifier {
    var cornerRadius: CGFloat = 16
    var tiltDegrees:  CGFloat = 10
    var glareOpacity: CGFloat = 0.18

    @State private var hovered:  Bool    = false
    @State private var hoverLoc: CGPoint = .zero
    @State private var cardSize: CGSize  = .zero

    private var tiltX: Double {
        guard hovered, cardSize.height > 0 else { return 0 }
        return Double((hoverLoc.y / cardSize.height - 0.5) * -tiltDegrees)
    }
    private var tiltY: Double {
        guard hovered, cardSize.width > 0 else { return 0 }
        return Double((hoverLoc.x / cardSize.width  - 0.5) *  tiltDegrees)
    }

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: GlassCardSizeKey.self, value: geo.size)
                }
            )
            .onPreferenceChange(GlassCardSizeKey.self) { size in
                if size != .zero { cardSize = size }
            }
            .background(glassLayers)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.42), radius: 22, x: 0, y: 10)
            .rotation3DEffect(.degrees(tiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
            .rotation3DEffect(.degrees(tiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.65), value: tiltX)
            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.65), value: tiltY)
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    if !hovered { hovered = true }
                    hoverLoc = loc
                case .ended:
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { hovered = false }
                }
            }
    }

    @ViewBuilder
    private var glassLayers: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(red: 0.06, green: 0.06, blue: 0.13).opacity(0.62))
            if hovered {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(RadialGradient(
                        colors: [Color.white.opacity(glareOpacity), .clear],
                        center: UnitPoint(
                            x: cardSize.width  > 0 ? Double(hoverLoc.x / cardSize.width)  : 0.5,
                            y: cardSize.height > 0 ? Double(hoverLoc.y / cardSize.height) : 0.5
                        ),
                        startRadius: 0,
                        endRadius:   max(cardSize.width, cardSize.height) * 0.75
                    ))
                    .animation(.linear(duration: 0), value: hoverLoc)
            }
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(LinearGradient(
                    colors: [Color.white.opacity(0.30), Color.white.opacity(0.06)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ), lineWidth: 1)
        }
    }
}

extension View {
    func frostedGlass(cornerRadius: CGFloat = 16, tiltDegrees: CGFloat = 10) -> some View {
        modifier(FrostedGlass(cornerRadius: cornerRadius, tiltDegrees: tiltDegrees))
    }
}

// MARK: - Status color palette

extension AgentJobStatus {
    var hudColor: Color {
        switch self {
        case .queued, .preparing, .reading, .running, .writing:
            return Color(red: 0.18, green: 0.56, blue: 1.00)
        case .waitingForInput, .waitingForConfirmation, .waitingForVariantSelection:
            return Color(red: 1.00, green: 0.75, blue: 0.20)
        case .blockedPermission, .blockedTool:
            return Color(red: 1.00, green: 0.55, blue: 0.15)
        case .completed:
            return Color(red: 0.20, green: 0.84, blue: 0.29)
        case .failed:
            return Color(red: 1.00, green: 0.35, blue: 0.35)
        case .cancelled:
            return Color.white.opacity(0.35)
        }
    }

    var hudLabel: String {
        switch self {
        case .queued:                       return "Queued"
        case .preparing:                    return "Preparing"
        case .reading:                      return "Reading"
        case .running:                      return "Running"
        case .writing:                      return "Writing"
        case .waitingForInput:              return "Waiting"
        case .waitingForConfirmation:       return "Approval"
        case .waitingForVariantSelection:   return "Selection"
        case .blockedPermission:            return "Blocked"
        case .blockedTool:                  return "Blocked"
        case .completed:                    return "Done"
        case .failed:                       return "Failed"
        case .cancelled:                    return "Cancelled"
        }
    }
}

// MARK: - FloatingAgentChipView
//
// Three states:
//   minimized = true  → micro-chip pill (190pt wide, 38pt tall)
//   minimized = false, expanded = false → compact card with frosted glass
//   minimized = false, expanded = true  → full card with steps + actions

struct FloatingAgentChipView: View {
    let job: AgentJob
    @ObservedObject private var store: AgentJobStore
    @State private var expanded  = false
    @State private var minimized = false

    init(job: AgentJob) {
        self.job    = job
        self._store = ObservedObject(wrappedValue: AgentJobStore.shared)
    }

    private var accent: Color { job.status.hudColor }

    var body: some View {
        Group {
            if minimized {
                microChipView
            } else {
                fullChipView
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal:   .move(edge: .trailing).combined(with: .opacity)
        ))
    }

    // MARK: - Micro chip (minimized state)

    private var microChipView: some View {
        HStack(spacing: 8) {
            // Glyph tile
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(accent.opacity(0.18))
                    .frame(width: 26, height: 26)
                if job.status.isActive {
                    BlueCursorSpinnerPublic(color: accent).frame(width: 13, height: 13)
                } else {
                    Image(systemName: job.type.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(accent)
                }
            }

            Text(shortTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.88))
                .lineLimit(1)

            Spacer(minLength: 4)

            // Status dot
            Circle().fill(accent).frame(width: 5, height: 5)

            // Expand / restore button
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { minimized = false }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(width: 20, height: 20)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 190)
        .frostedGlass(cornerRadius: 13, tiltDegrees: 6)
        // Report bounds for hit-testing
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: AgentHUDInteractiveRectKey.self,
                                       value: geo.frame(in: .global))
            }
        )
    }

    // MARK: - Full chip (normal + expanded)

    private var fullChipView: some View {
        VStack(spacing: 0) {
            chipHeader
            if expanded { chipExpandedStrip }
        }
        // Frosted glass replaces the solid dark background
        .frostedGlass(cornerRadius: 16, tiltDegrees: 8)
        // Animated chrome border while running
        .modifier(job.status.isActive
            ? AnyViewModifier(AgentHUDPillChrome())
            : AnyViewModifier(EmptyModifier()))
        // Report bounds for hit-testing
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: AgentHUDInteractiveRectKey.self,
                                       value: geo.frame(in: .global))
            }
        )
        .onTapGesture {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { expanded.toggle() }
        }
        .frame(width: 280)
    }

    // MARK: - Compact header row

    private var chipHeader: some View {
        HStack(spacing: 10) {
            glyphTile

            VStack(alignment: .leading, spacing: 2) {
                Text(jobTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)

                if job.status.isActive {
                    Text(job.currentStep)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                } else if let summary = job.result?.summary {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                } else if let err = job.errorMessage {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(accent.opacity(0.80))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statusChipView

            // Minimize to micro-chip
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { minimized = true }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.38))
                    .frame(width: 20, height: 20)
                    .background(Color.white.opacity(0.07))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Expanded detail strip

    private var chipExpandedStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().background(Color.white.opacity(0.07))

            // Progress bar for active jobs
            if job.status.isActive && job.progress > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Color.white.opacity(0.06)
                        accent.opacity(0.70)
                            .frame(width: geo.size.width * CGFloat(job.progress))
                            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: job.progress)
                    }
                }
                .frame(height: 3)
            }

            // Activity timeline (last 4 steps)
            let visibleSteps = job.steps.suffix(4)
            if !visibleSteps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(visibleSteps.enumerated()), id: \.element.id) { _, step in
                        HStack(spacing: 6) {
                            stepDot(status: step.status)
                            Text(step.title)
                                .font(.system(size: 11))
                                .foregroundColor(step.status.isTerminal
                                    ? .white.opacity(0.38)
                                    : .white.opacity(0.80))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            // Action buttons (terminal jobs only)
            if job.status.isTerminal {
                Divider().background(Color.white.opacity(0.07))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(job.actions.prefix(3)) { action in
                            followUpButton(title: action.title, icon: action.icon) {
                                handleAction(action.identifier)
                            }
                        }
                        followUpButton(title: "Dismiss", icon: "xmark") {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                AgentJobStore.shared.hideFromHUD(id: job.id)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - Sub-components

    private var glyphTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(accent.opacity(0.15))
                .frame(width: 34, height: 34)

            if job.status.isActive {
                BlueCursorSpinnerPublic(color: accent).frame(width: 18, height: 18)
            } else {
                Image(systemName: job.type.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(accent)
            }
        }
    }

    private var statusChipView: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(accent)
                .frame(width: 5, height: 5)
                .opacity(job.status.isActive ? 1 : 0.6)

            Text(job.status.hudLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(accent)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(job.status.isTerminal ? 0.12 : 0.18))
        )
    }

    private func stepDot(status: AgentJobStatus) -> some View {
        Circle()
            .fill(status.hudColor)
            .frame(width: 5, height: 5)
            .opacity(status.isTerminal ? 0.45 : 1.0)
    }

    private func followUpButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.70))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var jobTitle: String {
        let words = job.prompt.split(separator: " ").prefix(6).joined(separator: " ")
        return words.isEmpty ? job.type.rawValue : words
    }

    private var shortTitle: String {
        let words = job.prompt.split(separator: " ").prefix(3).joined(separator: " ")
        return words.isEmpty ? job.type.rawValue : words
    }

    private func handleAction(_ identifier: String) {
        switch identifier {
        case "open_browser", "open_live_site":
            if let url = job.result?.metadata["deployedUrl"] ?? job.result?.metadata["previewUrl"],
               let u = URL(string: url) { NSWorkspace.shared.open(u) }
        case "copy_url":
            if let url = job.result?.metadata["deployedUrl"] {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
        case "open_project":
            if let path = job.result?.outputPath, let u = URL(string: "file://\(path)") {
                NSWorkspace.shared.open(u)
            }
        default:
            NotificationCenter.default.post(
                name: .agentHUDAction,
                object: nil,
                userInfo: ["jobId": job.id, "action": identifier]
            )
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { expanded = false }
    }
}

// MARK: - AnyViewModifier helper

private struct AnyViewModifier: ViewModifier {
    private let _body: (AnyView) -> AnyView
    init<M: ViewModifier>(_ modifier: M) { _body = { AnyView($0.modifier(modifier)) } }
    func body(content: Content) -> some View { _body(AnyView(content)) }
}

private struct EmptyModifier: ViewModifier {
    func body(content: Content) -> some View { content }
}

// MARK: - Spinner

struct BlueCursorSpinnerPublic: View {
    let color: Color
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let agentHUDAction = Notification.Name("mira.agentHUD.action")
}
