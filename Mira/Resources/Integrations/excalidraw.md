# Excalidraw & Diagrams
tool: run_python_skill (diagram_gen, stdlib only)

## When to use
User says: diagram, flowchart, architecture diagram, sequence diagram, draw, visualize, chart, mindmap, ERD, Excalidraw, Mermaid.

## Generate a diagram (HTML preview)
`run_python_skill(skill:"diagram_gen", args:{format:"mermaid", definition:"<mermaid syntax>", title:"<title>", path?:"~/Desktop/<name>.html", theme?:"dark"})`

After generating: `run_shell_command("open <path>")` to open in browser.

## Mermaid (preferred — Claude generates natively)
format: `"mermaid"`

Diagram types:
- `flowchart TD` / `flowchart LR` — top-down or left-right flow
- `sequenceDiagram` — message passing between actors
- `classDiagram` — OOP class structure
- `erDiagram` — database entity relationships
- `gantt` — project timelines
- `pie` — proportional data
- `mindmap` — hierarchical topics
- `gitGraph` — branch/merge history

Syntax rules: labels with spaces or special chars must use `["label text"]`. Avoid bare `()` in labels.

## Excalidraw (hand-drawn aesthetic)
format: `"excalidraw"`, definition: `"<Excalidraw JSON string>"`
The HTML file renders the live Excalidraw canvas — editable in browser.

## Canonical patterns

### "Draw a flowchart of <process>"
Mermaid flowchart TD, save to ~/Desktop/<title>.html, open.

### "Show the architecture of <system>"
Mermaid flowchart LR or classDiagram depending on the structure.

### "Create a sequence diagram for <flow>"
Mermaid sequenceDiagram.

### "Make an Excalidraw diagram"
Use excalidraw format with proper element JSON.

## Constraints
- Output is a self-contained HTML file — no server needed, works offline.
- Mermaid CDN v10; Excalidraw ESM CDN with React 18.
- Validate Mermaid syntax mentally before generating — unclosed nodes or invalid syntax silently fail to render.
