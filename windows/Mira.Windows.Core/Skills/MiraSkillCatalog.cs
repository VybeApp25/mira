namespace Mira.Windows.Core.Skills;

/// <summary>
/// The Windows equivalent of Mira/Models/MiraSkillCatalog.swift's ~30
/// hardcoded built-ins — deliberately a different, smaller set. Most of
/// Mac's built-ins (iMessage, Spotify control, Find My) are directives
/// telling the model which Mac-only tool to prefer; none of those tools
/// exist on Windows, so porting that exact list would just be dead text with
/// nothing to steer. This is a curated set of communication-style/expertise
/// skills that meaningfully change what Claude actually writes back, since
/// Windows chat routes (HigherModel/GptQuery/escalated LocalResponse) are
/// currently text-reply-only — no tool-calling surface for a skill to nudge.
/// </summary>
public static class MiraSkillCatalog
{
    public static IReadOnlyList<MiraSkill> Builtins { get; } =
    [
        new MiraSkill
        {
            Id = "concise-mode", Name = "Concise Mode", Tagline = "Short, to-the-point answers",
            Icon = "✂️", Category = "communication", Origin = MiraSkillOrigin.Builtin,
            Context = "Keep every response as brief as possible — a few sentences at most unless the user explicitly asks for depth. Prefer short bullet points over paragraphs.",
        },
        new MiraSkill
        {
            Id = "explain-simply", Name = "Explain Simply", Tagline = "Plain-language explanations",
            Icon = "🧸", Category = "communication", Origin = MiraSkillOrigin.Builtin,
            Context = "Explain things in plain, simple language, as if to someone with no background in the topic. Avoid jargon; when a technical term is unavoidable, define it in the same sentence.",
        },
        new MiraSkill
        {
            Id = "code-reviewer", Name = "Code Reviewer", Tagline = "Careful, thorough code review",
            Icon = "🔍", Category = "development", Origin = MiraSkillOrigin.Builtin,
            Context = "When reviewing code, be specific and concrete: name exact lines or functions, explain WHY something is a problem, and suggest a fix rather than just flagging an issue. Call out both real problems and things done well.",
        },
        new MiraSkill
        {
            Id = "socratic-tutor", Name = "Socratic Tutor", Tagline = "Learn by being asked questions",
            Icon = "🎓", Category = "learning", Origin = MiraSkillOrigin.Builtin,
            Context = "Instead of giving direct answers right away, guide the user toward the answer by asking one clarifying or probing question at a time. Only give the direct answer if the user asks for it explicitly or seems stuck after a couple of exchanges.",
        },
        new MiraSkill
        {
            Id = "devils-advocate", Name = "Devil's Advocate", Tagline = "Pressure-tests your ideas",
            Icon = "🥊", Category = "thinking", Origin = MiraSkillOrigin.Builtin,
            Context = "Before agreeing with a plan or idea, actively look for weaknesses, risks, and counterarguments and raise them clearly. Be constructive, not just contrarian — always pair a concern with a suggestion.",
        },
        new MiraSkill
        {
            Id = "meeting-notes", Name = "Meeting Notes", Tagline = "Turns rambling text into structured notes",
            Icon = "📝", Category = "productivity", Origin = MiraSkillOrigin.Builtin,
            Context = "When asked to summarize notes or a transcript, structure the output as three sections: Decisions, Action Items (with an owner if one is mentioned), and Open Questions. Be terse within each section.",
        },
        new MiraSkill
        {
            Id = "writing-coach", Name = "Writing Coach", Tagline = "Sharper, tighter prose",
            Icon = "✍️", Category = "communication", Origin = MiraSkillOrigin.Builtin,
            Context = "When reviewing or improving writing, cut unnecessary words, prefer active voice, and flag any sentence that could be split or clarified. Preserve the author's voice — don't over-polish into something generic.",
        },
        new MiraSkill
        {
            Id = "second-opinion", Name = "Second Opinion", Tagline = "Independent, skeptical review",
            Icon = "🧐", Category = "thinking", Origin = MiraSkillOrigin.Builtin,
            Context = "Treat every request as a request for an independent, skeptical second opinion rather than automatic agreement. State plainly when you think something is a bad idea and explain why.",
        },
    ];
}
