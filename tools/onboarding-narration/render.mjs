#!/usr/bin/env node
// render.mjs — (re)generate the bundled Marin onboarding narration clips.
//
// Why this exists: the gpt-4o-mini-tts /audio/speech endpoint has no "marin"
// voice (marin is Realtime-only), so Mira's live onboarding narration fell back
// to the flat macOS system voice. We instead pre-bake every onboarding line in
// true Marin via the GA Realtime API and bundle the mp3s; OnboardingNarrator
// prefers the bundled clip whenever one exists.
//
// The lines are parsed directly out of NotchOnboardingManager.swift — that file
// is the single source of truth, so the generated filenames always match the
// runtime lookup (djb2(text + "marin"), base-36).
//
// Rendering runs through the maintainer-only `render-onboarding-marin` edge
// function so OPENAI_API_KEY stays inside Supabase. You authenticate to it with
// the RENDER_TOOL_SECRET (a dedicated secret set via `supabase secrets set`).
//
// Usage:
//   RENDER_TOOL_SECRET=... node tools/onboarding-narration/render.mjs --check
//       Parse lines, compute hashes, and report which clips exist / are missing.
//       No network, no secret required.
//
//   RENDER_TOOL_SECRET=... node tools/onboarding-narration/render.mjs --all
//       Render every line (fresh Marin takes) and overwrite the bundled mp3s.
//
//   RENDER_TOOL_SECRET=... node tools/onboarding-narration/render.mjs --only 3,7
//       Render just the given lines (1-based indices from --check) or hashes.
//
//   ... --missing        Render only the lines whose mp3 is not yet bundled.
//
// Requires: node 18+, ffmpeg on PATH.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve, join } from "node:path";

const HERE      = dirname(fileURLToPath(import.meta.url));
const REPO      = resolve(HERE, "..", "..");
const SWIFT     = join(REPO, "Mira", "Services", "NotchOnboardingManager.swift");
const OUT_DIR   = join(REPO, "Mira", "Resources", "OnboardingNarration");
const REF_FILE  = join(REPO, "supabase", ".temp", "project-ref");
const VOICE     = "marin";

// ── args ─────────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const has  = (f) => args.includes(f);
const valOf = (f) => { const i = args.indexOf(f); return i >= 0 ? args[i + 1] : undefined; };
const mode =
  has("--all")     ? "all"     :
  has("--missing") ? "missing" :
  has("--only")    ? "only"    :
  "check";
const onlySel = (valOf("--only") ?? "").split(",").map((s) => s.trim()).filter(Boolean);

// ── djb2(text + voice), base-36 — MUST match OnboardingNarrator.bundledNarrationURL ──
function clipHash(text) {
  const MASK = (1n << 64n) - 1n;
  let h = 5381n;
  for (const byte of Buffer.from(text + VOICE, "utf8")) {
    h = (h * 33n + BigInt(byte)) & MASK;
  }
  return h.toString(36);
}

// ── extract the narration lines from the Swift source ────────────────────────
function extractLines() {
  const src = readFileSync(SWIFT, "utf8");
  const re = /speakAndWait\("((?:[^"\\]|\\.)*)"\)/g;
  const seen = new Set();
  const lines = [];
  let m;
  while ((m = re.exec(src)) !== null) {
    // Un-escape the handful of Swift string escapes we might hit.
    const text = m[1]
      .replace(/\\"/g, '"').replace(/\\n/g, "\n")
      .replace(/\\t/g, "\t").replace(/\\\\/g, "\\");
    if (seen.has(text)) continue;
    seen.add(text);
    lines.push(text);
  }
  return lines;
}

// ── QA: does the model's transcript match the source, ignoring punctuation? ──
function normalize(s) {
  return s.toLowerCase()
    .replace(/[‐-―]/g, "-")   // various dashes → hyphen
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ").trim();
}

