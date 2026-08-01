using Mira.Windows.Core.Providers;
using Newtonsoft.Json.Linq;

namespace Mira.Windows.Core.Vision;

/// <summary>
/// The Windows equivalent of macOS's <c>ComputerUseOrchestrator</c>
/// (Mira/Services/ComputerUseOrchestrator.swift) — drives a multi-turn Claude
/// <c>computer_20251124</c> tool-use session against <c>anthropic-proxy</c>
/// (same model <c>claude-sonnet-5</c>, same <c>anthropic-beta:
/// computer-use-2025-11-24</c> header, same 40-step per-task ceiling, same
/// screenshot-verified action-feedback loop, same before/after fingerprint
/// check so a click that hit nothing is reported as such instead of a blind "OK"),
/// executing every tool call via <see cref="ScreenCapture"/>/<see cref="SyntheticInput"/>.
///
/// Deliberately narrower than the Swift original — this is the Windows client's
/// FIRST computer-use capability, not a port of Mira's full autonomy stack:
/// <list type="bullet">
/// <item>No 3-tier <c>ActuationRouter</c>/<c>AXActuationService</c> — the Mac
/// app tries background UI-tree actuation (no cursor movement) and
/// AX-located-cursor clicks before falling back to this vision loop; this port
/// goes straight to the vision loop for every request. The equivalent Windows
/// primitive (UI Automation's Invoke/SetValue patterns) is a real follow-up,
/// not built here.</item>
/// <item>No quota/task-run metering (<c>QuotaService</c> has no Windows port
/// yet) and no live activity-chip UI (<c>AgentTaskManager</c>/<c>TaskAnnouncer</c>
/// likewise) — <see cref="StepCompleted"/> is the one hook a caller has today.</item>
/// <item>No click-marker overlay (<c>CodexLiveOverlay</c>) — nothing currently
/// shows the user *where* Mira is about to click before it happens.</item>
/// </list>
/// </summary>
public sealed class ComputerUseOrchestrator
{
    public static ComputerUseOrchestrator Shared { get; } = new();

    private const string Model = "claude-sonnet-5";
    private const int PerTaskStepCeiling = 40;
    private static readonly IReadOnlyDictionary<string, string> ComputerUseBetaHeader =
        new Dictionary<string, string> { ["anthropic-beta"] = "computer-use-2025-11-24" };

    private bool _stopRequested;

    public event Action<ComputerUseStep>? StepCompleted;

    /// <summary>
    /// Fired once at the start/end of every <see cref="RunAsync"/> call — the
    /// hook <see cref="Shell.AgentActivityWindow"/> uses to show/hide the
    /// floating activity chip (there's no persisted "AgentJob" system on
    /// Windows yet, unlike macOS's <c>AgentJobStore</c>-backed chips, so this
    /// covers only the ephemeral "AgentActivity" half of the Mac app's chip
    /// system for now — see docs/windows/IMPLEMENTATION_PLAN.md Phase 6).
    /// </summary>
    public event Action? TaskStarted;

    /// <summary>Fired exactly once per <see cref="RunAsync"/> call, on every exit path (success, refusal, API error, step-ceiling, or <see cref="Stop"/>).</summary>
    public event Action? TaskFinished;

    private ComputerUseOrchestrator() { }

    public void Stop() => _stopRequested = true;

    /// <summary>Runs the vision-control loop for <paramref name="task"/> until Claude signals completion, the step ceiling is hit, or <see cref="Stop"/> is called. Returns Claude's final text.</summary>
    public async Task<string> RunAsync(string task, CancellationToken ct = default)
    {
        TaskStarted?.Invoke();
        try
        {
            return await RunCoreAsync(task, ct);
        }
        finally
        {
            TaskFinished?.Invoke();
        }
    }

