import Foundation
import AppKit

// A single step in a Computer Use session — used to drive the step log UI.
struct CUAStep: Identifiable {
    let id        = UUID()
    let action:   String
    let details:  String
    var screenshot: NSImage? = nil
}

// Drives a multi-turn Claude computer_20251124 session.
// Sends the full conversation to /v1/messages, executes every tool_use block
// via ComputerUseService, then loops until Claude returns end_turn.
@MainActor
final class ComputerUseOrchestrator: ObservableObject {
    static let shared = ComputerUseOrchestrator()
    private init() {}

    @Published private(set) var isRunning        = false
    @Published private(set) var steps: [CUAStep] = []
    @Published private(set) var result:  String  = ""
    @Published private(set) var latestScreenshot: NSImage?

    private var stopRequested = false
    private let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!

    // MARK: - Public

    func run(task: String, apiKey: String) async {
        isRunning     = true
        stopRequested = false
        steps         = []
        result        = ""
        latestScreenshot = nil

        let cua = ComputerUseService.shared
        let w   = cua.displayWidth
        let h   = cua.displayHeight

        let systemPrompt = """
            You are controlling a macOS computer. Display size: \(w)×\(h) points (top-left origin).
            Use the computer tool to accomplish the task. Always take a screenshot first to understand the current state.
            Common macOS shortcuts: cmd+c (copy), cmd+v (paste), cmd+z (undo), cmd+a (select all), cmd+tab (app switcher).
            The "super" key is the macOS Command (⌘) key.
            """

        var messages: [[String: Any]] = [
            ["role": "user", "content": [["type": "text", "text": task]]]
        ]

        var safetyLimit = 40   // max iterations to prevent runaway loops
        while !stopRequested, safetyLimit > 0 {
            safetyLimit -= 1
            guard let response = await sendRequest(messages: messages, apiKey: apiKey, system: systemPrompt, width: w, height: h) else {
                result = "API request failed."
                break
            }

            let content    = response["content"]    as? [[String: Any]] ?? []
            let stopReason = response["stop_reason"] as? String         ?? "end_turn"

            let turnText = content.compactMap { ($0["type"] as? String == "text") ? $0["text"] as? String : nil }.joined()

            messages.append(["role": "assistant", "content": content])

            let toolUses = content.filter { $0["type"] as? String == "tool_use" }

            if toolUses.isEmpty || stopReason == "end_turn" {
                result = turnText
                break
            }

            var toolResults: [[String: Any]] = []
            for tool in toolUses {
                let toolID = tool["id"]    as? String       ?? ""
                let input  = tool["input"] as? [String: Any] ?? [:]
                let action = input["action"] as? String      ?? ""

                let (resultContent, step) = await executeAction(action: action, input: input)
                toolResults.append([
                    "type":        "tool_result",
                    "tool_use_id": toolID,
                    "content":     resultContent
                ])
                steps.append(step)
                if let ss = step.screenshot { latestScreenshot = ss }
            }

            messages.append(["role": "user", "content": toolResults])
        }

        isRunning = false
    }

    func stop() { stopRequested = true }

