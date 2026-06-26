// Called hourly by pg_cron via pg_net.
// Sums today's aggregate token usage across all users and sends an email
// alert via Resend if it exceeds SPEND_ALARM_TOKENS (default 2 000 000).
// A 6-hour cooldown prevents repeat paging.
//
// Secrets required:
//   CRON_SECRET          — shared secret validated in x-cron-secret header
//   RESEND_API_KEY       — from resend.com (free tier is fine for alerts)
//   SPEND_ALARM_TOKENS   — optional override, default 2000000
//   SPEND_ALARM_EMAIL    — optional override, default trevonbarbour@gmail.com

import { createClient } from "jsr:@supabase/supabase-js@2";
import { CORS, json } from "../_shared/auth.ts";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const THRESHOLD    = parseInt(Deno.env.get("SPEND_ALARM_TOKENS") ?? "2000000");
const ALERT_EMAIL  = Deno.env.get("SPEND_ALARM_EMAIL") ?? "trevonbarbour@gmail.com";
const COOLDOWN_MS  = 6 * 60 * 60 * 1000;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  // Validate cron secret so random callers can't spam the alarm log
  const cronSecret = Deno.env.get("CRON_SECRET");
  if (cronSecret && req.headers.get("x-cron-secret") !== cronSecret) {
    return new Response("Unauthorized", { status: 401 });
  }

  // Sum today's tokens across all users and providers
  const today = new Date().toISOString().slice(0, 10);
  const { data: rows } = await admin
    .from("usage")
    .select("input_tokens, output_tokens")
    .eq("window_start", today);

  const totalTokens = (rows ?? []).reduce(
    (sum: number, r: { input_tokens: number; output_tokens: number }) =>
      sum + Number(r.input_tokens) + Number(r.output_tokens),
    0,
  );

  if (totalTokens < THRESHOLD) {
    return json({ status: "ok", total_tokens: totalTokens, threshold: THRESHOLD });
  }

  // Cooldown check — don't send more than once per 6 hours
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

  // Log the alert
  await admin.from("spend_alarm_log").insert({
    total_tokens: totalTokens,
    threshold: THRESHOLD,
  });

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
        subject: `⚠️ Mira spend alert: ${(totalTokens / 1_000_000).toFixed(1)}M tokens today`,
        html: [
          `<p>Mira used <strong>${totalTokens.toLocaleString()} tokens</strong> today across all users.</p>`,
          `<p>Alarm threshold: ${THRESHOLD.toLocaleString()} tokens/day.</p>`,
          `<p>Check the <a href="https://supabase.com/dashboard/project/rdbljrbjsmbfqwwpwwvn/editor">`,
          `Supabase SQL Editor</a> for a per-user breakdown:</p>`,
          `<pre>select user_id, provider, input_tokens, output_tokens\n`,
          `from usage where window_start = '${today}'\norder by (input_tokens+output_tokens) desc;</pre>`,
          `<p><small>Next alert in at least 6 hours.</small></p>`,
        ].join(""),
      }),
    });
    emailStatus = resp.ok ? "sent" : `resend_error_${resp.status}`;
  }

  return json({ status: "alerted", total_tokens: totalTokens, email: emailStatus });
});