    private async Task<string> RunCoreAsync(string task, CancellationToken ct)
    {
        _stopRequested = false;
        var width = ScreenCapture.DisplayWidth;
        var height = ScreenCapture.DisplayHeight;

        var systemPrompt =
            $"""
            You are controlling a Windows computer. Display size: {width}x{height} pixels (top-left origin).
            Use the computer tool to accomplish the task. Take a screenshot first to see the current state.
            After every click, type, key press, scroll, or drag you receive a fresh screenshot showing the result. Study it and verify the action had the intended effect before moving on. If it didn't (nothing happened, wrong element, unexpected state), do not repeat the same action blindly — re-locate the target in the screenshot and adjust.
            Never claim an action succeeded unless the screenshot proves it. Only declare the task complete once the final screenshot visibly shows the goal state; if you cannot get there, say plainly what failed instead of claiming success.
            Common Windows shortcuts: ctrl+c (copy), ctrl+v (paste), ctrl+z (undo), ctrl+a (select all), alt+tab (app switcher).
            The "super"/"win" key is the Windows key.

            Opening an application (Start menu search + Enter, taskbar icon, desktop shortcut) can take several seconds to actually appear on screen, especially on first launch — a blank, half-rendered, or still-loading window is normal, not a failure. If the app you just launched doesn't look right yet, use the wait action and take another screenshot before concluding anything went wrong. Do not close a window you just opened unless the screenshot gives clear evidence it's the wrong one entirely. And do not treat a slow-to-open app as "not installed" — never go looking for an app in the Microsoft Store or a browser download page unless you have first confirmed, after waiting, that it truly isn't already on this PC.
            """;

        var messages = new JArray
        {
            new JObject { ["role"] = "user", ["content"] = new JArray { new JObject { ["type"] = "text", ["text"] = task } } },
        };

        var stepsLeft = PerTaskStepCeiling;
        var result = "";

        // Sliding cache breakpoint for the growing conversation history -- this is
        // what actually balloons in size across a multi-step task (every prior
        // screenshot stays in `messages`), unlike the static system+tools prefix
        // below. Each step marks the current last content block cacheable, then
        // un-marks it before the NEXT step moves the breakpoint forward -- otherwise
        // stale breakpoints would accumulate past Anthropic's 4-per-request limit
        // well before the 40-step ceiling.
        JObject? previousCacheBreakpoint = null;

        while (!_stopRequested && stepsLeft-- > 0)
        {
            JObject response;
            try
            {
                if (previousCacheBreakpoint is not null) previousCacheBreakpoint.Remove("cache_control");
                if (messages.Count > 0 && messages[^1]?["content"] is JArray lastContent && lastContent.Count > 0 && lastContent[^1] is JObject lastBlock)
                {
                    lastBlock["cache_control"] = new JObject { ["type"] = "ephemeral" };
                    previousCacheBreakpoint = lastBlock;
                }

                // system + tools are byte-identical on every single step of a task (only
                // the growing messages array changes), so both are marked cacheable --
                // Anthropic serves the cached prefix back much faster on steps 2+ instead
                // of fully reprocessing the same system prompt/tool schema from scratch
                // every step. Pure latency/cost win, no behavior change -- neither this
                // port nor the Swift original used caching here before this pass.
                var body = new JObject
                {
                    ["model"] = Model,
                    ["max_tokens"] = 16000,
                    ["system"] = new JArray
                    {
                        new JObject
                        {
                            ["type"] = "text",
                            ["text"] = systemPrompt,
                            ["cache_control"] = new JObject { ["type"] = "ephemeral" },
                        },
                    },
                    ["tools"] = new JArray
                    {
                        new JObject
                        {
                            ["type"] = "computer_20251124", ["name"] = "computer",
                            ["display_width_px"] = width, ["display_height_px"] = height,
                            ["cache_control"] = new JObject { ["type"] = "ephemeral" },
                        },
                    },
                    ["messages"] = messages,
                };
                response = await AnthropicProxyClient.SendRawAsync(body, ComputerUseBetaHeader, ct);
            }
            catch (Exception ex)
            {
                return $"API request failed: {ex.Message}";
            }

            var content = response["content"] as JArray ?? new JArray();
            var stopReason = (string?)response["stop_reason"] ?? "end_turn";

            if (stopReason == "refusal")
                return "I couldn't complete that — the request was declined by the model's safety system.";

            var turnText = string.Concat(content.Where(b => (string?)b["type"] == "text").Select(b => (string?)b["text"] ?? ""));
            messages.Add(new JObject { ["role"] = "assistant", ["content"] = content });

            var toolUses = content.Where(b => (string?)b["type"] == "tool_use").ToList();
            if (toolUses.Count == 0 || stopReason == "end_turn")
            {
                result = turnText;
                break;
            }

            var toolResults = new JArray();
            foreach (var tool in toolUses)
            {
                var toolId = (string?)tool["id"] ?? "";
                var input = tool["input"] as JObject ?? new JObject();
                var action = (string?)input["action"] ?? "";

                var (resultContent, step) = await ExecuteActionAsync(action, input, ct);
                toolResults.Add(new JObject { ["type"] = "tool_result", ["tool_use_id"] = toolId, ["content"] = resultContent });
                StepCompleted?.Invoke(step);
            }
            messages.Add(new JObject { ["role"] = "user", ["content"] = toolResults });
        }

        return result;
    }

