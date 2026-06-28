import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { CORS, json, requireUser } from "../_shared/auth.ts";

const STRIPE_SECRET   = Deno.env.get("STRIPE_SECRET_KEY")!;
const PRICE_PRO       = Deno.env.get("STRIPE_PRICE_PRO")!;
const PRICE_ULTRA     = Deno.env.get("STRIPE_PRICE_ULTRA")!;

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  try {
    const user = await requireUser(req);
    const { plan } = await req.json() as { plan: "pro" | "ultra" };
    const priceId = plan === "ultra" ? PRICE_ULTRA : PRICE_PRO;

    const body = new URLSearchParams({
      "mode":                          "subscription",
      "payment_method_types[0]":       "card",
      "line_items[0][price]":          priceId,
      "line_items[0][quantity]":       "1",
      "client_reference_id":           user.userId,
      "metadata[plan]":                plan,
      "metadata[user_id]":             user.userId,
      "success_url":                   "https://getmira.today?upgrade=success",
      "cancel_url":                    "https://getmira.today?upgrade=cancelled",
      "allow_promotion_codes":         "true",
    });

    const res = await fetch("https://api.stripe.com/v1/checkout/sessions", {
      method: "POST",
      headers: {
        "Authorization":  `Bearer ${STRIPE_SECRET}`,
        "Content-Type":   "application/x-www-form-urlencoded",
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
