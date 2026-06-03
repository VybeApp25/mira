import express from "express";
import { runAgent, executeConfirmedCall, getConnectUrl } from "./agent";
import type { ConfirmationRequest } from "./agent";
import type Anthropic from "@anthropic-ai/sdk";

const app = express();
app.use(express.json());

const PORT = 4242;

app.get("/health", (_req, res) => {
  res.json({ status: "ok", service: "mira-agent" });
});

// Swift → run agent with prompt
app.post("/agent/run", async (req, res) => {
  const { prompt, userId, claudeApiKey } = req.body as {
    prompt: string;
    userId: string;
    claudeApiKey: string;
  };

  if (!prompt || !userId || !claudeApiKey) {
    res.status(400).json({ error: "Missing prompt, userId, or claudeApiKey" });
    return;
  }

  if (!process.env.COMPOSIO_API_KEY) {
    res.status(500).json({ error: "COMPOSIO_API_KEY not set" });
    return;
  }

  try {
    const result = await runAgent({ prompt, userId, claudeApiKey });
    res.json(result);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("[agent/run]", msg);
    res.status(500).json({ error: msg });
  }
});

// Swift → user confirmed an action — execute it
app.post("/agent/confirm", async (req, res) => {
  const { toolCall, userId } = req.body as {
    toolCall: Anthropic.ToolUseBlock;
    userId: string;
  };

  if (!toolCall || !userId) {
    res.status(400).json({ error: "Missing toolCall or userId" });
    return;
  }

  try {
    const result = await executeConfirmedCall(toolCall, userId);
    res.json({ success: true, result });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    res.status(500).json({ error: msg });
  }
});

// Swift → open browser to connect an app (Gmail, Notion, etc.)
app.get("/connect/:app", async (req, res) => {
  const { userId } = req.query as { userId?: string };
  if (!userId) { res.status(400).json({ error: "Missing userId" }); return; }

  try {
    const url = await getConnectUrl(req.params["app"]!, userId);
    res.json({ url });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    res.status(500).json({ error: msg });
  }
});

app.listen(PORT, "127.0.0.1", () => {
  console.log(`Mira agent service → http://127.0.0.1:${PORT}`);
});
