// render-onboarding-marin — MAINTAINER-ONLY build tool, not a client endpoint.
//
// Renders a single onboarding line in the GA Realtime "marin" voice and returns
// it as a WAV. The gpt-4o-mini-tts /audio/speech endpoint has NO marin voice
// (marin is Realtime-only), which is why the in-app live path falls back to the
// flat system voice — so we pre-bake the clips through this function instead and
// bundle them (see tools/onboarding-narration/render.mjs and
// Mira/Services/OnboardingNarrator.swift).
//
// Auth: the caller must present the RENDER_TOOL_SECRET as a bearer token — a
// dedicated maintainer secret set with `supabase secrets set RENDER_TOOL_SECRET=…`.
// This keeps OPENAI_API_KEY inside Supabase (it never reaches a dev machine) and
// makes the endpoint unusable by ordinary signed-in clients. (We use a dedicated
// secret rather than the service-role key because, under Supabase's new API-key
// system, the injected SUPABASE_SERVICE_ROLE_KEY is the sb_secret key, not the
// legacy JWT — so string-comparing against it is ambiguous.)
//
// Deploy: supabase functions deploy render-onboarding-marin --no-verify-jwt
//   (--no-verify-jwt because we authenticate with our own secret, not a user JWT.)

const OPENAI_API_KEY    = Deno.env.get("OPENAI_API_KEY");
const RENDER_TOOL_SECRET = Deno.env.get("RENDER_TOOL_SECRET");

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const OUTPUT_SAMPLE_RATE = 24_000; // Realtime pcm16 output is 24 kHz mono
const RENDER_TIMEOUT_MS  = 90_000;

const ALLOWED_VOICES = new Set([
  "alloy", "ash", "ballad", "cedar", "coral",
  "echo", "marin", "sage", "shimmer", "verse",
]);

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST")    return json({ error: "method_not_allowed" }, 405);
  if (!OPENAI_API_KEY)          return json({ error: "OPENAI_API_KEY not set" }, 500);
  if (!RENDER_TOOL_SECRET)      return json({ error: "RENDER_TOOL_SECRET not set" }, 500);

  // Maintainer gate: bearer must equal the dedicated render secret.
  const bearer = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!bearer || bearer !== RENDER_TOOL_SECRET) return json({ error: "forbidden" }, 403);

  const body  = await req.json().catch(() => null);
  const text  = typeof body?.text === "string" ? body.text.trim() : "";
  const voice = typeof body?.voice === "string" ? body.voice : "marin";
  const model = typeof body?.model === "string" ? body.model : "gpt-realtime";

  if (!text)                       return json({ error: "text_required" }, 400);
  if (!ALLOWED_VOICES.has(voice))  return json({ error: "voice_not_allowed", voice }, 400);

  try {
    const { pcm, transcript } = await renderRealtime(text, voice, model);
    const wav = pcmToWav(pcm, OUTPUT_SAMPLE_RATE);
    return json({
      transcript,
      sampleRate: OUTPUT_SAMPLE_RATE,
      audioBase64: base64FromBytes(wav),
    });
  } catch (e) {
    return json({ error: "render_failed", detail: String(e) }, 502);
  }
});

