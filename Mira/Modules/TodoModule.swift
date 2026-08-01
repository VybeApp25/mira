// TodoModule.swift
// MacNotch's Todo module: add, complete, delete and restore tasks, staying in
// sync with macOS Reminders. The parity audit scored this ❌ — Mira had zero
// EKReminder usage anywhere.
//
// Reminders IS the store. No parallel task list, no local database to drift out
// of sync: a task completed here is completed in Reminders and on every device.
// That is the whole value proposition, and a local mirror would quietly break it.
//
// Deliberately not built yet: the trash with retention. Reminders' own deletion
// is immediate and there is no undo API, so a faithful trash needs a local
// tombstone layer — which is exactly the parallel state this module avoids.
// Deleting therefore asks nothing and simply removes, matching Reminders itself.

import SwiftUI
import EventKit
import Combine

// MARK: - Service

@MainActor
final class RemindersService: ObservableObject {

    static let shared = RemindersService()

    @Published private(set) var reminders: [EKReminder] = []
    @Published private(set) var permitted = false
    @Published private(set) var checked   = false

    /// Show completed items alongside open ones.
    @Published var showCompleted = false

    private let store = EKEventStore()
    private init() {}

    func requestAccess() {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess, .authorized:
            permitted = true; checked = true; load()
        case .denied, .restricted:
            permitted = false; checked = true
        default:
            store.requestFullAccessToReminders { [weak self] ok, _ in
                DispatchQueue.main.async {
                    self?.permitted = ok
                    self?.checked = true
                    if ok { self?.load() }
                }
            }
        }
    }

    func load() {
        guard permitted else { return }
        let predicate = store.predicateForReminders(in: nil)
        store.fetchReminders(matching: predicate) { [weak self] found in
            let items = (found ?? []).sorted { a, b in
                // Incomplete first, then by due date, then title — a stable order
                // so completing something doesn't reshuffle the list under the cursor.
                if a.isCompleted != b.isCompleted { return !a.isCompleted }
                switch (a.dueDateComponents?.date, b.dueDateComponents?.date) {
                case let (x?, y?): return x < y
                case (_?, nil):    return true
                case (nil, _?):    return false
                default:           return (a.title ?? "") < (b.title ?? "")
                }
            }
            DispatchQueue.main.async { self?.reminders = items }
        }
    }

    func toggle(_ reminder: EKReminder) {
        reminder.isCompleted.toggle()
        save(reminder)
    }

    func add(title: String, to calendar: EKCalendar? = nil) {
        guard permitted, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = calendar ?? store.defaultCalendarForNewReminders()
        save(r)
    }

    func delete(_ reminder: EKReminder) {
        do {
            try store.remove(reminder, commit: true)
            load()
        } catch {
            NSLog("[Mira] reminder delete failed: %@", error.localizedDescription)
        }
    }

    private func save(_ reminder: EKReminder) {
        do {
            try store.save(reminder, commit: true)
            load()
        } catch {
            NSLog("[Mira] reminder save failed: %@", error.localizedDescription)
        }
    }
}

// MARK: - Module

@MainActor
final class TodoModule: NotchModule, ObservableObject {

    let id    = "todo"
    let title = "Todo"
    let icon  = "checklist"

    let heightLevel: NotchHeightLevel = .tall
    let allowsTallMode = false

    private let service = RemindersService.shared
    private var cancellables = Set<AnyCancellable>()

    var subtitle: NotchHeaderSubtitle? {
        let open = service.reminders.filter { !$0.isCompleted }.count
        guard open > 0 else { return nil }
        return NotchHeaderSubtitle(text: "\(open)")
    }

    var headerAccessories: [NotchHeaderAccessory] {
        [
            NotchHeaderAccessory(
                id: "showCompleted",
                systemImage: service.showCompleted ? "eye" : "eye.slash",
                label: service.showCompleted ? "Hide completed" : "Show completed"
            ) { [weak self] in
                self?.service.showCompleted.toggle()
            },
            NotchHeaderAccessory(id: "refresh", systemImage: "arrow.clockwise",
                                 label: "Refresh reminders") { [weak self] in
                self?.service.load()
            }
        ]
    }

    init() {
        service.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func didAppear() { service.requestAccess() }

    func makeContent() -> AnyView { AnyView(TodoModuleView(service: service)) }
}

// MARK: - View

private struct TodoModuleView: View {

    @ObservedObject var service: RemindersService
    @ObservedObject private var accentSvc = AccentColorService.shared
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var accent: Color { accentSvc.color }

    private var visible: [EKReminder] {
        service.showCompleted ? service.reminders
                              : service.reminders.filter { !$0.isCompleted }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !service.permitted && service.checked {
                permissionPrompt
            } else {
                addRow
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                list
            }
        }
        .padding(.top, NotchModuleShellView.headerHeight)
        .background(Color.black)
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.35))
            TextField("Add a reminder", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.92))
                .focused($fieldFocused)
                .onSubmit {
                    service.add(title: draft)
                    draft = ""
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(visible, id: \.calendarItemIdentifier) { reminder in
                    row(reminder)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .overlay {
            if visible.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.22))
                    Text(service.showCompleted ? "Nothing here" : "All clear")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.50))
                }
            }
        }
    }

    private func row(_ reminder: EKReminder) -> some View {
        HStack(spacing: 9) {
            Button {
                service.toggle(reminder)
            } label: {
                Image(systemName: reminder.isCompleted ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundColor(reminder.isCompleted ? accent : .white.opacity(0.35))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reminder.isCompleted ? "Mark incomplete" : "Mark complete")

            VStack(alignment: .leading, spacing: 1) {
                Text(reminder.title ?? "Untitled")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(reminder.isCompleted ? 0.40 : 0.90))
                    .strikethrough(reminder.isCompleted, color: .white.opacity(0.35))
                    .lineLimit(1)
                if let due = reminder.dueDateComponents?.date {
                    Text(due.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9))
                        .foregroundColor(overdue(due) ? Color(red: 1, green: 0.45, blue: 0.45)
                                                      : .white.opacity(0.38))
                }
            }

            Spacer(minLength: 0)

            Button {
                service.delete(reminder)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.28))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete reminder")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func overdue(_ date: Date) -> Bool { date < Date() }

    private var permissionPrompt: some View {
        VStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.30))
            Text("Reminders access needed")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
            Text("Grant access in System Settings › Privacy")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
