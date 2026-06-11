# Claude Design
tool: run_python_skill (diagram_gen), run_shell_command, run_coding_agent

## When to use
User says: design, make it look good, landing page, prototype, UI, frontend, visual, mockup, brand, style, color palette, make it beautiful.

## Output hierarchy (choose narrowest fit)
1. **Single HTML file** — for landing pages, prototypes, dashboards, decks. Self-contained, no server.
2. **run_coding_agent** — for multi-file frontend builds with a dev server.
3. **diagram_gen Mermaid** — for flowcharts, architecture, sequence diagrams.
4. **diagram_gen Excalidraw** — for hand-drawn style whiteboard diagrams.

## Design taste rules
Apply to every HTML artifact:

**Color**: Pick a palette specific to the topic — never default to generic blue/white. One dominant color (60-70%), 1-2 supporting, one accent. Dark backgrounds for hero/title sections; light for content.

**Typography**: Choose contrasting font pairs (e.g. Georgia + Calibri, Arial Black + Arial). Headings 36-48px bold; body 15-16px; line-height 1.6.

**Layout**: Avoid text-only slides/sections. Always include visual elements: icons, cards, stat callouts, images, dividers. Use grid/flex for alignment. 24-40px gutters. 0.5" minimum margins.

**Micro-interactions**: Subtle CSS transitions (0.2-0.3s ease) on hover, focus. Fade-in on load for above-fold content.

**Don't**: Centered body text, equal-weight color combos, accent underlines on headings, text-only layouts.

## Canonical patterns

### "Build a landing page for <product>"
Single HTML file, hero + features + CTA. Dark hero, light content, brand palette.

### "Make a pitch deck as a webpage"
HTML with slide-like sections, scroll-snap or JS navigation, designed slide layouts.

### "Design a dashboard"
Single HTML + inline CSS/JS, stat cards, charts via Chart.js CDN, sidebar nav.

### "Create a logo concept"
SVG inline in HTML — geometric, type-based, or icon mark. Never raster.

## Constraint
Image generation, provider-backed video, and slide-deck generation are not available. Offer HTML/SVG alternatives instead of claiming a provider route exists.
