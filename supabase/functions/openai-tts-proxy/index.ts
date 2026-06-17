// openai-tts-proxy — reverse-proxies OpenAI /v1/audio/speech so the secret key
// never ships in the client. Used to generate the in-app voice previews: every
// voice speaks the SAME line so previews are directly comparable.
//
// The client sends only { voice }. The phrase + model are fixed server-side so
// the preview is identical for everyone and the endpoint can't be abused as a
// general-purpose TTS sink.
//
// Deploy:  supabase functions deploy openai-tts-proxy
// Secret:  OPENAI_API_KEY (shared with openai-proxy — already set)

import { CORS, json, requireUser, requireEntitlement, checkQuota, meter } from "../_shared/auth.ts";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");

// gpt-4o-mini-tts is the only TTS model that supports all of Mira's realtime
// voices (including marin + cedar).
const TTS_MODEL = "gpt-4o-mini-tts";

// The single shared preview line — same for every voice, every user.
const PREVIEW_PHRASE = "Hi, I'm Mira, your AI companion. How can I help you today?";

// Mira's realtime voice catalog — mirrors MiraVoice in the client.
const ALLOWED_VOICES = new Set([
  "alloy", "ash", "ballad", "cedar", "coral",
  "echo", "marin", "sage", "shimmer", "verse",
]);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST")    return json({ error: "method_not_allowed" }, 405);
  if (!OPENAI_API_KEY)          return json({ error: "OPENAI_API_KEY secret not set" }, 500);

  let user;
  try { user = await requireUser(req); } catch (r) { return r as Response; }

  try {
    requireEntitlement(user.plan, ["free", "pro", "ultra"]);
    await checkQuota(user.userId, "openai", user.plan);
  } catch (r) { return r as Response; }

  const body = await req.json().catch(() => null);
  const voice = body && typeof body.voice === "string" ? body.voice : "";
  if (!ALLOWED_VOICES.has(voice)) return json({ error: "voice_not_allowed", voice }, 400);

  const upstream = await fetch("https://api.openai.com/v1/audio/speech", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: TTS_MODEL,
      voice,
      input: PREVIEW_PHRASE,
      response_format: "mp3",
    }),
  });

  if (!upstream.ok) {
    const text = await upstream.text();
    return new Response(text, {
      status: upstream.status,
      headers: { ...CORS, "Content-Type": "application/json" },
    });
  }

  // Flat meter: the phrase is a known, tiny, fixed cost. Charge a small allowance
  // against the OpenAI bucket so previews still count toward the daily ceiling.
  meter(user.userId, "openai", PREVIEW_PHRASE.length, 0);

  const audio = await upstream.arrayBuffer();
  return new Response(audio, {
    status: 200,
    headers: { ...CORS, "Content-Type": "audio/mpeg", "Cache-Control": "no-store" },
  });
});
