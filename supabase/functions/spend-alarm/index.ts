// Called hourly by pg_cron via pg_net.
// Pages (email via Resend) when today's aggregate spend looks abnormal across
// ALL users — either TOKEN usage (text/vision, from `usage`) OR VOICE audio
// minutes (Realtime, from `voice_usage`; the priciest per-user COGS and NOT
// token-metered, so it needs its own limb of the alarm). A 6-hour cooldown
// prevents repeat paging.
//
// Deployed with --no-verify-jwt (pg_cron sends only x-cron-secret, no Supabase
// JWT — the gateway would 401 it before this code runs otherwise).
//
// Secrets required:
//   CRON_SECRET               — shared secret validated in x-cron-secret header
//   RESEND_API_KEY            — from resend.com (free tier is fine for alerts)
//   SPEND_ALARM_TOKENS        — optional, default 2000000 (tokens/day aggregate)
//   SPEND_ALARM_VOICE_SECONDS — optional, default 36000 (=600 min/day aggregate); <0 disables the voice limb
//   SPEND_ALARM_EMAIL         — optional, default trevonbarbour@gmail.com

import { createClient } from "jsr:@supabase/supabase-js@2";
import { CORS, json } from "../_shared/auth.ts";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const TOKEN_THRESHOLD  = parseInt(Deno.env.get("SPEND_ALARM_TOKENS") ?? "2000000");
const VOICE_SEC_THRESH = parseInt(Deno.env.get("SPEND_ALARM_VOICE_SECONDS") ?? "36000");
const ALERT_EMAIL      = Deno.env.get("SPEND_ALARM_EMAIL") ?? "trevonbarbour@gmail.com";
const COOLDOWN_MS      = 6 * 60 * 60 * 1000;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  // Validate cron secret so random callers can't spam the alarm log
  const cronSecret = Deno.env.get("CRON_SECRET");
  if (cronSecret && req.headers.get("x-cron-secret") !== cronSecret) {
    return new Response("Unauthorized", { status: 401 });
  }

  const today = new Date().toISOString().slice(0, 10);

  // Token usage (text/vision) across all users today.
  const { data: rows } = await admin
    .from("usage")
    .select("input_tokens, output_tokens")
    .eq("window_start", today);

  const totalTokens = (rows ?? []).reduce(
    (sum: number, r: { input_tokens: number; output_tokens: number }) =>
      sum + Number(r.input_tokens) + Number(r.output_tokens),
    0,
  );

  // Voice (Realtime audio) seconds + sessions across all users today. Priciest
  // COGS and not token-metered, so it's a separate limb of the alarm.
  const { data: vrows } = await admin
    .from("voice_usage")
    .select("seconds, sessions")
    .eq("window_start", today);

  const totalVoiceSeconds = (vrows ?? []).reduce(
    (sum: number, r: { seconds: number }) => sum + Number(r.seconds), 0,
  );
  const totalVoiceSessions = (vrows ?? []).reduce(
    (sum: number, r: { sessions: number }) => sum + Number(r.sessions), 0,
  );

  const tokensOver = TOKEN_THRESHOLD  >= 0 && totalTokens       >= TOKEN_THRESHOLD;
  const voiceOver  = VOICE_SEC_THRESH >= 0 && totalVoiceSeconds >= VOICE_SEC_THRESH;

  if (!tokensOver && !voiceOver) {
    return json({
      status: "ok",
      total_tokens: totalTokens, token_threshold: TOKEN_THRESHOLD,
      total_voice_seconds: totalVoiceSeconds, voice_seconds_threshold: VOICE_SEC_THRESH,
    });
  }

  // Cooldown — at most one page per 6h regardless of which limb tripped.
  const { data: lastAlert } = await admin
    .from("spend_alarm_log")
    .select("alerted_at")
    .order("alerted_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (lastAlert) {
    const elapsed = Date.now() - new Date(lastAlert.alerted_at).getTime();
    if (elapsed < COOLDOWN_MS) {
      return json({ status: "cooled_down", next_alert_in_ms: COOLDOWN_MS - elapsed });
    }
  }

  // Log the alert (total_tokens kept for backward compat; drives the cooldown).
  await admin.from("spend_alarm_log").insert({
    total_tokens: totalTokens,
    threshold: TOKEN_THRESHOLD,
  });

  const voiceMin = Math.round(totalVoiceSeconds / 60);
  const voiceMinThresh = Math.round(VOICE_SEC_THRESH / 60);
  const reasons: string[] = [];
  if (tokensOver) reasons.push(`${totalTokens.toLocaleString()} tokens ≥ ${TOKEN_THRESHOLD.toLocaleString()}`);
  if (voiceOver)  reasons.push(`${voiceMin.toLocaleString()} voice-min ≥ ${voiceMinThresh.toLocaleString()}`);

  // Send email via Resend
  const resendKey = Deno.env.get("RESEND_API_KEY");
  let emailStatus = "no_key";
  if (resendKey) {
    const resp = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${resendKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: "Mira Alerts <onboarding@resend.dev>",
        to: [ALERT_EMAIL],
        subject: `⚠️ Mira spend alert: ${reasons.join(" · ")}`,
        html: [
          `<p>Mira spend looks high today (${today}) across all users:</p>`,
          `<ul>`,
          `<li><strong>Tokens:</strong> ${totalTokens.toLocaleString()} (alarm ${TOKEN_THRESHOLD.toLocaleString()})${tokensOver ? " ⚠️" : ""}</li>`,
          `<li><strong>Voice:</strong> ${voiceMin.toLocaleString()} min across ${totalVoiceSessions.toLocaleString()} sessions (alarm ${voiceMinThresh.toLocaleString()} min)${voiceOver ? " ⚠️" : ""}</li>`,
          `</ul>`,
          `<p>Per-user breakdown:</p>`,
          `<pre>select user_id, provider, input_tokens, output_tokens\n`,
          `from usage where window_start = '${today}'\norder by (input_tokens+output_tokens) desc;\n\n`,
          `select user_id, sessions, seconds\n`,
          `from voice_usage where window_start = '${today}'\norder by seconds desc;</pre>`,
          `<p><small>Next alert in at least 6 hours.</small></p>`,
        ].join(""),
      }),
    });
    emailStatus = resp.ok ? "sent" : `resend_error_${resp.status}`;
  }

  return json({
    status: "alerted",
    reasons,
    total_tokens: totalTokens,
    total_voice_seconds: totalVoiceSeconds,
    total_voice_sessions: totalVoiceSessions,
    email: emailStatus,
  });
});
