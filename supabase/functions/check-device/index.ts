// Public endpoint — no auth required.
// Lets the client check whether a device_hash already has a free account
// BEFORE creating a new account, so we never create orphan users.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { CORS, json } from "../_shared/auth.ts";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const body = await req.json().catch(() => ({}));
  const deviceHash = body?.device_hash;
  if (!deviceHash || typeof deviceHash !== "string") {
    return json({ error: "device_hash required" }, 400);
  }

  const { count, error } = await admin
    .from("profiles")
    .select("user_id", { count: "exact", head: true })
    .eq("device_id_hash", deviceHash)
    .eq("plan", "free");

  if (error) return json({ error: "db_error" }, 500);
  return json({ available: (count ?? 0) === 0 });
});
