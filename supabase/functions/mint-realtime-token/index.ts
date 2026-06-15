// mint-realtime-token — mints a short-lived OpenAI Realtime client secret so the
// raw OpenAI key never reaches the client. Hardened: requires a verified Supabase
// JWT (a real, meterable user) before minting — previously this was open to anyone
// with the public anon key. Voice is free-tier, so all plans are allowed, but the
// caller must be authenticated. See docs/architecture/backend_secrets_proxy.md.
//
// Deploy:  supabase functions deploy mint-realtime-token
// Secret:  supabase secrets set OPENAI_API_KEY=sk-…

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { CORS, json, requireUser, requireEntitlement, meter } from "../_shared/auth.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");
  if (!OPENAI_API_KEY) return json({ error: "OPENAI_API_KEY secret not set" }, 500);

  // Identity from the verified JWT (not the anon key). Voice mode is free-tier,
  // so every plan is allowed — but the caller must be a real, signed-in user.
  let user;
  try {
    user = await requireUser(req);
    requireEntitlement(user.plan, ["free", "pro", "ultra"]);
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

  // Record a session start (token-level metering for realtime audio is out of
  // scope; one "request" per minted session is enough for rate-limiting).
  meter(user.userId, "openai-realtime", 0, 0);

  return new Response(
    JSON.stringify({ token: payload.value ?? "", expires_at: payload.expires_at ?? 0, model }),
    { headers: { ...CORS, "Content-Type": "application/json" } },
  );
});
