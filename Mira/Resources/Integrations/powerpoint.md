# PowerPoint / PPTX
tool: run_python_skill (python-pptx, auto-installed)

## When to use
User says: deck, slides, presentation, pptx, pitch deck, slide deck, PowerPoint.

## Ops

### Create a new deck
`run_python_skill(skill:"pptx_rw", args:{op:"create", path:"~/Desktop/<name>.pptx", title?:"<deck title>", slides:[{title:"<slide>", bullets:["point 1","point 2"], layout?:"title_content"}]})`
Layouts: `"title"` (title-only), `"title_content"` (default), `"blank"`.

### Read / extract text from a deck
`run_python_skill(skill:"pptx_rw", args:{op:"read", path:"<abs_path>"})`
Returns: `{slide_count, slides:[{title, bullets, notes}]}`

### Append a slide
`run_python_skill(skill:"pptx_rw", args:{op:"append_slide", path:"<abs_path>", title:"<title>", bullets:["..."]})`

## Design rules (never produce boring slides)
- Pick a specific color palette for the topic — don't default to blue/white
- One dominant color (60-70% weight), 1-2 supporting tones, one accent
- Dark backgrounds for title + conclusion; light for content slides
- Every slide needs a visual element — vary layouts (two-column, icon row, grid, stat callout)
- Titles 36-44pt bold, body 14-16pt, 0.5" margins minimum
- Never use accent lines under titles (AI hallmark — avoid)

## After creating
Open the file: `run_shell_command("open <abs_path>")` so the user can see it in Preview or PowerPoint.

## Constraints
- Requires python-pptx (auto-installed by Mira's skill venv on first run).
- Paths are expanded: `~` → home directory.
- Confirm before overwriting an existing file.
