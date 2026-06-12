import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS });
  }

  const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");
  if (!OPENAI_API_KEY) {
    return new Response(
      JSON.stringify({ error: "OPENAI_API_KEY secret not set" }),
      { status: 500, headers: { ...CORS, "Content-Type": "application/json" } }
    );
  }

  let voice = "alloy";
  try {
    const body = await req.json();
    if (body.voice) voice = body.voice;
  } catch (_) { /* no body is fine */ }

  const model = "gpt-realtime";

  // GA endpoint — /v1/realtime/sessions (beta) was retired with the
  // gpt-4o-realtime-preview models. Response shape: { value, expires_at, session }.
  const openaiRes = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      session: {
        type: "realtime",
        model,
        audio: { output: { voice } },
      },
    }),
  });

  const payload = await openaiRes.json();

  if (!openaiRes.ok) {
    return new Response(JSON.stringify({ error: payload }), {
      status: openaiRes.status,
      headers: { ...CORS, "Content-Type": "application/json" },
    });
  }

  const token  = payload.value ?? "";
  const expiry = payload.expires_at ?? 0;

  return new Response(
    JSON.stringify({ token, expires_at: expiry, model }),
    { headers: { ...CORS, "Content-Type": "application/json" } }
  );
});
