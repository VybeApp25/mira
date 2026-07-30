// SystemModule.swift
// Second NotchModule conformer — and the one that proves the shell contract
// generalizes, since Weather alone couldn't show whether the chrome was really
// module-agnostic or just shaped around weather.
//
// Maps MacNotch's "System Analytics: live CPU, RAM, storage with visual ring
// indicators". SystemStatsService already samples all three and is reference
// counted, so didAppear/didDisappear map straight onto subscribe/unsubscribe —
// the sampling timer stops the moment you swipe to another module.

import SwiftUI
import Combine

@MainActor
final class SystemModule: NotchModule, ObservableObject {

    let id    = "system"
    let title = "System"
    let icon  = "cpu.fill"

    /// Three rings and their captions sit comfortably in the short panel.
    let heightLevel: NotchHeightLevel = .compact
    let allowsTallMode = false

    private let stats = SystemStatsService.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        stats.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Reference-counted upstream, so this is safe to pair strictly.
    func didAppear()    { stats.subscribe() }
    func didDisappear() { stats.unsubscribe() }

    func makeContent() -> AnyView { AnyView(SystemModuleView(stats: stats)) }
}

// MARK: - View

private struct SystemModuleView: View {

    @ObservedObject var stats: SystemStatsService

    var body: some View {
        HStack(spacing: 0) {
            ring(label: "CPU",
                 pct: stats.cpuPercent,
                 caption: String(format: "%.0f%%", stats.cpuPercent))
            ring(label: "Memory",
                 pct: stats.memPercent,
                 caption: String(format: "%.1f / %.0f GB", stats.memUsedGB, stats.memTotalGB))
            ring(label: "Storage",
                 pct: stats.diskPercent,
                 caption: String(format: "%.0f / %.0f GB", stats.diskUsedGB, stats.diskTotalGB))
        }
        .padding(.top, NotchModuleShellView.headerHeight + 6)
        .padding(.bottom, 10)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color(red: 0.09, green: 0.10, blue: 0.13),
                                    Color(red: 0.04, green: 0.05, blue: 0.07)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private func ring(label: String, pct: Double, caption: String) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.09), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, pct / 100)))
                    .stroke(color(for: pct),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.45), value: pct)
                Text("\(Int(pct.rounded()))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))
            }
            .frame(width: 52, height: 52)

            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.70))
            Text(caption)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.40))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(Int(pct.rounded())) percent, \(caption)")
    }

    /// Green under load, amber approaching full, red at the point it's a problem.
    private func color(for pct: Double) -> Color {
        switch pct {
        case ..<60:  return Color(red: 0.30, green: 0.82, blue: 0.60)
        case ..<85:  return Color(red: 0.98, green: 0.75, blue: 0.30)
        default:     return Color(red: 0.98, green: 0.42, blue: 0.42)
        }
    }
}
