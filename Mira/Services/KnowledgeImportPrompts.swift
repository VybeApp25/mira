import Foundation

// MARK: - KnowledgeImportPrompts
//
// Generates the portable "tell Mira everything about me" prompt the user copies
// into another assistant. The host LLM (ChatGPT / Claude / Gemini / DeepSeek /
// Grok) returns ONE JSON block that Mira parses into a `UserKnowledge` profile.
//
// Design goals:
//  • COMPREHENSIVE — every dimension Mira benefits from knowing, in one pass.
//  • STRICT OUTPUT — exactly one ```json block, fixed snake_case schema, so
//    paste-back parsing is deterministic across providers.
//  • HONEST — the host LLM must include only what it actually knows, mark guesses,
//    and never invent. A fabricated profile is worse than a sparse one.
//  • PRIVACY-SAFE — secrets / passwords / full financial or ID numbers are
//    explicitly excluded; this is preferences and working context, not credentials.
//  • PER-LLM — each provider gets a tailored "where to source this from" and a
//    house-style note matched to how that assistant talks, while the schema is
//    identical everywhere.

enum KnowledgeImportPrompts {

    /// The full prompt for a given provider, ready to copy-paste.
    static func prompt(for provider: KnowledgeProvider) -> String {
        """
        \(sourcingLine(provider))

        # Your task
        Build a thorough, structured profile of me so another AI assistant (called \
        Mira, a Mac assistant) can understand me and tailor everything it does to my \
        actual wants, needs, and working style. Draw on EVERYTHING you know about me \
        from our history and any memory or personalization you have access to.

        # Rules (read carefully)
        1. HONESTY FIRST. Include only what you genuinely know or can confidently \
        infer about me. If you're inferring, that's fine — but don't invent facts. \
        It is far better to leave a field shorter than to fabricate. If you know \
        almost nothing about me, return a nearly-empty profile rather than guessing.
        2. PRIVACY. Do NOT include passwords, API keys, secrets, full financial \
        account or card numbers, government IDs, exact home address, or anything I'd \
        be uncomfortable seeing copied between apps. Preferences, context, and \
        working style only.
        3. BE SPECIFIC AND USEFUL. "Prefers concise answers with code examples first" \
        beats "likes good communication." Each entry should be something Mira could \
        actually act on.
        4. WRITE FOR A THIRD PARTY. Each entry is a statement about me that Mira will \
        read, e.g. "Works in product design" — not "You work in product design."
        5. \(styleNote(provider))

        # Output format — follow EXACTLY
        Respond with NOTHING but a single fenced code block containing one JSON \
        object with the keys below. No preamble, no explanation, no text after the \
        block. Omit any key you have no real information for (don't include empty \
        strings or made-up filler). Every value is an array of short, specific \
        strings except "summary" (a 2–3 sentence string) and "version" (the number 1).

        ```json
        {
          "version": 1,
          "summary": "2–3 sentence overview of who I am and what I'm focused on",
          "identity": ["name / what to call me", "location & timezone", "languages I speak", "my roles or occupation"],
          "work": ["companies or brands I run or work at", "my industry", "my responsibilities"],
          "projects": ["current or ongoing projects, with a word on each"],
          "goals": ["short-term goals", "long-term goals", "what success looks like to me"],
          "communication_preferences": ["tone I prefer", "how concise or detailed", "formatting I like", "things that annoy me"],
          "expertise": ["domains I know well and roughly how deeply", "topics I don't need over-explained"],
          "tools_and_stack": ["software, languages, frameworks, and devices I use daily"],
          "workflows": ["recurring tasks and routines", "how I like work delivered to me"],
          "interests": ["hobbies and topics I care about outside work"],
          "preferences": ["specific likes", "specific dislikes"],
          "constraints": ["hard do-nots", "accessibility needs", "time or budget constraints"],
          "decision_style": ["how I make decisions", "my risk tolerance", "how I want options presented to me"],
          "key_people": ["important collaborators or people in my life, each tagged with their role"],
          "current_focus": ["what I'm actively working on right now and my current priorities"],
          "notes": ["anything else genuinely useful that doesn't fit above"]
        }
        ```

        Remember: one JSON block, only what you truly know, no fabrication, no secrets.
        """
    }

    // MARK: - Per-provider tailoring

    /// Where each assistant should pull knowledge from — matched to its real memory model.
    private static func sourcingLine(_ provider: KnowledgeProvider) -> String {
        switch provider {
        case .chatgpt:
            return "Using your saved Memories about me and the full history of our past conversations, do the following. If memory is enabled, draw on it completely; if it's off, use everything in our chats."
        case .claude:
            return "Using everything you know about me from our conversation history and any project knowledge or memory you have access to, do the following."
        case .gemini:
            return "Using your personalization from my Google account activity (where available) and the history of our conversations, do the following."
        case .deepseek:
            return "Using everything you can determine about me from our conversation history in this chat, do the following."
        case .grok:
            return "Using our conversation history and — if my X account is connected — what my posts and activity reveal about my interests, voice, and work, do the following."
        }
    }

    /// A house-style nudge phrased the way each assistant tends to operate, so the
    /// instruction lands naturally rather than fighting the model's defaults.
    private static func styleNote(_ provider: KnowledgeProvider) -> String {
        switch provider {
        case .chatgpt:
            return "Don't pad the output to seem thorough — density over length. Only the JSON block; resist adding a friendly intro or sign-off."
        case .claude:
            return "Apply your usual rigor about uncertainty: if you're not sure, either omit it or keep it tight. Output only the JSON block, with no commentary before or after."
        case .gemini:
            return "Keep entries crisp and factual. Return only the JSON block — no extra formatting, headers, or follow-up suggestions."
        case .deepseek:
            return "Be precise and literal. Emit only the JSON block and stop — no reasoning trace, no explanation."
        case .grok:
            return "Be direct and unvarnished — capture the real me, not a flattering version. Only the JSON block, no quips outside it."
        }
    }
}
