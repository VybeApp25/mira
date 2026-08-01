// LiveActivitiesModule.swift
// The expanded half of Live Activities: what the collapsed strip is rotating
// through, and a Focus toggle per source.
//
// The rotation itself already worked — LiveActivityService picks from a
// priority order taken verbatim from MacNotch's stored array and shows one at a
// time in the pill. What the audit listed as missing was the panel: "Expanded
// view lists active activities with a Focus/Unfocus toggle per activity".
//
// Without it the strip is unreadable in a specific way — you see one source at
// a time for four seconds and have no way to know what else is competing for
// the space, or to say "just show me the timer".

import SwiftUI
import Combine

@MainActor
final class LiveActivitiesModule: NotchModule, ObservableObject {

    let id    = "liveactivities"
    let title = "Live Activities"
    let icon  = "dot.radiowaves.left.and.right"

    let heightLevel: NotchHeightLevel = .compact
    let allowsTallMode = true

    private let service = LiveActivityService.shared
    private var cancellables = Set<AnyCancellable>()

    var subtitle: NotchHeaderSubtitle? {
        if let focused = service.focusedKind {
            return NotchHeaderSubtitle(text: "Focused: \(Self.name(for: focused))", isPill: true)
        }
        let count = service.active.count
        if count == 0 { return NotchHeaderSubtitle(text: "nothing active") }
        return NotchHeaderSubtitle(text: count == 1 ? "1 active" : "\(count) active")
    }

    var headerAccessories: [NotchHeaderAccessory] {
        guard service.focusedKind != nil else { return [] }
        return [NotchHeaderAccessory(id: "unfocus",
                                     systemImage: "pin.slash",
                                     label: "Stop focusing — resume the rotation") { [weak self] in
            guard let kind = self?.service.focusedKind else { return }
            self?.service.toggleFocus(kind)
        }]
    }

    init() {
        service.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    static func name(for kind: LiveActivity.Kind) -> String {
        switch kind {
        case .loading:      return "Loading"
        case .notification: return "Notifications"
        case .bluetooth:  return "Bluetooth"
        case .appUpdates: return "App updates"
        case .systemHUD:  return "Volume & brightness"
        case .power:      return "Power"
        case .media:      return "Media"
        case .pomodoro:   return "Pomodoro"
        case .event:      return "Calendar"
        case .todo:       return "Tasks"
        }
    }

    func makeContent() -> AnyView {
        AnyView(LiveActivitiesView(service: service))
    }
}

// MARK: - View

private struct LiveActivitiesView: View {

    @ObservedObject var service: LiveActivityService
    @ObservedObject private var accentSvc = AccentColorService.shared

    private var accent: Color { accentSvc.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if service.active.isEmpty {
                Text("Nothing is reporting right now. Media, a running timer, a "
                     + "low Bluetooth battery or an upcoming event will appear here.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(service.active) { activity in
                        row(activity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if service.focusedKind != nil {
                Text("Focused — the strip is holding this one instead of rotating.")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.38))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, NotchModuleShellView.headerHeight + 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background(Color.black)
    }

    private func row(_ activity: LiveActivity) -> some View {
        let isFocused = service.focusedKind == activity.kind
        let isOnScreen = service.current?.kind == activity.kind

        return Button {
            service.toggleFocus(activity.kind)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: activity.icon)
                    .font(.system(size: 11))
                    .foregroundColor(activity.tint ?? .white.opacity(0.6))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(LiveActivitiesModule.name(for: activity.kind))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                    Text(activity.text)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.52))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // Which one the pill is showing this second. Without it the
                // panel and the strip look unrelated.
                if isOnScreen && !isFocused {
                    Text("on screen")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.white.opacity(0.35))
                }

                Image(systemName: isFocused ? "pin.fill" : "pin")
                    .font(.system(size: 10))
                    .foregroundColor(isFocused ? accent : .white.opacity(0.25))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(isFocused ? accent.opacity(0.14) : Color.white.opacity(0.04)))
        }
        .buttonStyle(.plain)
        .help(isFocused ? "Stop focusing \(LiveActivitiesModule.name(for: activity.kind))"
                        : "Focus \(LiveActivitiesModule.name(for: activity.kind)) in the strip")
    }
}
