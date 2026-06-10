import SwiftUI

// MARK: - Status color palette (HeyClicky: agentRunningColor / agentDone / agentFailed / agentComplete)

extension AgentJobStatus {
    var hudColor: Color {
        switch self {
        case .queued, .preparing, .reading, .running, .writing:
            return Color(red: 0.18, green: 0.56, blue: 1.00)   // blue — running
        case .waitingForInput, .waitingForConfirmation, .waitingForVariantSelection:
            return Color(red: 1.00, green: 0.75, blue: 0.20)   // amber — waiting
        case .blockedPermission, .blockedTool:
            return Color(red: 1.00, green: 0.55, blue: 0.15)   // orange — blocked
        case .completed:
            return Color(red: 0.20, green: 0.84, blue: 0.29)   // green — done
        case .failed:
            return Color(red: 1.00, green: 0.35, blue: 0.35)   // red — failed
        case .cancelled:
            return Color.white.opacity(0.35)                    // gray — cancelled
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
// Mirrors HeyClicky's FloatingAgentChip: collapsed pill with glyphTile,
// primaryLiveContent, statusIndicatorDot, and expandable detail strip.

// MARK: - FloatingAgentChipView is internal (not private) so AgentHUDColumnView can see it

struct FloatingAgentChipView: View {
    let job: AgentJob
    @ObservedObject private var store: AgentJobStore
    @State private var expanded = false
    @State private var hovered  = false

    init(job: AgentJob) {
        self.job   = job
        self._store = ObservedObject(wrappedValue: AgentJobStore.shared)
    }

    private var accent: Color { job.status.hudColor }
    private var bg = Color(red: 0.09, green: 0.09, blue: 0.12)

    var body: some View {
        VStack(spacing: 0) {
            chipHeader
            if expanded { chipExpandedStrip }
        }
        .background(chipBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(chipBorder)
        .shadow(color: .black.opacity(0.30), radius: 12, x: 0, y: 4)
        // AgentHUDPillChrome animated border while running
        .modifier(job.status.isActive ? AnyViewModifier(AgentHUDPillChrome()) : AnyViewModifier(EmptyModifier()))
        // Report bounds to AgentHUDPanel for hit-testing
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: AgentHUDInteractiveRectKey.self,
                    value: geo.frame(in: .global)
                )
            }
        )
        .onHover { hovered = $0 }
        .onTapGesture { withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { expanded.toggle() } }
        .frame(width: 280)
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal:   .move(edge: .trailing).combined(with: .opacity)
        ))
    }

    // MARK: - Collapsed header (glyphTile + primaryLiveContent + statusIndicatorDot)

    private var chipHeader: some View {
        HStack(spacing: 10) {
            // glyphTile
            glyphTile

            // primaryLiveContent
            VStack(alignment: .leading, spacing: 2) {
                Text(jobTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)

                if job.status.isActive {
                    // liveTrackLine / current step
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

            // statusIndicatorDot + statusChip
            statusChipView
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Expanded strip (steps + actions + dismiss)

    private var chipExpandedStrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .background(Color.white.opacity(0.07))

            // Running progress bar
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
                                    ? .white.opacity(0.40)
                                    : .white.opacity(0.80))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            // Action buttons row (followUpRow equivalent)
            if job.status.isTerminal {
                Divider().background(Color.white.opacity(0.07))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(job.actions.prefix(3)) { action in
                            followUpButton(title: action.title, icon: action.icon) {
                                handleAction(action.identifier)
                            }
                        }

                        // Dismiss button
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
                // Spinner overlay for active jobs
                BlueCursorSpinnerPublic(color: accent)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: job.type.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(accent)
            }
        }
    }

    // statusChip(label:accent:solid:) equivalent
    private var statusChipView: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(accent)
                .frame(width: 5, height: 5)
                .opacity(job.status.isActive ? 1 : 0.6)
                .scaleEffect(job.status.isActive ? 1.0 : 1.0)

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

    private var chipBackground: some View {
        ZStack {
            bg
            if hovered {
                Color.white.opacity(0.03)
            }
        }
    }

    private var chipBorder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
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
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.70))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var jobTitle: String {
        let words = job.prompt.split(separator: " ").prefix(6).joined(separator: " ")
        return words.isEmpty ? job.type.rawValue : words
    }

    private func handleAction(_ identifier: String) {
        switch identifier {
        case "open_browser", "open_live_site":
            if let url = job.result?.metadata["deployedUrl"] ?? job.result?.metadata["previewUrl"],
               let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
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

    init<M: ViewModifier>(_ modifier: M) {
        _body = { AnyView($0.modifier(modifier)) }
    }

    func body(content: Content) -> some View {
        _body(AnyView(content))
    }
}

private struct EmptyModifier: ViewModifier {
    func body(content: Content) -> some View { content }
}

// MARK: - Spinner (public alias of BlueCursorView internal)

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
