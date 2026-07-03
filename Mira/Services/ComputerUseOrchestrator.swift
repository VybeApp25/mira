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
    private var apiURL: URL { MiraBackend.anthropicMessagesURL }

    /// Max Claude tool-use steps per task — the per-task cost ceiling.
    private let perTaskStepCeiling = 40

    // MARK: - Public

    func run(task: String, apiKey: String, drawn: DrawnContext? = nil) async {
        // Server-authoritative monthly quota (QuotaService → Supabase, with a
        // local offline fallback). consume() records the run up front and tells
        // us whether it's allowed; deny → announce, don't silently no-op.
        let decision = await QuotaService.shared.consume(path: "vision")
        guard decision.allowed else {
            result = "Monthly task limit reached."
            TaskAnnouncer.shared.announce(task: task, success: false,
                                          detail: QuotaService.shared.tasksLeftText)
            return
        }
        let ok = await runVisionLoop(task: task, apiKey: apiKey, drawn: drawn)
        if !stopRequested {
            TaskAnnouncer.shared.announce(task: task, success: ok,
                                          detail: result.isEmpty ? nil : result)
        }
    }

    /// Runs the Claude vision control loop WITHOUT consuming quota or announcing —
    /// for the auto engine router (EngineRouter), which owns a single consume +
    /// announce across a possible Codex→Claude failover. Returns whether the task
    /// completed cleanly.
    @discardableResult
    func control(task: String, apiKey: String, drawn: DrawnContext? = nil) async -> Bool {
        await runVisionLoop(task: task, apiKey: apiKey, drawn: drawn)
    }

    /// The Claude computer_use loop. Returns whether it completed cleanly. Does
    /// NOT consume quota or announce — callers (run / control / perform) own that
    /// so a task is metered + announced exactly once regardless of how it routed.
    @discardableResult
    private func runVisionLoop(task: String, apiKey: String, drawn: DrawnContext? = nil) async -> Bool {
        isRunning     = true
        stopRequested = false
        steps         = []
        result        = ""
        latestScreenshot = nil
        var taskSucceeded = false

        // Live bottom-right chip: one per task, updated in place through the
        // perception → reasoning → action phases. See AgentTaskManager.
        let activityID = AgentTaskManager.shared.start(
            title: Self.activityTitle(for: task),
            subtitle: "Reading screen…"
        )
        defer { AgentTaskManager.shared.finish(activityID, success: taskSucceeded, summary: result.isEmpty ? nil : String(result.prefix(60))) }

        let cua = ComputerUseService.shared
        let w   = cua.displayWidth
        let h   = cua.displayHeight
        MiraDebugLog.log("[Orchestrator] vision loop START display=\(w)x\(h) task=\(task.prefix(120))")
        // HeyClicky-style visibility: persistent click-through overlay marks every
        // click so the user SEES the agent working. Orchestrator coords are
        // logical points — don't let the overlay divide by backing scale.
        CodexLiveOverlay.shared.assumePixelsAreNative = false
        CodexLiveOverlay.shared.begin()
        defer {
            CodexLiveOverlay.shared.end()
            CodexLiveOverlay.shared.assumePixelsAreNative = true
        }

        let systemPrompt = """
            You are controlling a macOS computer. Display size: \(w)×\(h) points (top-left origin).
            Use the computer tool to accomplish the task. Take a screenshot first to see the current state.
            After every click, type, key press, scroll, or drag you receive a fresh screenshot showing the result. Study it and verify the action had the intended effect before moving on. If it didn't (nothing happened, wrong element, unexpected state), do not repeat the same action blindly — re-locate the target in the screenshot and adjust.
            Never claim an action succeeded unless the screenshot proves it. Only declare the task complete once the final screenshot visibly shows the goal state; if you cannot get there, say plainly what failed instead of claiming success.
            Common macOS shortcuts: cmd+c (copy), cmd+v (paste), cmd+z (undo), cmd+a (select all), cmd+tab (app switcher).
            The "super" key is the macOS Command (⌘) key.
            """

        // If the user drew on screen to mark WHERE to act, lead with the annotated
        // capture + a region hint (logical points). Mirrors analyzeHandoff's image+text
        // shape; the per-step screenshots later in the loop are unchanged.
        var firstContent: [[String: Any]] = []
        if let drawn, let b64 = drawn.annotatedJPEGBase64() {
            firstContent.append(["type": "image",
                                 "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]])
            firstContent.append(["type": "text", "text": "\(task)\n\n\(drawn.computerUseHint)"])
        } else {
            firstContent.append(["type": "text", "text": task])
        }
        var messages: [[String: Any]] = [
            ["role": "user", "content": firstContent]
        ]

        // Per-task cost ceiling: caps a single task's steps so one runaway task
        // can't burn the whole monthly budget (the cost-side guard that pairs
        // with the task-count quota). See project_mira_autonomy_direction.
        var stepsLeft = perTaskStepCeiling
        while !stopRequested, stepsLeft > 0 {
            stepsLeft -= 1
            AgentTaskManager.shared.update(activityID, status: .thinking, subtitle: "Thinking…")
            AgentTaskManager.shared.creepProgress(activityID)
            guard let response = await sendRequest(messages: messages, apiKey: apiKey, system: systemPrompt, width: w, height: h) else {
                result = "API request failed."
                MiraDebugLog.log("[Orchestrator] sendRequest returned nil — aborting loop at step \(perTaskStepCeiling - stepsLeft)")
                break
            }

            let content    = response["content"]    as? [[String: Any]] ?? []
            let stopReason = response["stop_reason"] as? String         ?? "end_turn"
            let toolCount  = content.filter { $0["type"] as? String == "tool_use" }.count
            MiraDebugLog.log("[Orchestrator] turn \(perTaskStepCeiling - stepsLeft): stop=\(stopReason) toolUses=\(toolCount) model=\(response["model"] as? String ?? "?")")

            // Sonnet 5 safety classifiers can decline a request (HTTP 200 +
            // stop_reason "refusal") — rare for ordinary desktop tasks. Surface
            // it rather than looping.
            if stopReason == "refusal" {
                result = "I couldn't complete that — the request was declined by the model's safety system."
                break
            }

            let turnText = content.compactMap { ($0["type"] as? String == "text") ? $0["text"] as? String : nil }.joined()

            messages.append(["role": "assistant", "content": content])

            let toolUses = content.filter { $0["type"] as? String == "tool_use" }

            if toolUses.isEmpty || stopReason == "end_turn" {
                result = turnText
                taskSucceeded = true
                MiraDebugLog.log("[Orchestrator] DONE after \(perTaskStepCeiling - stepsLeft) turns: \(turnText.prefix(200))")
                break
            }

            var toolResults: [[String: Any]] = []
            for tool in toolUses {
                let toolID = tool["id"]    as? String       ?? ""
                let input  = tool["input"] as? [String: Any] ?? [:]
                let action = input["action"] as? String      ?? ""

                AgentTaskManager.shared.update(activityID,
                                               status: .callingTools,
                                               subtitle: Self.activitySubtitle(for: action))
                AgentTaskManager.shared.creepProgress(activityID)

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
        return taskSucceeded
    }

    func stop() { stopRequested = true }

    // MARK: - Live-chip text

    /// Short, human title for the floating activity chip (first few words of the task).
    static func activityTitle(for task: String) -> String {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(separator: " ").prefix(6).joined(separator: " ")
        return words.isEmpty ? "Working" : words
    }

    /// Maps a computer_use action to a live "what's happening now" subtitle.
    static func activitySubtitle(for action: String) -> String {
        switch action {
        case "screenshot":                 return "Reading screen…"
        case "left_click", "click",
             "double_click", "right_click": return "Clicking…"
        case "type":                       return "Typing…"
        case "key", "hold_key":            return "Pressing keys…"
        case "scroll":                     return "Scrolling…"
        case "left_click_drag", "drag":    return "Dragging…"
        case "mouse_move", "cursor_position": return "Moving cursor…"
        case "wait":                       return "Waiting…"
        default:                           return "Acting…"
        }
    }

    // MARK: - Structured autonomous entry (router-first)

    /// The front door for a structured autonomous action. Routes through the
    /// deterministic ActuationRouter tiers first (AX background → AX-located
    /// cursor); only when the router reports `.needsVision` (AX-invisible app)
    /// does it fall into the Claude vision loop above. Counts the run and
    /// announces on completion — exactly once, regardless of which tier ran it.
    func perform(_ action: ActuationRouter.Action,
                 on bundleID: String,
                 taskDescription: String? = nil,
                 apiKey: String) async {
        let desc = taskDescription ?? action.phrasing

        // One quota consume for the whole task, up front (records + gates).
        let decision = await QuotaService.shared.consume(path: "routed")
        guard decision.allowed else {
            TaskAnnouncer.shared.announce(task: desc, success: false,
                                          detail: QuotaService.shared.tasksLeftText)
            return
        }

        let outcome = ActuationRouter.shared.perform(action, on: bundleID)

        // Tier 3: AX-invisible app → Claude vision loop. No second consume (this
        // task is already metered); runVisionLoop just executes + we announce.
        if outcome.path == .needsVision {
            let ok = await runVisionLoop(task: desc, apiKey: apiKey)
            if !stopRequested {
                TaskAnnouncer.shared.announce(task: desc, success: ok,
                                              detail: result.isEmpty ? nil : result)
            }
            return
        }

        // Tiers 1–2 executed deterministically: announce here.
        TaskAnnouncer.shared.announce(task: desc, success: outcome.success,
                                      detail: outcome.summary)
    }

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
        MiraBackend.authorizeAnthropic(&req, directKey: apiKey)
        req.setValue("2023-06-01",     forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = data
        req.timeoutInterval = 60

        if let (respData, resp) = try? await MiraBackend.proxyData(for: req),
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

        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            let coord = input["coordinate"] as? [Int] ?? [0, 0]
            let x = coord.count > 0 ? coord[0] : 0
            let y = coord.count > 1 ? coord[1] : 0
            let label = action.replacingOccurrences(of: "_", with: " ").capitalized
            // Fingerprint before/after so a click that hit nothing is reported
            // as such instead of a blind "OK" the model mistakes for success.
            let before = await cua.screenFingerprint()
            MiraDebugLog.log("[Orchestrator] \(action) at (\(x),\(y))")
            CodexLiveOverlay.shared.mark(rawX: Double(x), rawY: Double(y))
            switch action {
            case "double_click": cua.doubleClick(x: x, y: y)
            case "triple_click": cua.tripleClick(x: x, y: y)
            default:
                let btn = action == "right_click" ? "right" : action == "middle_click" ? "middle" : "left"
                cua.click(x: x, y: y, button: btn)
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            var note = "\(label) at (\(x), \(y)). The screenshot below shows the screen after the click — verify it had the intended effect before continuing."
            if let before, let after = await cua.screenFingerprint(),
               cua.changedFraction(before, after) < 0.005 {
                note = "\(label) at (\(x), \(y)) — WARNING: the screen did not visibly change, so the click likely missed its target or hit an inert area. Re-examine the screenshot below and try a different location."
            }
            let (content, shot) = await actionFeedback(note: note, settle: 0)
            return (content, CUAStep(action: action, details: "\(label) at (\(x), \(y))", screenshot: shot))

        case "left_click_drag":
            let s = input["start_coordinate"] as? [Int] ?? [0, 0]
            let e = input["coordinate"]       as? [Int] ?? [0, 0]
            cua.drag(fromX: s[0], fromY: s[1], toX: e[0], toY: e[1])
            let (content, shot) = await actionFeedback(note: "Drag performed (\(s[0]),\(s[1])) → (\(e[0]),\(e[1])). Verify the result in the screenshot below.")
            return (content, CUAStep(action: action, details: "Drag (\(s[0]),\(s[1])) → (\(e[0]),\(e[1]))", screenshot: shot))

        case "mouse_move":
            let coord = input["coordinate"] as? [Int] ?? [0, 0]
            cua.moveMouse(x: coord.count > 0 ? coord[0] : 0, y: coord.count > 1 ? coord[1] : 0)
            return ([ok], CUAStep(action: action, details: "Move to (\(coord[0]), \(coord[1]))"))

        case "type":
            let text = input["text"] as? String ?? ""
            cua.type(text: text)
            let preview = text.count > 50 ? String(text.prefix(50)) + "…" : text
            let (content, shot) = await actionFeedback(note: "Typed \"\(preview)\". The screenshot below shows the screen after typing — verify the text landed where intended.")
            return (content, CUAStep(action: action, details: "Type: \"\(preview)\"", screenshot: shot))

        case "key":
            let combo = input["text"] as? String ?? ""
            cua.key(combination: combo)
            let (content, shot) = await actionFeedback(note: "Pressed \(combo). The screenshot below shows the screen after the key press.")
            return (content, CUAStep(action: action, details: "Key: \(combo)", screenshot: shot))

        case "scroll":
            let coord     = input["coordinate"] as? [Int]    ?? [0, 0]
            let direction = input["direction"]  as? String   ?? "down"
            let amount    = input["amount"]     as? Int      ?? 3
            cua.scroll(x: coord.count > 0 ? coord[0] : 0, y: coord.count > 1 ? coord[1] : 0,
                       direction: direction, amount: amount)
            let (content, shot) = await actionFeedback(note: "Scrolled \(direction) ×\(amount) at (\(coord[0]), \(coord[1])). The screenshot below shows the screen after scrolling.")
            return (content, CUAStep(action: action, details: "Scroll \(direction) ×\(amount) at (\(coord[0]), \(coord[1]))", screenshot: shot))

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

    /// Post-action feedback: waits for the UI to settle, then returns a note plus
    /// a fresh screenshot so the model SEES what its action did instead of
    /// trusting a blind "OK" — the fix for "said it clicked but nothing happened".
    private func actionFeedback(note: String, settle: Double = 0.7) async -> ([[String: Any]], NSImage?) {
        if settle > 0 { try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000)) }
        var content: [[String: Any]] = [["type": "text", "text": note]]
        var image: NSImage? = nil
        if let data = await ComputerUseService.shared.screenshot() {
            content.append(["type": "image",
                            "source": ["type": "base64", "media_type": "image/png",
                                       "data": data.base64EncodedString()]])
            image = NSImage(data: data)
        }
        return (content, image)
    }

    // MARK: - API

    private func sendRequest(
        messages: [[String: Any]],
        apiKey: String,
        system: String,
        width: Int,
        height: Int
    ) async -> [String: Any]? {
        let body: [String: Any] = [
            // Sonnet 5 runs adaptive thinking by default when `thinking` is
            // omitted (sending `budget_tokens` or sampling params 400s), and
            // thinking tokens count toward max_tokens, so give headroom (the
            // proxy clamps to the plan cap anyway).
            "model":      "claude-sonnet-5",
            "max_tokens": 16000,
            "system":     system,
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
        // Sonnet 5 vision turns can run a while when thinking hard — don't cut them off.
        req.timeoutInterval = 300
        MiraBackend.authorizeAnthropic(&req, directKey: apiKey)
        req.setValue("2023-06-01",              forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json",        forHTTPHeaderField: "content-type")
        req.setValue("computer-use-2025-11-24", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = data

        do {
            let (respData, resp) = try await MiraBackend.proxyData(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                // The failure trail was invisible before — a rejected model,
                // clamped body, or auth error just became "API request failed."
                let body = String(data: respData, encoding: .utf8) ?? "<non-utf8>"
                MiraDebugLog.log("[Orchestrator] API \(status): \(body.prefix(500))")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
                MiraDebugLog.log("[Orchestrator] API 200 but non-JSON body")
                return nil
            }
            return json
        } catch {
            MiraDebugLog.log("[Orchestrator] request error: \(error.localizedDescription)")
            return nil
        }
    }
}
