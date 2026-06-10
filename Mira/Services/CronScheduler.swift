import Foundation

// Fires due crons by injecting their prompts into the chat pipeline.
// Checks every 60 seconds; uses the same Claude API key path as BackgroundScheduler.
@MainActor
final class CronScheduler {
    static let shared = CronScheduler()
    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let due = CronStore.shared.dueCrons
        guard !due.isEmpty else { return }

        let apiKey = MiraState.shared?.effectiveAPIKey ?? AppSecrets.anthropicAPIKey
        guard !apiKey.isEmpty else { return }

        for cron in due {
            Task {
                await run(cron: cron, apiKey: apiKey)
            }
        }
    }

    private func run(cron: MiraCron, apiKey: String) async {
        let claude = ClaudeService(apiKey: apiKey)
        do {
            let result = try await claude.ask(prompt: cron.prompt)
            CronStore.shared.recordRun(id: cron.id, result: result)
            PostHogService.shared.capture("cron_fired", properties: [
                "cron_name": cron.name,
                "schedule":  cron.schedule.displayName
            ])
            // Surface result as a notification
            NotificationCenter.default.post(
                name: .miraCronResult,
                object: nil,
                userInfo: ["name": cron.name, "result": result]
            )
        } catch {
            CronStore.shared.recordRun(id: cron.id, result: "Error: \(error.localizedDescription)")
        }
    }
}

extension Notification.Name {
    static let miraCronResult = Notification.Name("miraCronResult")
}

// MiraState singleton access for CronScheduler (avoids injection)
extension MiraState {
    static weak var shared: MiraState?
}
