import SwiftUI
import Darwin

// MARK: - SystemStatsService
//
// Utility #1 of the "5 Mac apps" set: a system monitor, surfaced as a Dock widget.
// Samples CPU / memory / disk via mach + URLResourceValues. Plan-gated in the UI:
// Free = locked, Pro = CPU + RAM, Ultra = + Disk.

@MainActor
final class SystemStatsService: ObservableObject {
    static let shared = SystemStatsService()
    private init() {}

    @Published var cpuPercent:  Double = 0
    @Published var memPercent:  Double = 0
    @Published var memUsedGB:   Double = 0
    @Published var memTotalGB:  Double = 0
    @Published var diskPercent: Double = 0
    @Published var diskUsedGB:  Double = 0
    @Published var diskTotalGB: Double = 0

    private var timer: Timer?
    private var prevTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var subscribers = 0

    /// Reference-counted so the timer only runs while a stats widget is visible.
    func subscribe() {
        subscribers += 1
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func unsubscribe() {
        subscribers = max(0, subscribers - 1)
        if subscribers == 0 { timer?.invalidate(); timer = nil }
    }

    private func sample() {
        cpuPercent = currentCPU()
        let m = currentMemory(); memPercent = m.percent; memUsedGB = m.used; memTotalGB = m.total
        let d = currentDisk();   diskPercent = d.percent; diskUsedGB = d.used; diskTotalGB = d.total
    }

    private func currentCPU() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return cpuPercent }
        let user = info.cpu_ticks.0, system = info.cpu_ticks.1, idle = info.cpu_ticks.2, nice = info.cpu_ticks.3
        defer { prevTicks = (user, system, idle, nice) }
        guard let p = prevTicks else { return 0 }
        let dUser = Double(user &- p.user), dSys = Double(system &- p.system)
        let dIdle = Double(idle &- p.idle), dNice = Double(nice &- p.nice)
        let total = dUser + dSys + dIdle + dNice
        guard total > 0 else { return cpuPercent }
        return (dUser + dSys + dNice) / total * 100
    }

    private func currentMemory() -> (percent: Double, used: Double, total: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard kr == KERN_SUCCESS, total > 0 else { return (memPercent, memUsedGB, memTotalGB) }
        let page = Double(vm_kernel_page_size)
        let used = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        let gb = 1024.0 * 1024 * 1024
        return (used / total * 100, used / gb, total / gb)
    }

    private func currentDisk() -> (percent: Double, used: Double, total: Double) {
        let url = URL(fileURLWithPath: "/")
        guard let vals = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = vals.volumeTotalCapacity, total > 0 else {
            return (diskPercent, diskUsedGB, diskTotalGB)
        }
        let available = Double(vals.volumeAvailableCapacityForImportantUsage ?? 0)
        let totalD = Double(total)
        let used = max(0, totalD - available)
        let gb = 1000.0 * 1000 * 1000   // disks are advertised in decimal GB
        return (used / totalD * 100, used / gb, totalD / gb)
    }
}

// MARK: - Dock widget (compact)

struct SystemStatsWidget: View {
    @ObservedObject private var stats = SystemStatsService.shared
    @ObservedObject private var ent   = EntitlementService.shared

    var body: some View {
        Group {
            if ent.plan == .free {
                VStack(spacing: 3) {
                    Image(systemName: "lock.fill").font(.system(size: 12)).foregroundColor(.yellow)
                    Text("System").font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.7))
                }
            } else {
                VStack(spacing: 3) {
                    miniRow("CPU", stats.cpuPercent)
                    miniRow("RAM", stats.memPercent)
                }
                .onAppear { stats.subscribe() }
                .onDisappear { stats.unsubscribe() }
            }
        }
        .frame(width: 60)
    }

    private func miniRow(_ label: String, _ pct: Double) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 8, weight: .semibold)).foregroundColor(.white.opacity(0.55))
            Spacer(minLength: 0)
            Text("\(Int(pct))%").font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(color(for: pct))
        }
    }

    private func color(for pct: Double) -> Color {
        pct > 85 ? .red : pct > 60 ? .orange : .green
    }
}

// MARK: - Detail popover (full)

struct SystemStatsDetailPanel: View {
    @ObservedObject private var stats = SystemStatsService.shared
    @ObservedObject private var ent   = EntitlementService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System").font(.system(size: 15, weight: .bold)).foregroundColor(.white)

            bar("CPU", stats.cpuPercent, "\(Int(stats.cpuPercent))%")
            bar("Memory", stats.memPercent, String(format: "%.1f / %.0f GB", stats.memUsedGB, stats.memTotalGB))

            if ent.plan == .ultra {
                bar("Disk", stats.diskPercent, String(format: "%.0f / %.0f GB", stats.diskUsedGB, stats.diskTotalGB))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                    Text("Disk, GPU & network — Ultra").font(.system(size: 11))
                }
                .foregroundColor(.white.opacity(0.4))
            }
        }
        .frame(width: 240)
        .onAppear { stats.subscribe() }
        .onDisappear { stats.unsubscribe() }
    }

    private func bar(_ label: String, _ pct: Double, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.85))
                Spacer()
                Text(detail).font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.55))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(pct > 85 ? Color.red : pct > 60 ? .orange : .green)
                        .frame(width: max(4, geo.size.width * pct / 100))
                }
            }
            .frame(height: 6)
        }
    }
}
