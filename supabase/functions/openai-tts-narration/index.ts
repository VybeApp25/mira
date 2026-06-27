// openai-tts-narration — general-purpose TTS for in-app narration (onboarding, etc.)
// Unlike openai-tts-proxy (which always plays the fixed preview phrase), this
// endpoint speaks whatever `input` text the client sends. Requires sign-in and
// caps text at 600 chars per call to prevent abuse.
//
// Deploy: supabase functions deploy openai-tts-narration

import { CORS, json, requireUser } from "../_shared/auth.ts";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");
const MAX_CHARS = 600;

const ALLOWED_VOICES = new Set([
  "alloy", "ash", "ballad", "cedar", "coral",
  "echo", "marin", "sage", "shimmer", "verse",
]);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST")    return json({ error: "method_not_allowed" }, 405);
  if (!OPENAI_API_KEY)          return json({ error: "OPENAI_API_KEY not set" }, 500);

  let user;
  try { user = await requireUser(req); } catch (r) { return r as Response; }

  const body  = await req.json().catch(() => null);
  const voice = typeof body?.voice === "string" ? body.voice : "marin";
  const input = typeof body?.input === "string" ? body.input.trim() : "";

  if (!ALLOWED_VOICES.has(voice)) return json({ error: "voice_not_allowed", voice }, 400);
  if (!input)                      return json({ error: "input_required" }, 400);
  if (input.length > MAX_CHARS)    return json({ error: "input_too_long", max: MAX_CHARS }, 400);

  const upstream = await fetch("https://api.openai.com/v1/audio/speech", {
    method:  "POST",
    headers: {
      "Authorization": `Bearer ${OPENAI_API_KEY}`,
      "Content-Type":  "application/json",
    },
    body: JSON.stringify({
      model:           "gpt-4o-mini-tts",
      voice,
      input,
      response_format: "mp3",
    }),
  });

  if (!upstream.ok) {
    const text = await upstream.text();
    return new Response(text, {
      status:  upstream.status,
      headers: { ...CORS, "Content-Type": "application/json" },
    });
  }

  const audio = await upstream.arrayBuffer();
  return new Response(audio, {
    status:  200,
    headers: { ...CORS, "Content-Type": "audio/mpeg", "Cache-Control": "no-store" },
  });
});
