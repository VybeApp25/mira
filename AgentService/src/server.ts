import "dotenv/config";
import express from "express";
import { runAgent, executeConfirmed, getConnectUrl, getConnectedApps, getConnectionStatuses } from "./agent";

const app = express();
app.use(express.json());

const PORT = 4242;

app.get("/health", (_req, res) => {
  res.json({ status: "ok", service: "mira-agent" });
});

app.post("/agent/run", async (req, res) => {
  const { prompt, userId, claudeApiKey } = req.body as {
    prompt?: string;
    userId?: string;
    claudeApiKey?: string;
  };

  if (!prompt || !userId || !claudeApiKey) {
    res.status(400).json({ error: "Missing prompt, userId, or claudeApiKey" });
    return;
  }
  if (!process.env.COMPOSIO_API_KEY) {
    res.status(500).json({ error: "COMPOSIO_API_KEY not set in .env" });
    return;
  }

  try {
    const result = await runAgent({ prompt, userId, claudeApiKey });
    res.json(result);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("[/agent/run]", msg);
    res.status(500).json({ error: msg });
  }
});

app.post("/agent/confirm", async (req, res) => {
  const { toolName, params, userId } = req.body as {
    toolName?: string;
    params?: Record<string, unknown>;
    userId?: string;
  };

  if (!toolName || !userId) {
    res.status(400).json({ error: "Missing toolName or userId" });
    return;
  }

  try {
    const result = await executeConfirmed(toolName, params ?? {}, userId);
    res.json({ success: true, result });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    res.status(500).json({ error: msg });
  }
});

// OAuth connect URL for a given app
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

// Per-account health: slug + status (ACTIVE / EXPIRED / FAILED / ...)
app.get("/connections/status", async (req, res) => {
  const { userId } = req.query as { userId?: string };
  if (!userId) { res.status(400).json({ error: "Missing userId" }); return; }

  try {
    const statuses = await getConnectionStatuses(userId);
    res.json({ statuses });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("[/connections/status]", msg);
    res.status(500).json({ error: msg, statuses: [] });
  }
});

// Return the list of active connected app slugs for a user
app.get("/connections", async (req, res) => {
  const { userId } = req.query as { userId?: string };
  if (!userId) { res.status(400).json({ error: "Missing userId" }); return; }

  try {
    const connected = await getConnectedApps(userId);
    res.json({ connected });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("[/connections]", msg);
    res.status(500).json({ error: msg, connected: [] });
  }
});

app.listen(PORT, "127.0.0.1", () => {
  console.log(`Mira agent service → http://127.0.0.1:${PORT}`);
});
