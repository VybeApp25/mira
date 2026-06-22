// spotify-search — resolves a free-text query (track + artist, any order) to a
// playable Spotify track URI using the Spotify Web API Client Credentials flow.
// The client then hands the URI to the LOCAL Spotify app via AppleScript
// (`play track "spotify:track:…"`), which plays instantly and reliably — no UI
// keyboard automation, word-order independent. See docs/architecture/backend_secrets_proxy.md.
//
// Client Credentials only grants catalog/search access (no user playback scope),
// which is all we need: search here, play locally. Requires a signed-in Mira user.
//
// Deploy:  supabase functions deploy spotify-search
// Secrets: supabase secrets set SPOTIFY_CLIENT_ID=… SPOTIFY_CLIENT_SECRET=…

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { CORS, json, requireUser, requireEntitlement, meter } from "../_shared/auth.ts";

interface SpotifyTrack {
  uri: string;
  name: string;
  artists: { name: string }[];
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const CLIENT_ID = Deno.env.get("SPOTIFY_CLIENT_ID");
  const CLIENT_SECRET = Deno.env.get("SPOTIFY_CLIENT_SECRET");
  if (!CLIENT_ID || !CLIENT_SECRET) {
    return json({ error: "SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET secret not set" }, 500);
  }

  // Real, signed-in user — keeps the search endpoint from being open to anyone
  // with the public anon key. Music is free-tier, so every plan is allowed.
  let user;
  try {
    user = await requireUser(req);
    requireEntitlement(user.plan, ["free", "pro", "ultra"]);
  } catch (r) { return r as Response; }

  let query = "";
  let track = "";
  let artist = "";
  try {
    const body = await req.json();
    query = (body.query ?? "").toString().trim();
    track = (body.track ?? "").toString().trim();
    artist = (body.artist ?? "").toString().trim();
  } catch (_) { /* validated below */ }

  // Build a search query. If the caller split track/artist, use Spotify's field
  // filters for a precise match; otherwise fall back to the free-text query
  // (Spotify's search is order-independent either way).
  let q = query;
  if (track && artist) q = `track:${track} artist:${artist}`;
  else if (track)      q = track;
  else if (artist)     q = artist;
  if (!q) return json({ error: "missing query" }, 400);

  // 1) App access token (Client Credentials).
  const tokenRes = await fetch("https://accounts.spotify.com/api/token", {
    method: "POST",
    headers: {
      "Authorization": `Basic ${btoa(`${CLIENT_ID}:${CLIENT_SECRET}`)}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials",
  });
  if (!tokenRes.ok) {
    return json({ error: "spotify_token_failed", status: tokenRes.status }, 502);
  }
  const { access_token } = await tokenRes.json();

  // 2) Search tracks, take the top result.
  const searchURL = `https://api.spotify.com/v1/search?type=track&limit=1&q=${encodeURIComponent(q)}`;
  const searchRes = await fetch(searchURL, {
    headers: { "Authorization": `Bearer ${access_token}` },
  });
  if (!searchRes.ok) {
    return json({ error: "spotify_search_failed", status: searchRes.status }, 502);
  }
  const data = await searchRes.json();
  const top: SpotifyTrack | undefined = data?.tracks?.items?.[0];

  meter(user.userId, "spotify-search", 0, 0);

  if (!top?.uri) return json({ error: "no_match", query: q }, 404);

  return json({
    uri: top.uri,                                    // spotify:track:…
    name: top.name,
    artist: top.artists?.map((a) => a.name).join(", ") ?? "",
  });
});
