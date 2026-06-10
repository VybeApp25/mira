import SwiftUI

private let cardBG  = Color(red: 0.11, green: 0.11, blue: 0.14)
private let accent  = Color(red: 0.29, green: 0.62, blue: 1.0)
private let accentG = Color(red: 0.20, green: 0.84, blue: 0.29)

struct CronsTabView: View {
    @ObservedObject private var store = CronStore.shared
    @State private var showingCreate  = false
    @State private var editingCron:    MiraCron? = nil

    var body: some View {
        VStack(spacing: 0) {
            header

            if store.crons.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(store.crons) { cron in
                            CronRow(cron: cron, onEdit: { editingCron = cron })
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
        }
        .sheet(isPresented: $showingCreate) {
            CronEditorView()
        }
        .sheet(item: $editingCron) { cron in
            CronEditorView(existing: cron)
        }
    }

    private var header: some View {
        HStack {
            Text("Scheduled Tasks")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
            Spacer()
            Button { showingCreate = true } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "clock.arrow.2.circlepath")
                .font(.system(size: 32))
                .foregroundColor(.white.opacity(0.15))
            Text("No scheduled tasks")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.35))
            Text("Tap + to schedule a recurring Mira task")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.20))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Row

private struct CronRow: View {
    let cron: MiraCron
    let onEdit: () -> Void

    @ObservedObject private var store = CronStore.shared

    var body: some View {
        HStack(spacing: 10) {
            // Status dot
            Circle()
                .fill(cron.enabled ? accentG : Color.white.opacity(0.2))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(cron.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(cron.enabled ? .white.opacity(0.9) : .white.opacity(0.4))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(cron.schedule.displayName)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))

                    if let last = cron.lastRunAt {
                        Text("· last \(last.relativeShort)")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.25))
                    }
                }
            }

            Spacer()

            // Next fire countdown
            VStack(alignment: .trailing, spacing: 2) {
                Text(cron.nextFireAt.relativeShort)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.30))
            }

            // Actions
            HStack(spacing: 4) {
                Button { onEdit() } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.25))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { store.toggle(id: cron.id) } label: {
                    Image(systemName: cron.enabled ? "pause.fill" : "play.fill")
                        .font(.system(size: 10))
                        .foregroundColor(cron.enabled ? .white.opacity(0.35) : accentG.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { store.delete(id: cron.id) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.4))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Show last result as tooltip on hover
        .help(cron.lastRunResult ?? "No result yet")
    }
}

// MARK: - Editor

struct CronEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CronStore.shared

    var existing: MiraCron? = nil

    @State private var name     = ""
    @State private var prompt   = ""
    @State private var scheduleType = ScheduleType.daily
    @State private var hour     = 9
    @State private var minute   = 0
    @State private var weekday  = 2  // Mon
    @State private var interval = 30 // minutes for custom

    enum ScheduleType: String, CaseIterable {
        case hourly, daily, weekly, custom = "custom (minutes)"
    }

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.12).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text(existing == nil ? "New Scheduled Task" : "Edit Task")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.white.opacity(0.4))
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

                Divider().background(Color.white.opacity(0.08))

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        field("Task name", placeholder: "e.g. Morning briefing", text: $name)
                        promptField
                        scheduleSection

                        Button(existing == nil ? "Add Task" : "Save") {
                            saveAndDismiss()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(canSave ? accent : Color.white.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .disabled(!canSave)
                    }
                    .padding(18)
                }
            }
        }
        .frame(width: 340, height: 460)
        .onAppear { populate() }
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.45))
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prompt").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.45))
            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(height: 80)
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Schedule").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.45))

            Picker("", selection: $scheduleType) {
                ForEach(ScheduleType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .colorMultiply(.white)

            switch scheduleType {
            case .hourly:
                Text("Fires once per hour").font(.system(size: 11)).foregroundColor(.white.opacity(0.35))
            case .daily:
                timePicker
            case .weekly:
                VStack(spacing: 8) {
                    Picker("Day", selection: $weekday) {
                        ForEach(1...7, id: \.self) { d in
                            Text(["Sun","Mon","Tue","Wed","Thu","Fri","Sat"][d-1]).tag(d)
                        }
                    }.pickerStyle(.menu).tint(.white)
                    timePicker
                }
            case .custom:
                HStack {
                    Text("Every").font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
                    TextField("30", value: $interval, formatter: NumberFormatter())
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 50)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("minutes").font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
                }
            }
        }
    }

    private var timePicker: some View {
        HStack(spacing: 8) {
            Stepper("Hour: \(String(format: "%02d", hour))", value: $hour, in: 0...23)
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
            Stepper("Min: \(String(format: "%02d", minute))", value: $minute, in: 0...59)
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
        }
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !prompt.trimmingCharacters(in: .whitespaces).isEmpty }

    private func buildSchedule() -> CronSchedule {
        switch scheduleType {
        case .hourly:  return .hourly
        case .daily:   return .daily(hour: hour, minute: minute)
        case .weekly:  return .weekly(weekday: weekday, hour: hour, minute: minute)
        case .custom:  return .custom(intervalMinutes: max(1, interval))
        }
    }

    private func saveAndDismiss() {
        let trimmedName   = name.trimmingCharacters(in: .whitespaces)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespaces)
        if var cron = existing {
            cron.name     = trimmedName
            cron.prompt   = trimmedPrompt
            cron.schedule = buildSchedule()
            cron.nextFireAt = buildSchedule().nextFire()
            store.update(cron)
        } else {
            store.add(MiraCron(name: trimmedName, prompt: trimmedPrompt, schedule: buildSchedule()))
        }
        dismiss()
    }

    private func populate() {
        guard let c = existing else { return }
        name   = c.name
        prompt = c.prompt
        switch c.schedule {
        case .hourly:               scheduleType = .hourly
        case .daily(let h, let m):  scheduleType = .daily; hour = h; minute = m
        case .weekly(let d, let h, let m): scheduleType = .weekly; weekday = d; hour = h; minute = m
        case .custom(let i):        scheduleType = .custom; interval = i
        }
    }
}

// MARK: - Date helper

private extension Date {
    var relativeShort: String {
        let diff = Date().timeIntervalSince(self)
        if diff < 0 {
            // Future
            let abs = -diff
            if abs < 3600  { return "in \(Int(abs/60))m" }
            if abs < 86400 { return "in \(Int(abs/3600))h" }
            return "in \(Int(abs/86400))d"
        }
        if diff < 60   { return "now" }
        if diff < 3600 { return "\(Int(diff/60))m ago" }
        if diff < 86400 { return "\(Int(diff/3600))h ago" }
        return "\(Int(diff/86400))d ago"
    }
}
