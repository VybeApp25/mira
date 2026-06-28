// stripe-portal — creates a Stripe Billing Portal session so a paid user can
// manage or cancel their subscription in-app. Authenticated: identity comes
// from the verified Supabase JWT; the Stripe customer id is looked up from the
// user's own profile (never trusted from the client).
//
// Deploy:  supabase functions deploy stripe-portal
// Secret:  STRIPE_SECRET_KEY (already set for stripe-checkout)

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { CORS, json, requireUser } from "../_shared/auth.ts";

const STRIPE_SECRET = Deno.env.get("STRIPE_SECRET_KEY")!;
const RETURN_URL    = Deno.env.get("STRIPE_PORTAL_RETURN_URL") ?? "https://miraapp.ai";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  try {
    const user = await requireUser(req);

    // Look up the Stripe customer id from the user's profile (set by the webhook
    // on first checkout). No customer = nothing to manage yet.
    const { data: profile } = await admin
      .from("profiles").select("stripe_customer_id").eq("user_id", user.userId).single();
    const customerId = profile?.stripe_customer_id as string | undefined;
    if (!customerId) return json({ error: "no_subscription" }, 400);

    const body = new URLSearchParams({
      "customer":   customerId,
      "return_url": RETURN_URL,
    });

    const res = await fetch("https://api.stripe.com/v1/billing_portal/sessions", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${STRIPE_SECRET}`,
        "Content-Type":  "application/x-www-form-urlencoded",
      },
      body,
    });
    const session = await res.json();
    if (!res.ok) return json({ error: session.error?.message ?? "stripe_error" }, 400);
    return json({ url: session.url });
  } catch (r) {
    if (r instanceof Response) return r;
    return json({ error: String(r) }, 500);
  }
});
