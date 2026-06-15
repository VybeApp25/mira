// assemblyai-proxy — path-forwarding reverse proxy for AssemblyAI's REST API
// (file transcription: /v2/upload, /v2/transcript, /v2/transcript/:id). Unlike
// the single-endpoint anthropic/openai proxies, AssemblyAI hits several paths, so
// this forwards whatever /v2/* path the client appends. See
// docs/architecture/backend_secrets_proxy.md.
//
// Deploy:  supabase functions deploy assemblyai-proxy
// Secret:  supabase secrets set ASSEMBLYAI_API_KEY=…

import { CORS, json, requireUser, meter } from "../_shared/auth.ts";

const ASSEMBLYAI_API_KEY = Deno.env.get("ASSEMBLYAI_API_KEY");
const BASE = "https://api.assemblyai.com";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!ASSEMBLYAI_API_KEY)      return json({ error: "ASSEMBLYAI_API_KEY secret not set" }, 500);

  // Identity (also rejects anonymous callers). Transcription is billed by audio
  // minutes, not tokens, so we meter one request rather than token quota.
  let user;
  try { user = await requireUser(req); } catch (r) { return r as Response; }

  // Extract the AssemblyAI path the client appended after the function name.
  const url = new URL(req.url);
  const marker = "/assemblyai-proxy";
  const i = url.pathname.indexOf(marker);
  const subpath = i >= 0 ? url.pathname.slice(i + marker.length) : "";
  if (!subpath.startsWith("/v2/")) return json({ error: "path_not_allowed", path: subpath }, 400);

  const upstream = await fetch(BASE + subpath + url.search, {
    method: req.method,
    headers: {
      "Authorization": ASSEMBLYAI_API_KEY,            // AssemblyAI uses the raw key here
      "Content-Type": req.headers.get("content-type") ?? "application/json",
    },
    body: (req.method === "GET" || req.method === "HEAD") ? undefined : await req.arrayBuffer(),
  });

  meter(user.userId, "assemblyai", 0, 0); // request-level metering (token quota N/A)

  return new Response(upstream.body, {
    status: upstream.status,
    headers: { ...CORS, "Content-Type": upstream.headers.get("content-type") ?? "application/json" },
  });
});
