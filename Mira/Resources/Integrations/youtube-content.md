# YouTube Content
tool: run_python_skill (youtube-transcript-api, auto-installed)

## When to use
User shares a YouTube URL, asks to summarize a video, requests a transcript, or wants to extract content from a YouTube video.

## Get transcript
`run_python_skill(skill:"youtube_transcript", args:{url:"<youtube_url_or_id>"})`
Accepts: full URLs (`https://youtube.com/watch?v=ID`), short links (`https://youtu.be/ID`), Shorts, or bare 11-char video IDs.
Returns: `{success, video_id, text, segments:[{start, duration, text}]}`

## Output formats (after fetching)
Choose based on what the user asked for:

- **Summary** — 5-10 sentence overview of the full video
- **Chapters** — group by topic shifts with timestamps: `00:00 Intro — ...`
- **Thread** — numbered X/Twitter posts, each under 280 chars
- **Blog post** — full article: title, sections, key takeaways
- **Quotes** — notable quotes with timestamps
- **Key points** — bullet list of the 5-10 most important ideas

Default to Summary unless the user specifies a format.

## Canonical patterns

### "Summarize this YouTube video: <url>"
fetch transcript → produce 5-10 sentence summary.

### "Get the transcript of <url>"
fetch → return raw `text` field.

### "Turn this video into a Twitter thread"
fetch → thread format, 15-20 tweets.

### "What are the chapters in <url>"
fetch → group segments by topic, output timestamped chapter list.

## Constraints
- Requires `youtube-transcript-api` (auto-installed on first run).
- Transcripts unavailable if the video has no captions/auto-captions.
- If `success` is false, report the error — likely no captions available.
- Max transcript length ~50,000 chars; summarize sections if longer.
