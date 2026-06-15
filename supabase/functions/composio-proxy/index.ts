// composio-proxy — transparent reverse-proxy for the Composio API so the secret
// COMPOSIO_API_KEY never ships in the client. Previously the key was compiled
// into the app binary (AppSecrets.composioAPIKey) and injected as an env var into
// the bundled Node agent sidecar — extractable from the shipped binary via
// `strings`. Now the sidecar points the Composio SDK's `baseURL` at this function
// and authorizes with the user's Supabase JWT; we verify the JWT, inject the real
// key server-side, and forward the (unchanged) request to backend.composio.dev.
// The Composio SDK builds request URLs by string-concatenating baseURL + path
// (@composio/client buildURL), so `${SUPABASE_URL}/functions/v1/composio-proxy`
// + `/api/v3/…` lands here and we strip the prefix to recover the upstream path.
// See docs/architecture/backend_secrets_proxy.md.
//
// Deploy:  supabase functions deploy composio-proxy
// Secret:  supabase secrets set COMPOSIO_API_KEY=ak_…

import { requireUser, meter } from "../_shared/auth.ts";

const COMPOSIO_API_KEY = Deno.env.get("COMPOSIO_API_KEY");
const COMPOSIO_BASE = "https://backend.composio.dev";
const PREFIX = "/composio-proxy";

// Composio is reached server-to-server from the Node sidecar (no browser), so
// CORS is moot here, but keep it permissive + method-agnostic for safety.
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-api-key, content-type, accept, user-agent",
  "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
};

function err(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!COMPOSIO_API_KEY)       return err({ error: "COMPOSIO_API_KEY secret not set" }, 500);

  // 1) Identity from the verified JWT — the sidecar sends it as Authorization:
  //    Bearer via the Composio SDK's defaultHeaders. Never trust the body.
  let user;
  try { user = await requireUser(req); } catch (r) { return r as Response; }

  // 2) Map /functions/v1/composio-proxy/<rest>?<query> → backend.composio.dev/<rest>?<query>
  const inUrl = new URL(req.url);
  const idx = inUrl.pathname.indexOf(PREFIX);
  const upstreamPath = idx >= 0 ? inUrl.pathname.slice(idx + PREFIX.length) : inUrl.pathname;
  const upstream = `${COMPOSIO_BASE}${upstreamPath}${inUrl.search}`;

  // 3) Forward headers verbatim except: drop our JWT (not for Composio) and the
  //    inbound host, and inject the real server-held key.
  const headers = new Headers(req.headers);
  headers.delete("authorization");
  headers.delete("host");
  headers.set("x-api-key", COMPOSIO_API_KEY);

  const hasBody = req.method !== "GET" && req.method !== "HEAD";
  const resp = await fetch(upstream, {
    method: req.method,
    headers,
    body: hasBody ? await req.arrayBuffer() : undefined,
  });

  // 4) Best-effort request metering (Composio has no token concept; meter counts
  //    one request). Never block the response on metering.
  await meter(user.userId, "composio", 0, 0);

  // 5) Stream the response back. Deno's fetch already decompressed the body, so
  //    drop the now-stale content-encoding/length to stop the client re-decoding.
  const respHeaders = new Headers(resp.headers);
  respHeaders.set("Access-Control-Allow-Origin", "*");
  respHeaders.delete("content-encoding");
  respHeaders.delete("content-length");
  return new Response(resp.body, { status: resp.status, headers: respHeaders });
});