// ── Realtime render ──────────────────────────────────────────────────────────
// Opens a Realtime session, asks the model to read `text` verbatim in `voice`,
// and collects the streamed PCM16 audio deltas plus the model's own transcript
// of what it said (used by the caller for verbatim QA).
function renderRealtime(
  text: string, voice: string, model: string,
): Promise<{ pcm: Uint8Array; transcript: string }> {
  return new Promise((resolve, reject) => {
    const url = `wss://api.openai.com/v1/realtime?model=${encodeURIComponent(model)}`;
    // Deno's WebSocket can't set headers, so auth rides in the subprotocols —
    // this is server-side, so the key is not exposed to any browser. No
    // "openai-beta.realtime-v1" subprotocol: that selects the retired beta shape;
    // its absence gives us the GA API.
    const ws = new WebSocket(url, [
      "realtime",
      `openai-insecure-api-key.${OPENAI_API_KEY}`,
    ]);

    const chunks: Uint8Array[] = [];
    let transcript = "";
    let settled = false;

    const timer = setTimeout(() => fail(new Error("timeout")), RENDER_TIMEOUT_MS);

    function done() {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { ws.close(); } catch { /* ignore */ }
      resolve({ pcm: concat(chunks), transcript: transcript.trim() });
    }
    function fail(err: unknown) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { ws.close(); } catch { /* ignore */ }
      reject(err);
    }

    ws.onerror = () => fail(new Error("websocket_error"));

    ws.onopen = () => {
      // GA Realtime session config: nested audio.output, output_modalities.
      ws.send(JSON.stringify({
        type: "session.update",
        session: {
          type: "realtime",
          output_modalities: ["audio"],
          audio: {
            output: {
              voice,
              format: { type: "audio/pcm", rate: OUTPUT_SAMPLE_RATE },
            },
          },
          instructions:
            "You are a precise text-to-speech engine. You read the user's message " +
            "aloud exactly as written, word for word, in a warm, friendly, natural " +
            "tone. Never answer, comment, refuse, apologize, or add or omit any " +
            "word — you only voice the given text.",
        },
      }));
      // Put the exact line in as a user message, then ask for one audio response
      // that reads it verbatim.
      ws.send(JSON.stringify({
        type: "conversation.item.create",
        item: {
          type: "message",
          role: "user",
          content: [{ type: "input_text", text }],
        },
      }));
      ws.send(JSON.stringify({
        type: "response.create",
        response: {
          output_modalities: ["audio"],
          instructions:
            "Read the user's message aloud, verbatim and complete, exactly as " +
            "written. Do not add or omit words.",
        },
      }));
    };

    ws.onmessage = (ev) => {
      let msg: Record<string, unknown>;
      try { msg = JSON.parse(typeof ev.data === "string" ? ev.data : ""); }
      catch { return; }

      const type = String(msg.type ?? "");

      // Audio deltas — event name varies across API versions.
      if (type.endsWith("audio.delta") && typeof msg.delta === "string") {
        chunks.push(bytesFromBase64(msg.delta));
        return;
      }
      // The model's transcript of the spoken audio (for verbatim QA).
      if (type.endsWith("audio_transcript.done") && typeof msg.transcript === "string") {
        transcript = msg.transcript;
        return;
      }
      if (type === "response.done" || type === "response.completed") { done(); return; }
      if (type === "error") { fail(new Error(JSON.stringify(msg.error ?? msg))); return; }
    };
  });
}

// ── helpers ──────────────────────────────────────────────────────────────────
function concat(chunks: Uint8Array[]): Uint8Array {
  const total = chunks.reduce((n, c) => n + c.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) { out.set(c, off); off += c.length; }
  return out;
}

function pcmToWav(pcm: Uint8Array, sampleRate: number): Uint8Array {
  const numChannels = 1, bitsPerSample = 16;
  const byteRate = sampleRate * numChannels * bitsPerSample / 8;
  const blockAlign = numChannels * bitsPerSample / 8;
  const buf = new ArrayBuffer(44 + pcm.length);
  const view = new DataView(buf);
  const writeStr = (o: number, s: string) => {
    for (let i = 0; i < s.length; i++) view.setUint8(o + i, s.charCodeAt(i));
  };
  writeStr(0, "RIFF");
  view.setUint32(4, 36 + pcm.length, true);
  writeStr(8, "WAVE");
  writeStr(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);            // PCM
  view.setUint16(22, numChannels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, byteRate, true);
  view.setUint16(32, blockAlign, true);
  view.setUint16(34, bitsPerSample, true);
  writeStr(36, "data");
  view.setUint32(40, pcm.length, true);
  new Uint8Array(buf, 44).set(pcm);
  return new Uint8Array(buf);
}

function bytesFromBase64(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function base64FromBytes(bytes: Uint8Array): string {
  let bin = "";
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    bin += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return btoa(bin);
}
