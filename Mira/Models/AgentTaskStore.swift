import Foundation
import Combine

struct AgentTask: Identifiable, Codable {
    let id: UUID
    let prompt: String
    let reply: String
    let toolsUsed: [String]
    let createdAt: Date
    var isCompleted: Bool

    var toolIcon: String {
        if toolsUsed.contains(where: { $0.contains("GMAIL") }) { return "envelope.fill" }
        if toolsUsed.contains(where: { $0.contains("CALENDAR") }) { return "calendar" }
        if toolsUsed.contains(where: { $0.contains("NOTION") }) { return "doc.text.fill" }
        if toolsUsed.contains(where: { $0.contains("SLACK") }) { return "message.fill" }
        return "cpu"
    }

    var relativeTime: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff/60))m ago" }
        if diff < 86400 { return "\(Int(diff/3600))h ago" }
        return "\(Int(diff/86400))d ago"
    }
}

class AgentTaskStore: ObservableObject {
    static let shared = AgentTaskStore()

    @Published var tasks: [AgentTask] = []

    private let key = "mira_agent_tasks"

    init() { load() }

    func add(prompt: String, reply: String, toolsUsed: [String], completed: Bool = true) {
        let task = AgentTask(
            id: UUID(),
            prompt: prompt,
            reply: reply,
            toolsUsed: toolsUsed,
            createdAt: Date(),
            isCompleted: completed
        )
        tasks.insert(task, at: 0)
        if tasks.count > 50 { tasks = Array(tasks.prefix(50)) }
        save()
    }

    func clear() {
        tasks = []
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([AgentTask].self, from: data) else { return }
        tasks = decoded
    }
}
