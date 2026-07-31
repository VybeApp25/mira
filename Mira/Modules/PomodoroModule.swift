// PomodoroModule.swift
// MacNotch's Pomodoro panel: work/break cycles with progress in the UI, a
// reorderable preset list, and a Focus Target attached to something on today's
// schedule. Scored 🟡 in the audit — the cycle machine already existed as a dock
// widget, but the presets, the target and a real panel did not.
//
// Layout follows the shell's 2-column grammar (audit §1.1): a narrow left index
// of presets, a wide right pane with the ring and transport. The target picker
// is a drill-in rather than a popover, because a popover is a second window and
// the slab is supposed to read as one object.

import SwiftUI
import EventKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class PomodoroModule: NotchModule, ObservableObject {

    let id    = "pomodoro"
    let title = "Pomodoro"
    let icon  = "timer"

    let heightLevel: NotchHeightLevel = .standard
    let allowsTallMode = false

    private let pom       = PomodoroService.shared
    private let calendar  = CalendarTodayService.shared
    private let reminders = RemindersService.shared
    private var cancellables = Set<AnyCancellable>()

    /// True while the Focus Target picker is pushed.
    @Published private(set) var isPickingTarget = false

    var detailTitle: String? { isPickingTarget ? "Pomodoro" : nil }
    func popDetail() { isPickingTarget = false }

    var subtitle: NotchHeaderSubtitle? {
        if isPickingTarget {
            return NotchHeaderSubtitle(text: "Focus Target", isPill: true)
        }
        if let target = pom.focusTarget {
            return NotchHeaderSubtitle(text: target.title, isPill: true)
        }
        return NotchHeaderSubtitle(text: "\(pom.completed) of \(pom.sessionsPerSet)")
    }

    var headerAccessories: [NotchHeaderAccessory] {
        guard !isPickingTarget else { return [] }
        var out: [NotchHeaderAccessory] = []
        out.append(NotchHeaderAccessory(
            id: "target",
            systemImage: "target",
            label: pom.focusTarget == nil ? "Pick a focus target" : "Change focus target",
            isProminent: pom.focusTarget != nil
        ) { [weak self] in
            self?.beginPickingTarget()
        })
        out.append(NotchHeaderAccessory(
            id: "reset",
            systemImage: "arrow.counterclockwise",
            label: "Reset the cycle"
        ) { PomodoroService.shared.reset() })
        return out
    }

    init() {
        for p in [pom.objectWillChange, calendar.objectWillChange, reminders.objectWillChange] {
            p.sink { [weak self] _ in self?.objectWillChange.send() }
             .store(in: &cancellables)
        }
    }

    private func beginPickingTarget() {
        // Ask for access at the moment the user asks to see the list, not at
        // launch — the timer itself needs no calendar permission at all.
        calendar.requestAccess()
        reminders.requestAccess()
        isPickingTarget = true
    }

    func didDisappear() {
        // Don't strand the panel in a pushed state; switching modules and coming
        // back should land on the timer.
        isPickingTarget = false
    }

    func makeContent() -> AnyView {
        AnyView(PomodoroModuleView(module: self,
                                   pom: pom,
                                   calendar: calendar,
                                   reminders: reminders))
    }
}

// MARK: - View

private struct PomodoroModuleView: View {

    @ObservedObject var module: PomodoroModule
    @ObservedObject var pom: PomodoroService
    @ObservedObject var calendar: CalendarTodayService
    @ObservedObject var reminders: RemindersService
    @ObservedObject private var accentSvc = AccentColorService.shared

    private var accent: Color { accentSvc.color }