    // Analyze a single captured screenshot region (Handoff mode — no action loop).
    func analyzeHandoff(image: NSImage, prompt: String, apiKey: String) async {
        isRunning = true
        stopRequested = false
        steps = []
        result = ""
        latestScreenshot = image

        guard let b64 = image.pngBase64() else {
            result = "Failed to encode screenshot."
            isRunning = false
            return
        }

        let messages: [[String: Any]] = [[
            "role": "user",
            "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": b64]],
                ["type": "text", "text": prompt]
            ]
        ]]

        let body: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "max_tokens": 1024,
            "system": "You are Mira, a helpful AI assistant. The user has selected a region of their screen. Analyze it concisely and helpfully.",
            "messages": messages
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body),
              var req = Optional(URLRequest(url: apiURL)) else {
            result = "Request encoding failed."
            isRunning = false
            return
        }
        req.httpMethod = "POST"
        req.setValue(apiKey,           forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",     forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = data
        req.timeoutInterval = 60

        if let (respData, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
           let content = json["content"] as? [[String: Any]] {
            result = content.compactMap { ($0["type"] as? String == "text") ? $0["text"] as? String : nil }.joined()
        } else {
            result = "Analysis failed."
        }

        steps.append(CUAStep(action: "handoff", details: "Region analyzed", screenshot: image))
        isRunning = false
    }

    // MARK: - Action dispatcher

    private func executeAction(action: String, input: [String: Any]) async -> ([[String: Any]], CUAStep) {
        let cua = ComputerUseService.shared

        switch action {

        case "screenshot":
            if let data = await cua.screenshot() {
                let b64  = data.base64EncodedString()
                let content: [[String: Any]] = [[
                    "type":   "image",
                    "source": ["type": "base64", "media_type": "image/png", "data": b64]
                ]]
                return (content, CUAStep(action: action, details: "Screenshot captured", screenshot: NSImage(data: data)))
            }
            return ([ok], CUAStep(action: action, details: "Screenshot failed"))

        case "left_click", "right_click", "middle_click":
            let coord = input["coordinate"] as? [Int] ?? [0, 0]
            let x = coord.count > 0 ? coord[0] : 0
            let y = coord.count > 1 ? coord[1] : 0
            let btn = action == "right_click" ? "right" : action == "middle_click" ? "middle" : "left"
            cua.click(x: x, y: y, button: btn)
            return ([ok], CUAStep(action: action, details: "\(action.replacingOccurrences(of: "_", with: " ").capitalized) at (\(x), \(y))"))

        case "double_click":
            let coord = input["coordinate"] as? [Int] ?? [0, 0]
            cua.doubleClick(x: coord.count > 0 ? coord[0] : 0, y: coord.count > 1 ? coord[1] : 0)
            return ([ok], CUAStep(action: action, details: "Double-click at (\(coord[0]), \(coord[1]))"))

        case "triple_click":
            let coord = input["coordinate"] as? [Int] ?? [0, 0]
            cua.tripleClick(x: coord.count > 0 ? coord[0] : 0, y: coord.count > 1 ? coord[1] : 0)
            return ([ok], CUAStep(action: action, details: "Triple-click at (\(coord[0]), \(coord[1]))"))

        case "left_click_drag":
            let s = input["start_coordinate"] as? [Int] ?? [0, 0]
            let e = input["coordinate"]       as? [Int] ?? [0, 0]
            cua.drag(fromX: s[0], fromY: s[1], toX: e[0], toY: e[1])
            return ([ok], CUAStep(action: action, details: "Drag (\(s[0]),\(s[1])) → (\(e[0]),\(e[1]))"))

        case "mouse_move":
            let coord = input["coordinate"] as? [Int] ?? [0, 0]
            cua.moveMouse(x: coord.count > 0 ? coord[0] : 0, y: coord.count > 1 ? coord[1] : 0)
            return ([ok], CUAStep(action: action, details: "Move to (\(coord[0]), \(coord[1]))"))

        case "type":
            let text = input["text"] as? String ?? ""
            cua.type(text: text)
            let preview = text.count > 50 ? String(text.prefix(50)) + "…" : text
            return ([ok], CUAStep(action: action, details: "Type: \"\(preview)\""))

        case "key":
            let combo = input["text"] as? String ?? ""
            cua.key(combination: combo)
            return ([ok], CUAStep(action: action, details: "Key: \(combo)"))

        case "scroll":
            let coord     = input["coordinate"] as? [Int]    ?? [0, 0]
            let direction = input["direction"]  as? String   ?? "down"
            let amount    = input["amount"]     as? Int      ?? 3
            cua.scroll(x: coord.count > 0 ? coord[0] : 0, y: coord.count > 1 ? coord[1] : 0,
                       direction: direction, amount: amount)
            return ([ok], CUAStep(action: action, details: "Scroll \(direction) ×\(amount) at (\(coord[0]), \(coord[1]))"))

        case "cursor_position":
            let pos = cua.cursorPosition()
            return ([["type": "text", "text": "{\"x\":\(pos.x),\"y\":\(pos.y)}"]],
                    CUAStep(action: action, details: "Cursor at (\(pos.x), \(pos.y))"))

        case "wait":
            let duration = (input["duration"] as? Double) ?? 2.0
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            return ([ok], CUAStep(action: action, details: "Waited \(String(format: "%.1f", duration))s"))

        default:
            return ([["type": "text", "text": "Unknown action: \(action)"]],
                    CUAStep(action: action, details: "Unknown: \(action)"))
        }
    }

    private var ok: [String: Any] { ["type": "text", "text": "OK"] }

    // MARK: - API

    private func sendRequest(
        messages: [[String: Any]],
        apiKey: String,
        system: String,
        width: Int,
        height: Int
    ) async -> [String: Any]? {
        let body: [String: Any] = [
            "model":      "claude-sonnet-4-6",
            "max_tokens": 4096,
            "system":     system,
            // claude-sonnet-4-6 only supports computer_20251124 — older tool
            // versions (20241022/20250124) are rejected with invalid_request_error.
            "tools": [[
                "type":              "computer_20251124",
                "name":              "computer",
                "display_width_px":  width,
                "display_height_px": height
            ]],
            "messages": messages
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: apiURL)
        req.httpMethod  = "POST"
        req.timeoutInterval = 180
        req.setValue(apiKey,                    forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",              forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json",        forHTTPHeaderField: "content-type")
        req.setValue("computer-use-2025-11-24", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = data

        guard let (respData, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            return nil
        }
        return json
    }
}
