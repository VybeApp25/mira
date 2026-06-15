// openai-proxy — reverse-proxies OpenAI /v1/chat/completions so the secret key
// never ships in the client. Same shape as anthropic-proxy. See
// docs/architecture/backend_secrets_proxy.md.
//
// Deploy:  supabase functions deploy openai-proxy
// Secret:  supabase secrets set OPENAI_API_KEY=sk-…

import { CORS, json, requireUser, requireEntitlement, checkQuota, meter } from "../_shared/auth.ts";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");

const ALLOWED_MODELS = new Set([
  "gpt-4o",
  "gpt-4o-mini",
  "gpt-4.1",
  "gpt-4.1-mini",
]);

const MAX_TOKENS_CAP: Record<string, number> = { free: 1500, pro: 8000, ultra: 16000 };

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST")    return json({ error: "method_not_allowed" }, 405);
  if (!OPENAI_API_KEY)          return json({ error: "OPENAI_API_KEY secret not set" }, 500);

  let user;
  try { user = await requireUser(req); } catch (r) { return r as Response; }

  try {
    requireEntitlement(user.plan, ["free", "pro", "ultra"]);
    await checkQuota(user.userId, "openai", user.plan);
  } catch (r) { return r as Response; }

  const body = await req.json().catch(() => null);
  if (!body || typeof body !== "object") return json({ error: "invalid_body" }, 400);
  if (!ALLOWED_MODELS.has(body.model))   return json({ error: "model_not_allowed", model: body.model }, 400);

  const cap = MAX_TOKENS_CAP[user.plan] ?? MAX_TOKENS_CAP.free;
  if (typeof body.max_tokens === "number") body.max_tokens = Math.min(body.max_tokens, cap);

  const isStream = body.stream === true;

  const upstream = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (isStream && upstream.ok && upstream.body) {
    meter(user.userId, "openai", estimateInputTokens(body), body.max_tokens ?? cap);
    return new Response(upstream.body, {
      status: upstream.status,
      headers: { ...CORS, "Content-Type": "text/event-stream", "Cache-Control": "no-cache" },
    });
  }

  const text = await upstream.text();
  if (upstream.ok) {
    try {
      const u = JSON.parse(text)?.usage; // { prompt_tokens, completion_tokens }
      if (u) await meter(user.userId, "openai", u.prompt_tokens ?? 0, u.completion_tokens ?? 0);
    } catch (_) { /* never fail the response on metering */ }
  }

  return new Response(text, {
    status: upstream.status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
});

function estimateInputTokens(body: { messages?: unknown }): number {
  return Math.ceil(JSON.stringify(body.messages ?? "").length / 4);
}
