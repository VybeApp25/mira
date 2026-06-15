import SwiftUI

// MARK: - AgentHUDColumnView
// Mirrors HeyClicky's CodexHUDView.hudColumn: a VStack of FloatingAgentChipView
// instances pinned to the bottom-right of the screen panel.
// Running jobs appear at top, terminal jobs (done/failed/cancelled) stack below,
// keeping the most recent 6 terminal jobs visible.

struct AgentHUDColumnView: View {
    @StateObject private var store = AgentJobStore.shared

    private var activeJobs: [AgentJob] {
        store.jobs.filter { !$0.status.isTerminal && !store.hudHidden.contains($0.id) }
    }

    private var recentTerminal: [AgentJob] {
        store.jobs
            .filter { $0.status.isTerminal && !store.hudHidden.contains($0.id) }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                // Running / active jobs (at top of the stack)
                ForEach(activeJobs) { job in
                    FloatingAgentChipView(job: job)
                        .id(job.id)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                // Recent terminal jobs below
                if !recentTerminal.isEmpty {
                    if !activeJobs.isEmpty {
                        // Subtle divider between active and terminal
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 280, height: 0.5)
                            .padding(.vertical, 2)
                    }

                    ForEach(recentTerminal) { job in
                        FloatingAgentChipView(job: job)
                            .id(job.id)
                            .opacity(0.85)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .padding(.bottom, 28)
            .padding(.trailing, 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.84), value: activeJobs.map(\.id))
            .animation(.spring(response: 0.32, dampingFraction: 0.84), value: recentTerminal.map(\.id))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 4)
    }
}
