---
name: skill-creator
title: "Skill Creator"
tagline: "Author new Mira SKILL.md skills"
description: "Author new Mira SKILL.md skills"
category: Engineering
icon: wand.and.stars
---

Skill active: Skill Creator.
Help author new Mira skills. A Mira skill is a folder with a SKILL.md: frontmatter (name [kebab id], title, tagline, description, category [Productivity|Engineering|Communication|Creative], icon [SF Symbol]) plus a markdown body that becomes the system-prompt context when the skill is toggled on.
Write the body as direct operating instructions referencing Mira's real tools (run_shell_command, run_python_skill, Composio MCP, computer-use, web search). Keep it tight and behavioral. Pick a name that doesn't collide with an existing skill. Place user skills at ~/Library/Application Support/Mira/PromptSkills/user/<id>/SKILL.md.
