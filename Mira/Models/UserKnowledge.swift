import Foundation

// MARK: - UserKnowledge (personal-knowledge plane)
//
// A structured profile of the user, imported from another assistant (ChatGPT,
// Claude, Gemini, DeepSeek, Grok) via the portable-prompt flow, or built up by
// Mira over time. This is the PERSONAL knowledge plane: it stays on the device
// and is NEVER shared into the collective recipe library — it's about the user.
//
// Every field is optional so parsing is lenient: a host LLM that only knows some
// things about the user still produces a valid import. Arrays-of-strings (rather
// than deep nesting) because LLMs emit those reliably across providers.

struct UserKnowledge: Codable, Equatable {
    var version: Int?
    var summary: String?                    // 2–3 sentence who-they-are
    var identity: [String]?                 // name, location, timezone, languages, roles
    var work: [String]?                     // companies, brands, industry, responsibilities
    var projects: [String]?                 // current/ongoing projects
    var goals: [String]?                    // short- and long-term goals
    var communicationPreferences: [String]? // tone, verbosity, formatting, pet peeves
    var expertise: [String]?                // strong domains + skill level
    var toolsAndStack: [String]?            // software, languages, frameworks, devices
    var workflows: [String]?                // recurring tasks, routines, how they like work delivered
    var interests: [String]?                // hobbies, topics they care about
    var preferences: [String]?              // likes / dislikes
    var constraints: [String]?              // do-nots, accessibility, time constraints
    var decisionStyle: [String]?            // how they decide, risk tolerance, how to present options
    var keyPeople: [String]?                // collaborators / relationships, role-tagged
    var currentFocus: [String]?             // what they're actively working on now
    var notes: [String]?                    // anything else useful

    // Provenance (set by Mira on import, not by the host LLM). A profile can be
    // built up from several assistants, so this is the list of contributing ones.
    var importedFrom: [String]?
    var importedAt: Date?

    enum CodingKeys: String, CodingKey {
        case version, summary, identity, work, projects, goals
        case communicationPreferences = "communication_preferences"
        case expertise
        case toolsAndStack = "tools_and_stack"
        case workflows, interests, preferences, constraints
        case decisionStyle = "decision_style"
        case keyPeople = "key_people"
        case currentFocus = "current_focus"
        case notes
        case importedFrom = "imported_from"
        case importedAt = "imported_at"
    }

    /// True when the profile carries essentially no information.
    var isEmpty: Bool {
        let arrays = [identity, work, projects, goals, communicationPreferences,
                      expertise, toolsAndStack, workflows, interests, preferences,
                      constraints, decisionStyle, keyPeople, currentFocus, notes]
        let anyArray = arrays.contains { ($0?.isEmpty == false) }
        return (summary?.isEmpty ?? true) && !anyArray
    }
}

// MARK: - Providers

/// The assistants a user can export their profile from. Each gets a tailored
/// extraction prompt (different memory sources + house style) but the SAME output
/// schema, so Mira parses them all identically.
enum KnowledgeProvider: String, CaseIterable, Identifiable {
    case chatgpt, claude, gemini, deepseek, grok

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatgpt:  return "ChatGPT"
        case .claude:   return "Claude"
        case .gemini:   return "Gemini"
        case .deepseek: return "DeepSeek"
        case .grok:     return "Grok"
        }
    }
}
