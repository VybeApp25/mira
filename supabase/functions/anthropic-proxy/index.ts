// anthropic-proxy — reverse-proxies Anthropic /v1/messages so the secret key
// never ships in the client. Verifies the user's Supabase JWT, enforces plan +
// daily quota, caps max_tokens, allowlists models, then forwards the (unchanged)
// request body with the server-held key and streams the response straight back.
// See docs/architecture/backend_secrets_proxy.md.
//
// Deploy:  supabase functions deploy anthropic-proxy
// Secret:  supabase secrets set ANTHROPIC_API_KEY=sk-ant-…

import { CORS, json, requireUser, requireEntitlement, checkQuota, meter } from "../_shared/auth.ts";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");

// Only models Mira actually uses — reject anything else so a stolen session
// can't call arbitrary (e.g. more expensive) models.
const ALLOWED_MODELS = new Set([
  "claude-opus-4-8",
  "claude-sonnet-4-6",
  "claude-haiku-4-5",
  "claude-haiku-4-5-20251001",
]);

// Hard per-plan ceiling on max_tokens (one call can't drain the day's budget).
const MAX_TOKENS_CAP: Record<string, number> = { free: 1500, pro: 8000, ultra: 16000 };

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST")    return json({ error: "method_not_allowed" }, 405);
  if (!ANTHROPIC_API_KEY)       return json({ error: "ANTHROPIC_API_KEY secret not set" }, 500);

  // 1) Identity + plan (from the verified JWT, never the body).
  let user;
  try { user = await requireUser(req); } catch (r) { return r as Response; }

  // 2) Entitlement + quota. (Chat is allowed on every plan; tighten per-feature
  //    later by passing the relevant entitlement here.)
  try {
    requireEntitlement(user.plan, ["free", "pro", "ultra"]);
    await checkQuota(user.userId, "anthropic", user.plan);
  } catch (r) { return r as Response; }

  // 3) Validate + sanitize the body.
  const body = await req.json().catch(() => null);
  if (!body || typeof body !== "object") return json({ error: "invalid_body" }, 400);
  if (!ALLOWED_MODELS.has(body.model))   return json({ error: "model_not_allowed", model: body.model }, 400);

  const cap = MAX_TOKENS_CAP[user.plan] ?? MAX_TOKENS_CAP.free;
  body.max_tokens = typeof body.max_tokens === "number" ? Math.min(body.max_tokens, cap) : cap;

  const isStream = body.stream === true;

  // 4) Forward with the server-held key.
  const upstream = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": ANTHROPIC_API_KEY,
      "anthropic-version": req.headers.get("anthropic-version") ?? "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });

  // 5a) Streaming: pass the SSE body straight through. Precise per-stream token
  //     metering needs teeing the stream; for now charge a conservative estimate
  //     (most Mira calls are non-streaming and metered exactly below).
  if (isStream && upstream.ok && upstream.body) {
    meter(user.userId, "anthropic", estimateInputTokens(body), body.max_tokens);
    return new Response(upstream.body, {
      status: upstream.status,
      headers: { ...CORS, "Content-Type": "text/event-stream", "Cache-Control": "no-cache" },
    });
  }

  // 5b) Non-streaming: meter exactly from the response usage block.
  const text = await upstream.text();
  if (upstream.ok) {
    try {
      const u = JSON.parse(text)?.usage;
      if (u) await meter(user.userId, "anthropic", u.input_tokens ?? 0, u.output_tokens ?? 0);
    } catch (_) { /* ignore parse issues; never fail the response on metering */ }
  }

  return new Response(text, {
    status: upstream.status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
});

// Rough input-token estimate (~4 chars/token) for streaming requests, where we
// can't read the usage block without consuming the stream.
function estimateInputTokens(body: { messages?: unknown; system?: unknown }): number {
  const blob = JSON.stringify(body.messages ?? "") + JSON.stringify(body.system ?? "");
  return Math.ceil(blob.length / 4);
}
