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

// Integrations Mira exposes — must match toolkit slugs in Composio
export const SUPPORTED_TOOLKITS = [
  "gmail",
  "googlecalendar",
  "notion",
  "slack",
  "github",
  "linear",
];

// Write/external actions that always need user confirmation before executing
const CONFIRM_BEFORE_RUN = new Set([
  // Gmail
  "GMAIL_SEND_EMAIL",
  "GMAIL_REPLY_TO_THREAD",
  "GMAIL_CREATE_EMAIL_DRAFT",
  // Google Calendar
  "GOOGLECALENDAR_CREATE_EVENT",
  "GOOGLECALENDAR_DELETE_EVENT",
  "GOOGLECALENDAR_UPDATE_EVENT",
  // Notion
  "NOTION_CREATE_PAGE",
  "NOTION_UPDATE_PAGE",
  "NOTION_DELETE_PAGE",
  // Slack
  "SLACK_SENDS_A_MESSAGE_AS_THE_APP",
  "SLACK_SEND_MESSAGE",
  "SLACK_CREATE_CHANNEL",
  // GitHub
  "GITHUB_CREATE_AN_ISSUE",
  "GITHUB_CREATE_PULL_REQUEST",
  "GITHUB_CREATE_A_RELEASE",
  "GITHUB_DELETE_A_REPOSITORY",
  // Linear
  "LINEAR_CREATE_ISSUE",
  "LINEAR_UPDATE_ISSUE",
  "LINEAR_DELETE_ISSUE",
]);

const SYSTEM_PROMPT = `You are Mira, a screen-aware Mac assistant with access to the user's connected apps. Be concise and direct.
Lead with the answer. No preamble. No markdown.
Use tools only when the user explicitly requests an action.
For write actions (send email, create event, post message, create issue) the system will confirm with the user before executing.
When reading data (list emails, fetch calendar, search Notion), proceed without confirmation.
Always summarize what you found or did in plain language — no raw JSON dumps.`;

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

  // Load tools filtered to supported toolkits only
  const session = await composio.create(req.userId);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const rawTools = await (session as any).tools({
    toolkitSlugs: SUPPORTED_TOOLKITS,
  }) as Record<string, any>;
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

export async function getConnectedApps(userId: string): Promise<string[]> {
  const composio = makeComposio();
  const result = await composio.connectedAccounts.list({
    userIds: [userId],
    statuses: ["ACTIVE"],
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return (result.items ?? []).map((a: any) => (a.toolkit?.slug ?? "").toLowerCase()).filter(Boolean);
}

function describe(tool: string, input: Record<string, unknown>): string {
  switch (tool) {
    case "GMAIL_SEND_EMAIL":
      return `send email to ${input["to"] ?? "recipient"}`;
    case "GMAIL_REPLY_TO_THREAD":
      return `reply to an email thread`;
    case "GMAIL_CREATE_EMAIL_DRAFT":
      return `create a draft email to ${input["to"] ?? "recipient"}`;
    case "GOOGLECALENDAR_CREATE_EVENT":
      return `create calendar event: "${input["summary"] ?? "event"}"`;
    case "GOOGLECALENDAR_DELETE_EVENT":
      return `delete calendar event`;
    case "GOOGLECALENDAR_UPDATE_EVENT":
      return `update calendar event: "${input["summary"] ?? "event"}"`;
    case "NOTION_CREATE_PAGE":
      return `create Notion page: "${input["title"] ?? "page"}"`;
    case "NOTION_UPDATE_PAGE":
      return `update Notion page`;
    case "NOTION_DELETE_PAGE":
      return `delete Notion page`;
    case "SLACK_SENDS_A_MESSAGE_AS_THE_APP":
    case "SLACK_SEND_MESSAGE":
      return `send Slack message to ${input["channel"] ?? "channel"}`;
    case "GITHUB_CREATE_AN_ISSUE":
      return `create GitHub issue: "${input["title"] ?? "issue"}"`;
    case "GITHUB_CREATE_PULL_REQUEST":
      return `create pull request: "${input["title"] ?? "PR"}"`;
    case "LINEAR_CREATE_ISSUE":
      return `create Linear issue: "${input["title"] ?? "issue"}"`;
    case "LINEAR_UPDATE_ISSUE":
      return `update Linear issue`;
    default:
      return tool.toLowerCase().replace(/_/g, " ");
  }
}
