// skills-catalog (Gap B Phase 3): public read of the APPROVED community skills.
// Optional ?q= filters by name/tagline. Deployed --no-verify-jwt — it only ever
// returns already-approved, public rows. Self-contained (no _shared import) so
// repo == deployment. See docs/specs/community-skills-moderation.md.

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const url = new URL(req.url);
  const q = (url.searchParams.get("q") ?? "").trim();

  let query = admin
    .from("community_skills")
    .select("slug,name,tagline,category,icon,body,author_handle,downloads,created_at")
    .eq("status", "approved")
    .order("downloads", { ascending: false })
    .limit(200);

  if (q) query = query.or(`name.ilike.%${q}%,tagline.ilike.%${q}%`);

  const { data, error } = await query;
  if (error) return json({ error: "query_failed", detail: error.message }, 500);
  return json({ skills: data ?? [] });
});
