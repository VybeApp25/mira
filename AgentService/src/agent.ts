import { generateText, stepCountIs } from "ai";
import { createAnthropic } from "@ai-sdk/anthropic";
import { Composio } from "@composio/core";
import { VercelProvider } from "@composio/vercel";

export interface AgentRequest {
  prompt: string;
  userId: string;
  claudeApiKey: string;
}

export interface AgentResponse {
  reply: string;
  toolsUsed: string[];
  requiresConfirmation?: PendingAction;
}

export interface PendingAction {
  toolName: string;
  description: string;
  params: Record<string, unknown>;
}

// Write/external actions that always need user confirmation first
const CONFIRM_BEFORE_RUN = new Set([
  "GMAIL_SEND_EMAIL",
  "GMAIL_REPLY_TO_THREAD",
  "GOOGLECALENDAR_CREATE_EVENT",
  "GOOGLECALENDAR_DELETE_EVENT",
  "NOTION_CREATE_PAGE",
  "NOTION_UPDATE_PAGE",
  "SLACK_SENDS_A_MESSAGE_AS_THE_APP",
]);

const SYSTEM_PROMPT = `You are Mira, a screen-aware Mac assistant. Be concise and direct.
Lead with the answer. No preamble.
Use tools only when the user explicitly requests an action.
For write actions the system will confirm with the user before anything is sent or changed.`;

function makeComposio() {
  return new Composio({
    apiKey: process.env.COMPOSIO_API_KEY!,
    provider: new VercelProvider(),
  });
}

// Wrap confirmation-gated tools so they signal "needs confirmation" instead of executing
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function wrapTools(rawTools: Record<string, any>): Record<string, any> {
  return Object.fromEntries(
    Object.entries(rawTools).map(([name, tool]) => {
      if (!CONFIRM_BEFORE_RUN.has(name)) return [name, tool];
      return [name, {
        ...tool,
        execute: async (params: Record<string, unknown>) => ({
          __pending_confirmation: true,
          toolName: name,
          description: describe(name, params),
          params,
        }),
      }];
    })
  );
}

export async function runAgent(req: AgentRequest): Promise<AgentResponse> {
  const composio = makeComposio();
  const anthropic = createAnthropic({ apiKey: req.claudeApiKey });

  // Tool router session — Composio manages execution + routing
  const session = await composio.create(req.userId);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const rawTools = await session.tools() as Record<string, any>;
  const tools = wrapTools(rawTools);

  const result = await generateText({
    model: anthropic("claude-haiku-4-5-20251001"),
    system: SYSTEM_PROMPT,
    prompt: req.prompt,
    tools,
    stopWhen: stepCountIs(5),
  });

  // Scan all steps for a pending confirmation signal
  for (const step of result.steps) {
    for (const toolResult of step.toolResults) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const output = (toolResult as any).output ?? (toolResult as any).result;
      if (output?.__pending_confirmation) {
        return {
          reply: `Ready to ${output.description as string}. Confirm?`,
          toolsUsed: [],
          requiresConfirmation: {
            toolName: output.toolName as string,
            description: output.description as string,
            params: output.params as Record<string, unknown>,
          },
        };
      }
    }
  }

  const toolsUsed = result.steps.flatMap(s =>
    s.toolCalls.map(c => c.toolName)
  );

  return { reply: result.text, toolsUsed };
}

export async function executeConfirmed(
  toolName: string,
  params: Record<string, unknown>,
  userId: string
): Promise<unknown> {
  const composio = makeComposio();
  const session = await composio.create(userId);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return (session as any).executeAction(toolName, params);
}

export async function getConnectUrl(app: string, userId: string): Promise<string> {
  const composio = makeComposio();
  const conn = await composio.connectedAccounts.initiate(userId, app.toUpperCase());
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
