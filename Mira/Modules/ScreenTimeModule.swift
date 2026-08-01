// ScreenTimeModule.swift
// MacNotch's Screen Time: category charts, ranked apps and app-switch counts,
// with usage following the frontmost app and staying on the Mac. The audit
// scored this ❌ — no frontmost-app usage tracking existed anywhere in Mira.
//
// This is the first module that must run from LAUNCH to be worth anything.
// Weather can fetch on demand and Bluetooth can poll when asked, but usage
// cannot be backfilled: a minute not recorded is gone. So the tracker starts in
// AppDelegate, not in didAppear.
//
// Its own observer rather than reusing AppContextService's: that service is
// about the CURRENT app for prompt context and doesn't retain durations, and
// bolting accumulation onto it would entangle a privacy-sensitive on-disk
// record with AI prompt plumbing. Keeping them apart means this data has one
// writer and one file.
//
// Stays on the Mac. Nothing here is uploaded, and it deliberately records bundle
// identifiers and durations only — never window titles or document names, which
// is where app usage stops being a statistic and becomes a diary.

import SwiftUI
import AppKit
import Combine

// MARK: - Categories

enum AppCategory: String, Codable, CaseIterable {
    case work, creative, social, entertainment, developer, other

    var label: String {
        switch self {
        case .work:          return "Work"
        case .creative:      return "Creative"
        case .social:        return "Social"
        case .entertainment: return "Entertainment"
        case .developer:     return "Developer"
        case .other:         return "Other"
        }
    }

    var color: Color {
        switch self {
        case .work:          return Color(red: 0.35, green: 0.65, blue: 1.00)
        case .creative:      return Color(red: 0.95, green: 0.55, blue: 0.35)
        case .social:        return Color(red: 0.98, green: 0.45, blue: 0.60)
        case .entertainment: return Color(red: 0.70, green: 0.50, blue: 0.98)
        case .developer:     return Color(red: 0.35, green: 0.82, blue: 0.62)
        case .other:         return Color(red: 0.55, green: 0.58, blue: 0.62)
        }
    }

    /// Bundle-id substring matching. Deliberately coarse — a wrong bucket is a
    /// cosmetic problem, and an ever-growing hardcoded catalogue would be worse.
    static func of(_ bundleID: String) -> AppCategory {
        let id = bundleID.lowercased()
        switch true {
        case id.contains("xcode"), id.contains("terminal"), id.contains("iterm"),
             id.contains("vscode"), id.contains("code"), id.contains("jetbrains"),
             id.contains("github"), id.contains("docker"), id.contains("simulator"):
            return .developer
        case id.contains("slack"), id.contains("discord"), id.contains("messages"),
             id.contains("mail"), id.contains("zoom"), id.contains("teams"),
             id.contains("whatsapp"), id.contains("telegram"):
            return .social
        case id.contains("music"), id.contains("spotify"), id.contains("tv"),
             id.contains("netflix"), id.contains("youtube"), id.contains("vlc"),
             id.contains("podcasts"):
            return .entertainment
        case id.contains("figma"), id.contains("sketch"), id.contains("photoshop"),
             id.contains("illustrator"), id.contains("final"), id.contains("logic"),
             id.contains("blender"), id.contains("pixelmator"):
            return .creative
        case id.contains("safari"), id.contains("chrome"), id.contains("arc"),
             id.contains("firefox"), id.contains("notion"), id.contains("pages"),
             id.contains("numbers"), id.contains("keynote"), id.contains("notes"),
             id.contains("calendar"), id.contains("finder"):
            return .work
        default:
            return .other
        }
    }
}

// MARK: - Model

struct AppUsage: Codable, Identifiable {
    let bundleID: String
    var name: String
    var seconds: TimeInterval
    var switches: Int

    var id: String { bundleID }
    var category: AppCategory { AppCategory.of(bundleID) }
}

// MARK: - Service

@MainActor
final class ScreenTimeService: ObservableObject {

    static let shared = ScreenTimeService()

    /// Today's usage, keyed by bundle id.
    @Published private(set) var today: [String: AppUsage] = [:]

