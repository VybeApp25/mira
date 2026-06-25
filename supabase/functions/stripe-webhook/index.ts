// stripe-webhook: handles Stripe lifecycle events and syncs profiles.plan.
// Deployed with --no-verify-jwt (Stripe has no Supabase JWT).
// Verify the Stripe-Signature header using STRIPE_WEBHOOK_SECRET instead.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { CORS } from "../_shared/auth.ts";

const STRIPE_SECRET          = Deno.env.get("STRIPE_SECRET_KEY")!;
const WEBHOOK_SECRET         = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;
const PRICE_PRO              = Deno.env.get("STRIPE_PRICE_PRO")!;
const PRICE_ULTRA            = Deno.env.get("STRIPE_PRICE_ULTRA")!;

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });

  const rawBody = await req.text();
  const sig     = req.headers.get("stripe-signature") ?? "";

  if (!(await verifySignature(rawBody, sig, WEBHOOK_SECRET))) {
    return new Response("Invalid signature", { status: 400 });
  }

  const event = JSON.parse(rawBody);

  try {
    switch (event.type) {
      case "checkout.session.completed":
        await handleCheckoutComplete(event.data.object);
        break;
      case "customer.subscription.updated":
        await handleSubscriptionUpdate(event.data.object);
        break;
      case "customer.subscription.deleted":
        await handleSubscriptionDeleted(event.data.object);
        break;
    }
  } catch (e) {
    console.error("webhook handler error:", e);
    return new Response("Handler error", { status: 500 });
  }

  return new Response("ok", { status: 200 });
});

// ── Handlers ────────────────────────────────────────────────────────────────

async function handleCheckoutComplete(session: Record<string, unknown>) {
  const userId       = session.client_reference_id as string;
  const meta         = session.metadata as Record<string, string>;
  const plan         = meta?.plan as "pro" | "ultra" ?? "pro";
  const customerId   = session.customer as string;
  const subId        = session.subscription as string;

  if (!userId) return;
  await admin.from("profiles").update({
    plan,
    stripe_customer_id:      customerId,
    stripe_subscription_id:  subId,
  }).eq("user_id", userId);
}

async function handleSubscriptionUpdate(sub: Record<string, unknown>) {
  const customerId = sub.customer as string;
  const status     = sub.status as string;

  // Map the active price to a plan name
  const items = (sub.items as { data: { price: { id: string } }[] }).data;
  const priceId = items?.[0]?.price?.id ?? "";
  let plan: string;
  if (priceId === PRICE_ULTRA)      plan = "ultra";
  else if (priceId === PRICE_PRO)   plan = "pro";
  else                              plan = "free";

  // Non-active statuses (past_due, canceled, unpaid) → downgrade
  if (!["active", "trialing"].includes(status)) plan = "free";

  await admin.from("profiles").update({ plan }).eq("stripe_customer_id", customerId);
}

async function handleSubscriptionDeleted(sub: Record<string, unknown>) {
  const customerId = sub.customer as string;
  await admin.from("profiles").update({ plan: "free" }).eq("stripe_customer_id", customerId);
}

// ── Stripe webhook signature verification ───────────────────────────────────

async function verifySignature(body: string, header: string, secret: string): Promise<boolean> {
  try {
    const parts = Object.fromEntries(
      header.split(",").map((p) => p.split("=") as [string, string])
    );
    const timestamp = parts["t"];
    const expected  = parts["v1"];
    if (!timestamp || !expected) return false;

    const payload = `${timestamp}.${body}`;
    const key = await crypto.subtle.importKey(
      "raw", new TextEncoder().encode(secret),
      { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
    );
    const mac  = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload));
    const hex  = Array.from(new Uint8Array(mac)).map((b) => b.toString(16).padStart(2, "0")).join("");
    return hex === expected;
  } catch {
    return false;
  }
}
