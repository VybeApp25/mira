import Anthropic from "@anthropic-ai/sdk";
import { Composio } from "@composio/core";
import { AnthropicProvider } from "@composio/anthropic";

export interface AgentRequest {
  prompt: string;
  userId: string;
  claudeApiKey: string;
}

export interface AgentResponse {
  reply: string;
  toolsUsed: string[];
  requiresConfirmation?: ConfirmationRequest;
}

export interface ConfirmationRequest {
  toolName: string;
  description: string;
  toolCall: Anthropic.ToolUseBlock;
}

// Write/external actions always need user confirmation
const CONFIRM_BEFORE_RUN = new Set([
  "GMAIL_SEND_EMAIL",
  "GMAIL_REPLY_TO_THREAD",
  "GOOGLECALENDAR_CREATE_EVENT",
  "GOOGLECALENDAR_DELETE_EVENT",
  "NOTION_CREATE_PAGE",
  "NOTION_UPDATE_PAGE",
  "SLACK_SENDS_A_MESSAGE_AS_THE_APP",
]);

function makeComposio() {
  return new Composio({
    apiKey: process.env.COMPOSIO_API_KEY!,
    provider: new AnthropicProvider(),
  });
}

export async function runAgent(req: AgentRequest): Promise<AgentResponse> {
  const composio = makeComposio();
  const anthropic = new Anthropic({ apiKey: req.claudeApiKey });

  // Get Anthropic-format tools for this user's connected apps
  const tools = await composio.tools.get(req.userId, {
    toolkits: ["gmail", "googlecalendar", "notion"],
  }) as Anthropic.Tool[];

  const messages: Anthropic.MessageParam[] = [
    { role: "user", content: req.prompt },
  ];

  const toolsUsed: string[] = [];

  for (let i = 0; i < 5; i++) {
    const response = await anthropic.messages.create({
      model: "claude-haiku-4-5-20251001",
      max_tokens: 1024,
      system: `You are Mira, a screen-aware Mac assistant. Be concise and direct.
Lead with the answer. No preamble.
Use tools only when the user explicitly requests an action.
Always confirm before sending emails, creating events, or anything externally visible.`,
      tools,
      messages,
    });

    const replyText = response.content
      .filter((b): b is Anthropic.TextBlock => b.type === "text")
      .map((b) => b.text)
      .join("");

    if (response.stop_reason === "end_turn") {
      return { reply: replyText, toolsUsed };
    }

    const toolCalls = response.content.filter(
      (b): b is Anthropic.ToolUseBlock => b.type === "tool_use"
    );

    if (toolCalls.length === 0) {
      return { reply: replyText, toolsUsed };
    }

    messages.push({ role: "assistant", content: response.content });

    const toolResults: Anthropic.ToolResultBlockParam[] = [];

    for (const call of toolCalls) {
      toolsUsed.push(call.name);

      // Gate write actions — return to Swift for confirmation
      if (CONFIRM_BEFORE_RUN.has(call.name)) {
        return {
          reply: replyText || `Ready to ${describe(call.name, call.input as Record<string, unknown>)}. Confirm?`,
          toolsUsed,
          requiresConfirmation: {
            toolName: call.name,
            description: describe(call.name, call.input as Record<string, unknown>),
            toolCall: call,
          },
        };
      }

      // Safe read-only tools execute immediately via Composio
      const composioCall = { type: "tool_use" as const, id: call.id, name: call.name, input: call.input as Record<string, unknown> };
      const result = await composio.provider.executeToolCall(req.userId, composioCall);
      toolResults.push({
        type: "tool_result",
        tool_use_id: call.id,
        content: typeof result === "string" ? result : JSON.stringify(result),
      });
    }

    messages.push({ role: "user", content: toolResults });
  }

  return { reply: "Done.", toolsUsed };
}

export async function executeConfirmedCall(
  toolCall: Anthropic.ToolUseBlock,
  userId: string
): Promise<unknown> {
  const composio = makeComposio();
  const composioCall = { type: "tool_use" as const, id: toolCall.id, name: toolCall.name, input: toolCall.input as Record<string, unknown> };
  return composio.provider.executeToolCall(userId, composioCall);
}

// authConfigId = the Composio integration ID for the app (e.g. "gmail_default")
// Users look this up once from the Composio dashboard
export async function getConnectUrl(authConfigId: string, userId: string): Promise<string> {
  const composio = makeComposio();
  const conn = await composio.connectedAccounts.initiate(userId, authConfigId);
  return (conn as { redirectUrl?: string }).redirectUrl ?? "";
}

function describe(tool: string, input: Record<string, unknown>): string {
  switch (tool) {
    case "GMAIL_SEND_EMAIL": return `send an email to ${input["to"] ?? "recipient"}`;
    case "GMAIL_REPLY_TO_THREAD": return `reply to an email`;
    case "GOOGLECALENDAR_CREATE_EVENT": return `create event: "${input["summary"] ?? "event"}"`;
    case "GOOGLECALENDAR_DELETE_EVENT": return `delete a calendar event`;
    case "NOTION_CREATE_PAGE": return `create a Notion page`;
    default: return tool.toLowerCase().replace(/_/g, " ");
  }
}
