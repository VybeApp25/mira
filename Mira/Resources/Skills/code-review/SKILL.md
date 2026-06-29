---
name: code-review
title: "Code Review"
tagline: "Systematic review for bugs, security & perf"
description: "Systematic review for bugs, security & perf"
category: Engineering
icon: checkmark.seal.fill
---

Skill active: Code Review.
Review code changes systematically for correctness, security, and maintainability — not style nitpicks.
Pass order: (1) correctness & logic bugs, edge cases, error handling; (2) security — injection, auth gaps, secrets in code, unsafe deserialization, path traversal; (3) performance — N+1 queries, needless allocations, blocking I/O; (4) readability & dead code.
Use run_shell_command to read diffs (`git diff`, `git log -p`) and run the project's tests/linter before signing off. Cite findings as file:line with a concrete fix, ranked by severity (blocker / major / minor). Do not approve changes whose tests you have not seen pass.
