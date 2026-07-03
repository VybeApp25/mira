// spotify-config — returns the PUBLIC Spotify client ID so the desktop app can run
// the user-authorization PKCE flow client-side (favorite / add-to-playlist /
// follow-artist need a per-USER token, which Client Credentials can't grant).
//
// The client ID is not a secret — it appears in every OAuth authorize URL — so it
// is safe to hand to a signed-in Mira user. The client SECRET stays server-side
// (still used only by spotify-search). See docs/architecture/backend_secrets_proxy.md.
//
// Deploy:  supabase functions deploy spotify-config
// Secrets: reuses the existing SPOTIFY_CLIENT_ID secret (already set).
//
// Self-contained (no _shared import) so it deploys as a single file.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const CLIENT_ID = Deno.env.get("SPOTIFY_CLIENT_ID");
  if (!CLIENT_ID) return json({ error: "SPOTIFY_CLIENT_ID secret not set" }, 500);

  // Require a real, signed-in user so this isn't an open endpoint. Identity comes
  // from the verified token — never from anything the client sends in the body.
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!jwt) return json({ error: "unauthenticated" }, 401);
  const { data: { user }, error } = await admin.auth.getUser(jwt);
  if (error || !user) return json({ error: "unauthenticated" }, 401);

  return json({ client_id: CLIENT_ID });
});
