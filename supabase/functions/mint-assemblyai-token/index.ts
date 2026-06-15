// mint-assemblyai-token — mints a short-lived AssemblyAI streaming token so the
// raw key never reaches the client WebSocket. Requires a verified Supabase JWT.
// See docs/architecture/backend_secrets_proxy.md.
//
// Deploy:  supabase functions deploy mint-assemblyai-token
// Secret:  supabase secrets set ASSEMBLYAI_API_KEY=…

import { CORS, json, requireUser, meter } from "../_shared/auth.ts";

const ASSEMBLYAI_API_KEY = Deno.env.get("ASSEMBLYAI_API_KEY");

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!ASSEMBLYAI_API_KEY)      return json({ error: "ASSEMBLYAI_API_KEY secret not set" }, 500);

  let user;
  try { user = await requireUser(req); } catch (r) { return r as Response; }

  // v3 streaming temporary token (short-lived; used as a ?token= query param).
  const res = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=120",
    { headers: { "Authorization": ASSEMBLYAI_API_KEY } },
  );
  const payload = await res.json();
  if (!res.ok) return json({ error: payload }, res.status);

  meter(user.userId, "assemblyai-realtime", 0, 0);
  return json({ token: payload.token ?? "" });
});