    private var currentBundle: String?
    private var currentName: String?
    private var segmentStart: Date?
    private var dayKey: String = ""
    private var saveWork: DispatchWorkItem?

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("screen_time.json")
    }()

    private init() {}

    // MARK: Lifecycle

    func start() {
        dayKey = Self.todayKey()
        load()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // Sleep and wake bracket the segment: without this, closing the lid at
        // 6pm and opening it at 9am books fifteen hours to whatever was frontmost.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        begin(NSWorkspace.shared.frontmostApplication)
    }

    @objc private func appDidActivate(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        Task { @MainActor in
            self.commitSegment()
            self.begin(app, countSwitch: true)
        }
    }

    @objc private func willSleep() { Task { @MainActor in commitSegment() } }
    @objc private func didWake()   { Task { @MainActor in begin(NSWorkspace.shared.frontmostApplication) } }

    // MARK: Accumulation

    private func begin(_ app: NSRunningApplication?, countSwitch: Bool = false) {
        guard let id = app?.bundleIdentifier else {
            currentBundle = nil; segmentStart = nil; return
        }
        currentBundle = id
        currentName = app?.localizedName ?? id
        segmentStart = Date()

        if countSwitch {
            var entry = today[id] ?? AppUsage(bundleID: id, name: currentName ?? id,
                                              seconds: 0, switches: 0)
            entry.switches += 1
            today[id] = entry
            scheduleSave()
        }
    }

    /// Books the time since the segment began onto the current app.
    private func commitSegment() {
        rolloverIfNeeded()
        guard let id = currentBundle, let start = segmentStart else { return }
        let elapsed = Date().timeIntervalSince(start)
        segmentStart = Date()
        // Ignore sub-second flickers — alt-tabbing through five apps shouldn't
        // register as five sessions of usage.
        guard elapsed >= 1 else { return }

        var entry = today[id] ?? AppUsage(bundleID: id, name: currentName ?? id,
                                          seconds: 0, switches: 0)
        entry.seconds += elapsed
        today[id] = entry
        scheduleSave()
    }

    /// Called by the view so the frontmost app's running total is live rather
    /// than only updating when you switch away from it.
    func tick() { commitSegment() }

    private func rolloverIfNeeded() {
        let key = Self.todayKey()
        guard key != dayKey else { return }
        dayKey = key
        today = [:]
        save()
    }

    // MARK: Derived

    var totalSeconds: TimeInterval { today.values.reduce(0) { $0 + $1.seconds } }
    var totalSwitches: Int { today.values.reduce(0) { $0 + $1.switches } }

    var ranked: [AppUsage] {
        today.values.sorted { $0.seconds > $1.seconds }
    }

    var byCategory: [(AppCategory, TimeInterval)] {
        var out: [AppCategory: TimeInterval] = [:]
        for usage in today.values { out[usage.category, default: 0] += usage.seconds }
        return out.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    // MARK: Persistence

    private struct Stored: Codable { let day: String; let apps: [String: AppUsage] }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func save() {
        let stored = Stored(day: dayKey, apps: today)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        // Only restore if it's still the same day — yesterday's totals shown as
        // today's would be worse than showing nothing.
        if stored.day == dayKey { today = stored.apps }
    }

    private static func todayKey() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

// MARK: - Module

@MainActor
final class ScreenTimeModule: NotchModule, ObservableObject {

    let id    = "screentime"
    let title = "Screen Time"
    let icon  = "hourglass"

    let heightLevel: NotchHeightLevel = .tall
    let allowsTallMode = false

    private let service = ScreenTimeService.shared
    private var cancellables = Set<AnyCancellable>()

    var subtitle: NotchHeaderSubtitle? {
        NotchHeaderSubtitle(text: ScreenTimeModule.duration(service.totalSeconds))
    }

    init() {
        service.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func didAppear() { service.tick() }

    static func duration(_ s: TimeInterval) -> String {
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

    func makeContent() -> AnyView { AnyView(ScreenTimeModuleView(service: service)) }
}

// MARK: - View

private struct ScreenTimeModuleView: View {

    @ObservedObject var service: ScreenTimeService

    var body: some View {
        // Recompute the live segment so the frontmost app's total climbs while
        // you're looking at it.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            HStack(spacing: 0) {
                donutSide.frame(width: 210)
                Rectangle().fill(Color.white.opacity(0.07)).frame(width: 0.5)
                rankedSide.frame(maxWidth: .infinity)
            }
            .onAppear { service.tick() }
        }
        .padding(.top, NotchModuleShellView.headerHeight)
        .background(Color.black)
    }

    // MARK: Left: donut + totals

    private var donutSide: some View {
        VStack(spacing: 8) {
            ZStack {
                ForEach(Array(donutSegments.enumerated()), id: \.offset) { _, seg in
                    Circle()
                        .trim(from: seg.start, to: seg.end)
                        .stroke(seg.color, style: StrokeStyle(lineWidth: 11, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                if service.totalSeconds == 0 {
                    Circle().stroke(Color.white.opacity(0.08), lineWidth: 11)
                }
                VStack(spacing: 0) {
                    Text(ScreenTimeModule.duration(service.totalSeconds))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.92))
                    Text("today")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.40))
                }
            }
            .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(service.byCategory.prefix(4), id: \.0) { cat, secs in
                    HStack(spacing: 5) {
                        Circle().fill(cat.color).frame(width: 6, height: 6)
                        Text(cat.label)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.70))
                        Spacer(minLength: 6)
                        Text(ScreenTimeModule.duration(secs))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.50))
                    }
                }
            }
            .padding(.horizontal, 16)

            Text("\(service.totalSwitches) app switches")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.32))

            Spacer(minLength: 0)
        }
        .padding(.top, 10)
    }

    private struct Segment { let start: CGFloat; let end: CGFloat; let color: Color }

    private var donutSegments: [Segment] {
        let total = service.totalSeconds
        guard total > 0 else { return [] }
        var out: [Segment] = []
        var cursor: CGFloat = 0
        for (cat, secs) in service.byCategory {
            let frac = CGFloat(secs / total)
            out.append(Segment(start: cursor, end: cursor + frac, color: cat.color))
            cursor += frac
        }
        return out
    }

    // MARK: Right: ranked apps

    private var rankedSide: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(service.ranked) { usage in
                    row(usage)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .overlay {
            if service.ranked.isEmpty {
                VStack(spacing: 4) {
                    Text("No usage recorded yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.50))
                    Text("Tracking starts when Mira launches.")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.32))
                }
            }
        }
    }

    private func row(_ usage: AppUsage) -> some View {
        let frac = service.totalSeconds > 0 ? usage.seconds / service.totalSeconds : 0
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(usage.category.color)
                .frame(width: 3, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(usage.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.90))
                    .lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(usage.category.color.opacity(0.75))
                            .frame(width: geo.size.width * CGFloat(frac))
                    }
                }
                .frame(height: 3)
            }
            Text(ScreenTimeModule.duration(usage.seconds))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(usage.name), \(ScreenTimeModule.duration(usage.seconds))")
    }
}