    var body: some View {
        Group {
            if module.isPickingTarget {
                targetPicker
            } else {
                timer
            }
        }
        .padding(.top, NotchModuleShellView.headerHeight + 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background(Color.black)
    }

    // MARK: Timer pane

    private var timer: some View {
        HStack(alignment: .top, spacing: 14) {
            presetRail
            Divider().overlay(Color.white.opacity(0.08))
            ring
        }
    }

    // MARK: Left index — presets

    private var presetRail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PRESETS")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.32))
                .padding(.leading, 2)

            ForEach(pom.presets) { preset in
                PresetRow(preset: preset,
                          minutes: pom.minutes(for: preset),
                          isActive: pom.activePresetID == preset.id,
                          accent: accent,
                          onTap: { pom.start(preset) },
                          onNudge: { delta in
                              pom.setMinutes(pom.minutes(for: preset) + delta, for: preset.id)
                          })
                    .onDrag { NSItemProvider(object: preset.id as NSString) }
                    .onDrop(of: [.text], delegate: PresetDropDelegate(target: preset, service: pom))
            }
            Spacer(minLength: 0)
        }
        // Wide enough that "Quick Timer" still fits once the ± nudges appear on
        // hover — at 128 the longest preset name truncated to "Quick…".
        .frame(width: 146, alignment: .leading)
    }

    // MARK: Right pane — ring and transport

    private var ring: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(phaseColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.9), value: progress)

                VStack(spacing: 1) {
                    Text(clock)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white)
                    Text(phaseName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            .frame(width: 104, height: 104)

            transport
            targetChip
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var transport: some View {
        HStack(spacing: 10) {
            circleButton(pom.isRunning ? "pause.fill" : "play.fill",
                         label: pom.isRunning ? "Pause" : "Start",
                         prominent: true) {
                pom.isRunning ? pom.pause() : pom.start()
            }
            circleButton("forward.end.fill", label: "Skip to the next phase") { pom.skip() }
        }
    }

    private func circleButton(_ symbol: String,
                              label: String,
                              prominent: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 12 : 10, weight: .semibold))
                .foregroundColor(prominent ? .black : .white.opacity(0.75))
                .frame(width: prominent ? 30 : 24, height: prominent ? 30 : 24)
                .background(Circle().fill(prominent ? accent : Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    /// The focus target, shown where you're looking while the timer runs. Also
    /// the way to clear it — the header button only ever adds or replaces.
    @ViewBuilder
    private var targetChip: some View {
        if let target = pom.focusTarget {
            HStack(spacing: 5) {
                Image(systemName: target.kind == .event ? "calendar" : "checklist")
                    .font(.system(size: 9))
                Text(target.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Button {
                    pom.focusTarget = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Clear the focus target")
            }
            .foregroundColor(.white.opacity(0.72))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }
    }

    // MARK: Detail — focus target picker

    private var targetPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                if todaysItems.isEmpty {
                    // An empty list has two very different causes and only one of
                    // them is the user's problem to fix. Saying "nothing to focus
                    // on" when we were simply never granted access is a lie the
                    // user can't act on.
                    Text(emptyStateText)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(.top, 8)
                }
                ForEach(todaysItems, id: \.id) { item in
                    Button {
                        pom.focusTarget = item
                        module.popDetail()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.kind == .event ? "calendar" : "checklist")
                                .font(.system(size: 10))
                                .foregroundColor(accent)
                                .frame(width: 14)
                            Text(item.title)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.88))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if pom.focusTarget?.id == item.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(accent)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(pom.focusTarget?.id == item.id ? Color.white.opacity(0.07) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            // Without this the VStack sizes to its content and the ScrollView
            // centers it, which reads as a different layout from every other
            // module's left-aligned list.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyStateText: String {
        guard calendar.checked, reminders.checked else { return "Checking your schedule…" }
        if !calendar.permitted && !reminders.permitted {
            return "Mira needs Calendar and Reminders access to list today's items."
        }
        return "Nothing on today's schedule to focus on."
    }

    /// Today's events and reminders, flattened into the stored target shape.
    private var todaysItems: [PomodoroService.FocusTarget] {
        let cal = Calendar.current
        var out: [PomodoroService.FocusTarget] = []

        for e in calendar.eventsByDay[cal.startOfDay(for: Date())] ?? [] where !e.isAllDay {
            out.append(.init(id: e.eventIdentifier ?? UUID().uuidString,
                             title: e.title ?? "Untitled",
                             kind: .event))
        }
        for r in reminders.reminders where !r.isCompleted {
            guard let due = r.dueDateComponents?.date, cal.isDateInToday(due) else { continue }
            out.append(.init(id: r.calendarItemIdentifier,
                             title: r.title ?? "Reminder",
                             kind: .reminder))
        }
        return out
    }

    // MARK: Derived

    private var totalSeconds: Int {
        switch pom.phase {
        case .focus:
            // A running Quick/Custom preset defines its own total; without this
            // the ring is drawn against pom_focus and reads as already part-way
            // through the moment a 5-minute timer starts.
            if let id = pom.activePresetID,
               let p = pom.presets.first(where: { $0.id == id }) {
                return pom.minutes(for: p) * 60
            }
            return pom.focusMins * 60
        case .shortBreak: return pom.shortBreakMins * 60
        case .longBreak:  return pom.longBreakMins * 60
        }
    }

    private var progress: CGFloat {
        guard totalSeconds > 0 else { return 0 }
        return CGFloat(totalSeconds - pom.secondsLeft) / CGFloat(totalSeconds)
    }

    private var clock: String {
        String(format: "%d:%02d", pom.secondsLeft / 60, pom.secondsLeft % 60)
    }

    private var phaseName: String {
        switch pom.phase {
        case .focus:      return "FOCUS"
        case .shortBreak: return "SHORT BREAK"
        case .longBreak:  return "LONG BREAK"
        }
    }

    private var phaseColor: Color {
        switch pom.phase {
        case .focus:      return accent
        case .shortBreak: return Color(red: 0.40, green: 0.80, blue: 0.62)
        case .longBreak:  return Color(red: 0.45, green: 0.66, blue: 0.95)
        }
    }
}

// MARK: - Preset row

private struct PresetRow: View {

    let preset: PomodoroService.Preset
    let minutes: Int
    let isActive: Bool
    let accent: Color
    let onTap: () -> Void
    let onNudge: (Int) -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: preset.systemImage)
                    .font(.system(size: 10))
                    .foregroundColor(isActive ? accent : .white.opacity(0.55))
                    .frame(width: 13)

                Text(preset.name)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundColor(.white.opacity(isActive ? 0.95 : 0.78))
                    .lineLimit(1)

                Spacer(minLength: 2)

                // Editable presets get ± on hover; built-ins just show the
                // length they inherit from Settings.
                if !preset.isBuiltIn && hovering {
                    nudge("minus", -1)
                    nudge("plus", 1)
                } else {
                    Text("\(minutes)m")
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.38))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? accent.opacity(0.16)
                               : (hovering ? Color.white.opacity(0.06) : .clear)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(preset.isBuiltIn
              ? "Start \(preset.name) — \(minutes) minutes, set in Settings"
              : "Start \(preset.name) — \(minutes) minutes")
    }

    private func nudge(_ symbol: String, _ delta: Int) -> some View {
        Button { onNudge(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.65))
                .frame(width: 13, height: 13)
                .background(Circle().fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta > 0 ? "Add a minute" : "Remove a minute")
    }
}

// MARK: - Reordering

/// Drag one preset onto another to move it there. MacNotch reorders its presets
/// the same way; a list this short doesn't warrant an edit mode.
private struct PresetDropDelegate: DropDelegate {

    let target: PomodoroService.Preset
    let service: PomodoroService

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let draggedID = object as? String else { return }
            Task { @MainActor in
                guard let from = service.presets.firstIndex(where: { $0.id == draggedID }),
                      let to   = service.presets.firstIndex(where: { $0.id == target.id }),
                      from != to
                else { return }
                service.movePreset(from: IndexSet(integer: from),
                                   to: to > from ? to + 1 : to)
            }
        }
        return true
    }
}
