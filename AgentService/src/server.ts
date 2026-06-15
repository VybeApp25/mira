import "dotenv/config";
import express from "express";
import type { Request } from "express";
import { runAgent, executeConfirmed, getConnectUrl, getConnectedApps, getConnectionStatuses } from "./agent";

const app = express();
app.use(express.json());

const PORT = Number(process.env.PORT) || 4242;

// The signed-in user's Supabase JWT, sent as `Authorization: Bearer …`. Every
// Composio call is reached through the composio-proxy edge function authorized
// by this token, so the secret Composio key never reaches the client.
function bearer(req: Request): string | undefined {
  const h = req.headers.authorization;
  if (typeof h === "string" && /^Bearer\s+/i.test(h)) return h.replace(/^Bearer\s+/i, "").trim();
  return undefined;
}

app.get("/health", (_req, res) => {
  res.json({ status: "ok", service: "mira-agent" });
});

app.post("/agent/run", async (req, res) => {
  const { prompt, userId, accessToken } = req.body as {
    prompt?: string;
    userId?: string;
    accessToken?: string;
  };

  if (!prompt || !userId || !accessToken) {
    res.status(400).json({ error: "Missing prompt, userId, or accessToken" });
    return;
  }
  if (!process.env.SUPABASE_URL) {
    res.status(500).json({ error: "SUPABASE_URL not set in .env" });
    return;
  }

  try {
    const result = await runAgent({ prompt, userId, accessToken });
    res.json(result);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("[/agent/run]", msg);
    res.status(500).json({ error: msg });
  }
});

app.post("/agent/confirm", async (req, res) => {
  const { toolName, params, userId, accessToken } = req.body as {
    toolName?: string;
    params?: Record<string, unknown>;
    userId?: string;
    accessToken?: string;
  };

  if (!toolName || !userId || !accessToken) {
    res.status(400).json({ error: "Missing toolName, userId, or accessToken" });
    return;
  }

  try {
    const result = await executeConfirmed(toolName, params ?? {}, userId, accessToken);
    res.json({ success: true, result });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    res.status(500).json({ error: msg });
  }
});

// OAuth connect URL for a given app
app.get("/connect/:app", async (req, res) => {
  const { userId } = req.query as { userId?: string };
  const token = bearer(req);
  if (!userId || !token) { res.status(400).json({ error: "Missing userId or accessToken" }); return; }

  try {
    const url = await getConnectUrl(req.params["app"]!, userId, token);
    res.json({ url });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    res.status(500).json({ error: msg });
  }
});

// Per-account health: slug + status (ACTIVE / EXPIRED / FAILED / ...)
app.get("/connections/status", async (req, res) => {
  const { userId } = req.query as { userId?: string };
  const token = bearer(req);
  if (!userId || !token) { res.status(400).json({ error: "Missing userId or accessToken", statuses: [] }); return; }

  try {
    const statuses = await getConnectionStatuses(userId, token);
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
  const token = bearer(req);
  if (!userId || !token) { res.status(400).json({ error: "Missing userId or accessToken", connected: [] }); return; }

  try {
    const connected = await getConnectedApps(userId, token);
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
