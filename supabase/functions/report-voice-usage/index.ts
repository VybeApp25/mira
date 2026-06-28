// report-voice-usage — the client POSTs the duration of a realtime voice session
// when it tears down, so the daily seconds cap (the soft half of the voice
// throttle) accumulates real usage. Authenticated: identity comes from the
// verified JWT, never the body. A client can only UNDER-report (which the hard
// session-count cap in mint-realtime-token already bounds), so this is safe to
// trust for cost-shaping. See migration 20260628120000_voice_usage_quota.sql.
//
// Deploy:  supabase functions deploy report-voice-usage
//
// Body: { "seconds": <int> }   →   { "status": "ok" }

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { CORS, json, requireUser, addVoiceUsage } from "../_shared/auth.ts";

// One session can't credibly exceed this; clamp so a bad/garbage value can't
// poison the daily total. (A malicious over-report would only throttle the
// attacker's own account, but clamp anyway for hygiene.)
const MAX_SESSION_SECONDS = 3600;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  let user;
  try { user = await requireUser(req); }
  catch (r) { return r as Response; }

  let seconds = 0;
  try {
    const body = await req.json();
    seconds = Number(body?.seconds ?? 0);
  } catch (_) { /* empty body → 0 seconds, harmless */ }

  if (!Number.isFinite(seconds) || seconds <= 0) return json({ status: "ok" });
  seconds = Math.min(Math.round(seconds), MAX_SESSION_SECONDS);

  await addVoiceUsage(user.userId, 0, seconds);
  return json({ status: "ok" });
});
