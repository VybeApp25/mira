// mint-realtime-token — mints a short-lived OpenAI Realtime client secret so the
// raw OpenAI key never reaches the client. Hardened: requires a verified Supabase
// JWT (a real, meterable user) before minting — previously this was open to anyone
// with the public anon key. Voice is free-tier, so all plans are allowed, but the
// caller must be authenticated AND within their daily voice cap (realtime audio is
// the most expensive COGS — see migration 20260628120000_voice_usage_quota.sql).
// See docs/architecture/backend_secrets_proxy.md.
//
// Deploy:  supabase functions deploy mint-realtime-token
// Secret:  supabase secrets set OPENAI_API_KEY=sk-…

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { CORS, json, requireUser, requireEntitlement, checkVoiceQuota, addVoiceUsage } from "../_shared/auth.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");
  if (!OPENAI_API_KEY) return json({ error: "OPENAI_API_KEY secret not set" }, 500);

  // Identity from the verified JWT (not the anon key). Voice mode is free-tier,
  // so every plan is allowed — but the caller must be a real, signed-in user who
  // is still within their daily voice allowance. checkVoiceQuota throws 429
  // `voice_quota_exceeded` (server-authoritative; a tampered client can't raise
  // its own cap) BEFORE we spend money minting an OpenAI session.
  let user;
  try {
    user = await requireUser(req);
    requireEntitlement(user.plan, ["free", "pro", "ultra"]);
    await checkVoiceQuota(user.userId, user.plan);
  } catch (r) { return r as Response; }

  let voice = "alloy";
  try {
    const body = await req.json();
    if (body.voice) voice = body.voice;
  } catch (_) { /* no body is fine */ }

  const model = "gpt-realtime";

  const openaiRes = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      session: { type: "realtime", model, audio: { output: { voice } } },
    }),
  });

  const payload = await openaiRes.json();
  if (!openaiRes.ok) {
    return new Response(JSON.stringify({ error: payload }), {
      status: openaiRes.status,
      headers: { ...CORS, "Content-Type": "application/json" },
    });
  }

  // Count this session against the daily voice cap (the hard, un-bypassable
  // half of the throttle). Actual audio seconds are reported separately by the
  // client on teardown via report-voice-usage (the soft half).
  addVoiceUsage(user.userId, 1, 0);

  return new Response(
    JSON.stringify({ token: payload.value ?? "", expires_at: payload.expires_at ?? 0, model }),
    { headers: { ...CORS, "Content-Type": "application/json" } },
  );
});
