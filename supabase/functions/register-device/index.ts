// Authenticated. Called after every successful sign-in / sign-up.
// Associates device_hash with the user's profile, or blocks if another
// free account already owns this device.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { CORS, json, requireUser } from "../_shared/auth.ts";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  let user: Awaited<ReturnType<typeof requireUser>>;
  try { user = await requireUser(req); }
  catch (r) { return r as Response; }

  const body = await req.json().catch(() => ({}));
  const deviceHash = body?.device_hash;
  if (!deviceHash || typeof deviceHash !== "string") {
    return json({ error: "device_hash required" }, 400);
  }

  // Load the user's current profile
  const { data: profile } = await admin
    .from("profiles")
    .select("device_id_hash, plan")
    .eq("user_id", user.userId)
    .single();

  // Already registered to this device — idempotent
  if (profile?.device_id_hash === deviceHash) {
    return json({ status: "ok" });
  }

  // Paid users can use any device — only enforce the lock for free plan
  if (user.plan !== "free") {
    await admin
      .from("profiles")
      .update({ device_id_hash: deviceHash, updated_at: new Date().toISOString() })
      .eq("user_id", user.userId);
    return json({ status: "ok" });
  }

  // Check whether another free account already owns this device
  const { count } = await admin
    .from("profiles")
    .select("user_id", { count: "exact", head: true })
    .eq("device_id_hash", deviceHash)
    .eq("plan", "free")
    .neq("user_id", user.userId);

  if ((count ?? 0) > 0) {
    return json({ error: "device_already_registered" }, 409);
  }

  await admin
    .from("profiles")
    .update({ device_id_hash: deviceHash, updated_at: new Date().toISOString() })
    .eq("user_id", user.userId);

  return json({ status: "ok" });
});