    private static async Task<(JArray Content, ComputerUseStep Step)> ExecuteActionAsync(string action, JObject input, CancellationToken ct)
    {
        switch (action)
        {
            case "screenshot":
            {
                var jpeg = ScreenCapture.CaptureJpeg();
                if (jpeg is null) return (Ok(), new ComputerUseStep(action, "Screenshot failed"));
                return (new JArray { ImageBlock(jpeg) }, new ComputerUseStep(action, "Screenshot captured"));
            }

            case "left_click" or "right_click" or "middle_click" or "double_click" or "triple_click":
            {
                var (x, y) = Coord(input, "coordinate");
                var label = action.Replace("_", " ");
                var before = ScreenCapture.CaptureFingerprint();

                switch (action)
                {
                    case "double_click": SyntheticInput.DoubleClick(x, y); break;
                    case "triple_click": SyntheticInput.TripleClick(x, y); break;
                    default:
                        var btn = action == "right_click" ? "right" : action == "middle_click" ? "middle" : "left";
                        SyntheticInput.Click(x, y, btn);
                        break;
                }

                await Task.Delay(800, ct);
                var note = $"{label} at ({x}, {y}). The screenshot below shows the screen after the click — verify it had the intended effect before continuing.";
                var after = ScreenCapture.CaptureFingerprint();
                if (before is not null && after is not null && ScreenCapture.ChangedFraction(before, after) < 0.005)
                    note = $"{label} at ({x}, {y}) — WARNING: the screen did not visibly change, so the click likely missed its target or hit an inert area. Re-examine the screenshot below and try a different location.";

                var content = await ActionFeedbackAsync(note, ct);
                return (content, new ComputerUseStep(action, $"{label} at ({x}, {y})"));
            }

            case "left_click_drag":
            {
                var (sx, sy) = Coord(input, "start_coordinate");
                var (ex, ey) = Coord(input, "coordinate");
                SyntheticInput.Drag(sx, sy, ex, ey);
                var content = await ActionFeedbackAsync($"Drag ({sx},{sy}) -> ({ex},{ey}). Verify the result in the screenshot below.", ct);
                return (content, new ComputerUseStep(action, $"Drag ({sx},{sy}) -> ({ex},{ey})"));
            }

            case "mouse_move":
            {
                var (x, y) = Coord(input, "coordinate");
                SyntheticInput.MoveMouse(x, y);
                return (Ok(), new ComputerUseStep(action, $"Move to ({x}, {y})"));
            }

            case "type":
            {
                var text = (string?)input["text"] ?? "";
                SyntheticInput.Type(text);
                var preview = text.Length > 50 ? text[..50] + "…" : text;
                var content = await ActionFeedbackAsync($"Typed \"{preview}\". The screenshot below shows the screen after typing — verify the text landed where intended.", ct);
                return (content, new ComputerUseStep(action, $"Type: \"{preview}\""));
            }

            case "key":
            {
                var combo = (string?)input["text"] ?? "";
                SyntheticInput.Key(combo);

                // Enter/Return most often confirms a Start-menu search to launch an
                // app — the single biggest source of the "looks like nothing
                // happened, let it try something else" misjudgment (e.g. closing
                // the just-opened app and going to install it from the Store
                // instead), because app cold-starts routinely take longer than the
                // ~0.7s default settle delay used for ordinary UI actions.
                var isLaunchLike = combo.Contains("enter", StringComparison.OrdinalIgnoreCase)
                    || combo.Contains("return", StringComparison.OrdinalIgnoreCase);
                var content = await ActionFeedbackAsync($"Pressed {combo}. The screenshot below shows the screen after the key press.",
                    ct, settleSeconds: isLaunchLike ? 2.0 : 0.7);
                return (content, new ComputerUseStep(action, $"Key: {combo}"));
            }

            case "scroll":
            {
                var (x, y) = Coord(input, "coordinate");
                var direction = (string?)input["direction"] ?? "down";
                var amount = (int?)input["amount"] ?? 3;
                SyntheticInput.Scroll(x, y, direction, amount);
                var content = await ActionFeedbackAsync($"Scrolled {direction} x{amount} at ({x}, {y}). The screenshot below shows the screen after scrolling.", ct);
                return (content, new ComputerUseStep(action, $"Scroll {direction} x{amount} at ({x}, {y})"));
            }

            case "cursor_position":
            {
                var (x, y) = SyntheticInput.CursorPosition();
                return (new JArray { new JObject { ["type"] = "text", ["text"] = $"{{\"x\":{x},\"y\":{y}}}" } },
                    new ComputerUseStep(action, $"Cursor at ({x}, {y})"));
            }

            case "wait":
            {
                var duration = (double?)input["duration"] ?? 2.0;
                await Task.Delay((int)(duration * 1000), ct);
                return (Ok(), new ComputerUseStep(action, $"Waited {duration:F1}s"));
            }

            default:
                return (new JArray { new JObject { ["type"] = "text", ["text"] = $"Unknown action: {action}" } },
                    new ComputerUseStep(action, $"Unknown: {action}"));
        }
    }

