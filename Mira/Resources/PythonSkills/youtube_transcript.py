#!/usr/bin/env python3
"""Fetch a YouTube video transcript.
Args JSON (stdin): {url, languages?}
  url — YouTube URL (watch?v=ID, youtu.be/ID, embed/ID, shorts/ID) or bare video ID
  languages — optional list like ["en", "en-US"] (default: ["en"])
Output JSON (stdout): {success, video_id, text, segments, error?}

Version-tolerant: works with youtube-transcript-api 1.x (instance .fetch/.list,
snippet objects with a .text attribute) AND legacy 0.6.x (static get_transcript,
list of dicts). The library dropped the static methods in 1.0, so pinning to one
shape breaks whenever pip resolves the other.
"""
import sys, json, re

def extract_id(url_or_id: str) -> str:
    m = re.search(r"(?:v=|youtu\.be/|embed/|shorts/)([A-Za-z0-9_-]{11})", url_or_id)
    return m.group(1) if m else url_or_id.strip()

def snippet_text(s) -> str:
    # 1.x snippets are objects with `.text`; 0.6.x are dicts with ["text"].
    if isinstance(s, dict):
        return s.get("text", "") or ""
    return getattr(s, "text", "") or ""

def get_snippets(video_id, languages):
    from youtube_transcript_api import YouTubeTranscriptApi
    # Legacy static API (<= 0.6.x).
    if hasattr(YouTubeTranscriptApi, "get_transcript"):
        return YouTubeTranscriptApi.get_transcript(video_id, languages=languages)
    # Modern instance API (>= 1.0).
    api = YouTubeTranscriptApi()
    try:
        return list(api.fetch(video_id, languages=languages))
    except Exception:
        # Fall back to any available transcript (manual first, then generated).
        tlist = api.list(video_id)
        try:
            tr = tlist.find_transcript(languages)
        except Exception:
            tr = tlist.find_generated_transcript(["en", "en-US", "en-GB"])
        return list(tr.fetch())

def main():
    try:
        args = json.load(sys.stdin)
    except Exception:
        args = {}
    url       = args.get("url", "")
    languages = args.get("languages", ["en"])
    video_id  = extract_id(url)

    if not video_id:
        print(json.dumps({"success": False, "error": "No video ID found in input"}))
        return

    try:
        from youtube_transcript_api import YouTubeTranscriptApi  # noqa: F401
    except ImportError:
        print(json.dumps({"success": False, "error": "youtube-transcript-api not installed. Run: pip3 install youtube-transcript-api"}))
        return

    try:
        snippets = get_snippets(video_id, languages)
        text = " ".join(snippet_text(s).replace("\n", " ") for s in snippets).strip()
        if not text:
            print(json.dumps({"success": False, "error": "Transcript was empty."}))
            return
        print(json.dumps({
            "success":  True,
            "video_id": video_id,
            "text":     text,
            "segments": len(snippets),
        }))
    except Exception as e:
        print(json.dumps({"success": False, "error": str(e)}))

main()