async function renderLine(text, endpoint, key) {
  const res = await fetch(endpoint, {
    method: "POST",
    headers: { "Authorization": `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ text, voice: VOICE }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${JSON.stringify(data)}`);
  if (!data.audioBase64) throw new Error(`no audio in response: ${JSON.stringify(data)}`);
  return { wav: Buffer.from(data.audioBase64, "base64"), transcript: data.transcript ?? "" };
}

function wavToMp3(wav, mp3Path) {
  const tmp = mp3Path + ".tmp.wav";
  writeFileSync(tmp, wav);
  try {
    execFileSync("ffmpeg", ["-y", "-i", tmp, "-codec:a", "libmp3lame", "-qscale:a", "2", mp3Path],
      { stdio: "ignore" });
  } finally { rmSync(tmp, { force: true }); }
}

// ── main ─────────────────────────────────────────────────────────────────────
const lines = extractLines();
if (lines.length === 0) { console.error(`No speakAndWait lines found in ${SWIFT}`); process.exit(1); }

const rows = lines.map((text, i) => {
  const hash = clipHash(text);
  const file = `narration-${hash}.mp3`;
  return { i: i + 1, text, hash, file, path: join(OUT_DIR, file), exists: existsSync(join(OUT_DIR, file)) };
});

if (mode === "check") {
  console.log(`Onboarding narration — ${rows.length} lines (voice: ${VOICE})\n`);
  for (const r of rows) {
    const flag = r.exists ? "✓" : "✗ MISSING";
    console.log(`${String(r.i).padStart(2)}. [${flag}] ${r.file}`);
    console.log(`    ${r.text.length > 90 ? r.text.slice(0, 90) + "…" : r.text}`);
  }
  const missing = rows.filter((r) => !r.exists).length;
  console.log(`\n${rows.length - missing}/${rows.length} bundled${missing ? `, ${missing} missing` : " — all present"}.`);
  process.exit(missing ? 1 : 0);
}

// Rendering modes need the endpoint + render secret.
const KEY = process.env.RENDER_TOOL_SECRET;
if (!KEY) { console.error("RENDER_TOOL_SECRET is required to render. (Use --check for a dry run.)"); process.exit(1); }
if (!existsSync(REF_FILE)) { console.error(`Missing ${REF_FILE} — run \`supabase link\` first.`); process.exit(1); }
const REF = readFileSync(REF_FILE, "utf8").trim();
const ENDPOINT = `https://${REF}.supabase.co/functions/v1/render-onboarding-marin`;

let targets = rows;
if (mode === "missing") targets = rows.filter((r) => !r.exists);
if (mode === "only") {
  const want = new Set(onlySel);
  targets = rows.filter((r) => want.has(String(r.i)) || want.has(r.hash));
  if (targets.length === 0) { console.error(`--only matched nothing. Selectors: ${onlySel.join(", ")}`); process.exit(1); }
}

if (!existsSync(OUT_DIR)) mkdirSync(OUT_DIR, { recursive: true });
console.log(`Rendering ${targets.length} line(s) via ${ENDPOINT}\n`);

let failures = 0;
for (const r of targets) {
  process.stdout.write(`${String(r.i).padStart(2)}. ${r.file} … `);
  try {
    const { wav, transcript } = await renderLine(r.text, ENDPOINT, KEY);
    wavToMp3(wav, r.path);
    const ok = normalize(transcript) === normalize(r.text);
    if (ok) {
      console.log("rendered ✓");
    } else {
      failures++;
      console.log("rendered ⚠ QA MISMATCH");
      console.log(`    wanted: ${r.text}`);
      console.log(`    heard : ${transcript}`);
    }
  } catch (e) {
    failures++;
    console.log(`FAILED — ${e.message}`);
  }
}

console.log(`\nDone. ${targets.length - failures}/${targets.length} clean.`);
if (failures) { console.log("Re-run failed/mismatched lines with --only <indices>."); process.exit(1); }