    private static (int X, int Y) Coord(JObject input, string field)
    {
        var arr = input[field] as JArray;
        var x = arr is { Count: > 0 } ? (int)arr[0]! : 0;
        var y = arr is { Count: > 1 } ? (int)arr[1]! : 0;
        return (x, y);
    }

    private static JArray Ok() => new() { new JObject { ["type"] = "text", ["text"] = "OK" } };

    private static JObject ImageBlock(byte[] jpegBytes) => new()
    {
        ["type"] = "image",
        ["source"] = new JObject { ["type"] = "base64", ["media_type"] = "image/jpeg", ["data"] = Convert.ToBase64String(jpegBytes) },
    };

    /// <summary>Waits for the UI to settle, then returns a note plus a fresh screenshot so the model SEES the result instead of trusting a blind "OK".</summary>
    private static async Task<JArray> ActionFeedbackAsync(string note, CancellationToken ct, double settleSeconds = 0.7)
    {
        if (settleSeconds > 0) await Task.Delay((int)(settleSeconds * 1000), ct);
        var content = new JArray { new JObject { ["type"] = "text", ["text"] = note } };
        var jpeg = ScreenCapture.CaptureJpeg();
        if (jpeg is not null) content.Add(ImageBlock(jpeg));
        return content;
    }
}
