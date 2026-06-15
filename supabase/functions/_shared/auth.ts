// Shared auth + entitlement + quota middleware for Mira's proxy edge functions.
// See docs/architecture/backend_secrets_proxy.md.
//
// Pattern: each function calls `requireUser(req)` (verifies the caller's Supabase
// JWT and loads their plan), optionally `requireEntitlement`, then `checkQuota`
// before the provider call and `meter` after. Helpers throw a ready-to-return
// `Response` on failure, so call sites do `try { … } catch (r) { return r as Response }`.

import { createClient } from "jsr:@supabase/supabase-js@2";

export const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, anthropic-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export type Plan = "free" | "pro" | "ultra";

// Daily token budget (input + output) per plan, per provider. Tune freely — this
// is the server-side cost ceiling that a stolen session cannot exceed.
const DAILY_TOKEN_BUDGET: Record<Plan, number> = {
  free:    100_000,
  pro:   2_000_000,
  ultra: 10_000_000,
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// Service-role client — bypasses RLS to read plans and write usage. Never exposed
// to clients; the key lives only in the function's environment.
const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

export interface AuthedUser {
  userId: string;
  plan: Plan;
}

/** Verifies the caller's JWT and loads their plan. Throws a 401 Response if the
 *  token is missing/invalid. Identity comes from the verified token — never from
 *  anything the client sends in the body. */
export async function requireUser(req: Request): Promise<AuthedUser> {
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!jwt) throw json({ error: "unauthenticated" }, 401);

  const { data: { user }, error } = await admin.auth.getUser(jwt);
  if (error || !user) throw json({ error: "unauthenticated" }, 401);

  const { data: profile } = await admin
    .from("profiles").select("plan").eq("user_id", user.id).single();

  return { userId: user.id, plan: (profile?.plan ?? "free") as Plan };
}

/** Throws 402 if the user's plan isn't in `allowed`. */
export function requireEntitlement(plan: Plan, allowed: Plan[]): void {
  if (!allowed.includes(plan)) throw json({ error: "upgrade_required", plan }, 402);
}

/** Throws 429 if the user is already over today's budget for `provider`.
 *  Returns the remaining token budget. */
export async function checkQuota(userId: string, provider: string, plan: Plan): Promise<number> {
  const today = new Date().toISOString().slice(0, 10);
  const { data } = await admin
    .from("usage").select("input_tokens, output_tokens")
    .eq("user_id", userId).eq("provider", provider).eq("window_start", today)
    .maybeSingle();

  const used   = Number(data?.input_tokens ?? 0) + Number(data?.output_tokens ?? 0);
  const budget = DAILY_TOKEN_BUDGET[plan];
  if (used >= budget) throw json({ error: "quota_exceeded", used, budget }, 429);
  return budget - used;
}

/** Atomically records token usage (best-effort; never blocks the response). */
export async function meter(
  userId: string, provider: string, input: number, output: number,
): Promise<void> {
  try {
    await admin.rpc("add_usage", {
      p_user: userId, p_provider: provider, p_requests: 1,
      p_input: Math.max(0, Math.round(input)), p_output: Math.max(0, Math.round(output)),
    });
  } catch (_) { /* metering must never fail the user's request */ }
}
