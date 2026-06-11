// ExternalTriggerRunner.swift
// Phase 17 — Routes fired external triggers to ProjectEngine sessions + Claude prompts.
// Call rebuildWatchers() any time the trigger list changes.

import Foundation

@MainActor
final class ExternalTriggerRunner {
    static let shared = ExternalTriggerRunner()
    private init() {}

    // MARK: - Fire

    func fire(triggerId: UUID, summary: String) {
        guard let trigger = TriggerStore.shared.triggers.first(where: { $0.id == triggerId }),
              trigger.enabled else { return }

        TriggerStore.shared.recordFired(id: triggerId, summary: summary)

        if let projectId = trigger.projectId,
           ProjectEngine.shared.project(id: projectId) != nil {
            ProjectEngine.shared.startSession(projectId: projectId,
                                              persona: .developer,
                                              trigger: .externalHook)
        }

        if let prompt = trigger.prompt, !prompt.isEmpty {
            let apiKey = MiraState.shared?.effectiveAPIKey ?? AppSecrets.anthropicAPIKey
            guard !apiKey.isEmpty else { postFired(trigger: trigger, summary: summary, result: nil); return }
            Task {
                let claude = ClaudeService(apiKey: apiKey)
                let result = try? await claude.ask(prompt: prompt)
                await MainActor.run {
                    postFired(trigger: trigger, summary: summary, result: result)
                }
            }
        } else {
            postFired(trigger: trigger, summary: summary, result: nil)
        }
    }

    private func postFired(trigger: ExternalTrigger, summary: String, result: String?) {
        var info: [String: Any] = ["name": trigger.name, "summary": summary]
        if let result { info["result"] = result }
        NotificationCenter.default.post(name: .miraTriggerFired, object: nil, userInfo: info)
    }

    // MARK: - Watcher rebuild

    func rebuildWatchers() {
        let triggers = TriggerStore.shared.triggers

        FileWatchService.shared.rebuild(triggers: triggers)

        let needsServer = triggers.contains { t in
            t.enabled && {
                switch t.kind { case .webhook, .githubPush: return true; default: return false }
            }()
        }
        if needsServer {
            WebhookServer.shared.start()
        } else {
            WebhookServer.shared.stop()
        }
    }
}

extension Notification.Name {
    static let miraTriggerFired = Notification.Name("miraTriggerFired")
}
