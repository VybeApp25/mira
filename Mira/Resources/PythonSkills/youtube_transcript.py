#!/usr/bin/env python3
"""Fetch a YouTube video transcript.
Args JSON (stdin): {url, languages?}
  url — YouTube URL (https://youtube.com/watch?v=ID or https://youtu.be/ID) or bare video ID
  languages — optional list like ["en", "en-US"] (default: ["en"])
Output JSON (stdout): {success, video_id, text, segments, error?}
"""
import sys, json, re

def extract_id(url_or_id: str) -> str:
    m = re.search(r"(?:v=|youtu\.be/)([A-Za-z0-9_-]{11})", url_or_id)
    return m.group(1) if m else url_or_id.strip()

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
        from youtube_transcript_api import YouTubeTranscriptApi, NoTranscriptFound, TranscriptsDisabled
    except ImportError:
        print(json.dumps({"success": False, "error": "youtube-transcript-api not installed. Run: pip3 install youtube-transcript-api"}))
        return

    try:
        transcript = YouTubeTranscriptApi.get_transcript(video_id, languages=languages)
        text = " ".join(t["text"].replace("\n", " ") for t in transcript)
        print(json.dumps({
            "success":  True,
            "video_id": video_id,
            "text":     text,
            "segments": len(transcript),
        }))
    except NoTranscriptFound:
        # Try auto-generated in any language
        try:
            tl = YouTubeTranscriptApi.list_transcripts(video_id)
            t  = tl.find_generated_transcript(["en", "en-US", "en-GB"])
            transcript = t.fetch()
            text = " ".join(s["text"].replace("\n", " ") for s in transcript)
            print(json.dumps({"success": True, "video_id": video_id, "text": text, "segments": len(transcript)}))
        except Exception as e2:
            print(json.dumps({"success": False, "error": f"No transcript available: {e2}"}))
    except Exception as e:
        print(json.dumps({"success": False, "error": str(e)}))

main()
