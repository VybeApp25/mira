import Foundation

// MARK: - Skill bundle format (Teaching System M3)
//
// A Skill is a folder bundle, Claude-Agent-Skills style:
//
//   <skill>/
//     SKILL.md     ← manifest: always-loaded metadata (name, description, domainApp)
//     steps.json   ← the curriculum, loaded ON DEMAND (progressive disclosure)
//
// The manifest is cheap and stays resident; the steps are read only when the
// skill is actually run. New domains are new folders — no app changes.
// See docs/architecture/teaching_system.md §5.
//
// (Spec wrote curriculum.yaml; we use JSON so the loader stays dependency-free
// while keeping SKILL.md as the human-facing manifest.)

/// The always-loaded part of a skill — parsed from SKILL.md frontmatter.
struct SkillManifest: Identifiable, Equatable {
    let id:          String        // == name
    let name:        String
    let description: String
    let domainApp:   String?       // bundle id this skill teaches in (relevance trigger)
    let grounding:   String?       // "accessibility" | "vision" — honest about its tier
    let version:     String?
    let bundleURL:   URL           // the skill folder
    var title:       String? = nil // optional human title; falls back to humanized name
    var scaffolded:  Bool = false  // machine-generated starter; "Unverified" until a real grounded run

    /// Human-facing lesson name. Uses the manifest `title` if present, otherwise
    /// humanizes the kebab id ("xcode-run-and-read" → "Xcode Run And Read").
    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return name
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - On-disk curriculum (steps.json), decoded on demand

struct SkillStepsDTO: Codable {
    let id:    String
    let title: String
    let steps: [StepDTO]
}

struct StepDTO: Codable {
    let id:            String
    let instruction:  String
    let target:       TargetDTO?
    let successCheck: SuccessCheckDTO
    let remediation:  String?
    let observeWindow: Double?
    let action:       StepActionDTO?

    /// Returns the domain step, or nil if the success check is unsupported — in
    /// which case the whole skill must fail to load. A bundle may not declare a
    /// check Mira can't actually perform (that would risk a false completion).
    func toDomain() -> TeachingStep? {
        guard let check = successCheck.toDomain() else { return nil }
        return TeachingStep(
            id: id,
            instruction: instruction,
            target: target.map { NamedTarget(description: $0.description) },
            successCheck: check,
            remediation: remediation ?? "Take your time — I'll keep watching.",
            observeWindow: observeWindow ?? 30,
            action: action?.toDomain() ?? .click)
    }
}

struct TargetDTO: Codable {
    let description: String
}

/// Tagged autonomous-mode action. Absent → `.click`. An unknown/incomplete action
/// degrades to `.click` rather than failing the load (a missing `text`/`combo`
/// shouldn't make the lesson unusable in guided mode).
struct StepActionDTO: Codable {
    let type:  String           // "click" | "doubleClick" | "type" | "key"
    let text:  String?          // for "type"
    let combo: String?          // for "key", e.g. "cmd+s"

    func toDomain() -> StepAction {
        switch type {
        case "doubleClick": return .doubleClick
        case "type":        return text.map  { .type(text: $0) }  ?? .click
        case "key":         return combo.map { .key(combo: $0) }  ?? .click
        default:            return .click
        }
    }
}

/// Tagged representation of a success check. Unknown `type` → nil (skill won't load).
struct SuccessCheckDTO: Codable {
    let type:     String
    let bundleId: String?
    /// For `visualState`: the described visible outcome to verify by vision
    /// ("the export progress bar reached 100%"). Missing → the skill won't load,
    /// rather than silently degrading to a check that can never pass.
    let prompt:   String?

    func toDomain() -> SuccessCheck? {
        switch type {
        case "appFrontmost":     return bundleId.map { .appFrontmost(bundleId: $0) }
        case "darkModeEnabled":  return .darkModeEnabled
        case "visualState":      return prompt.map { .visualState(prompt: $0) }
        case "userConfirmation": return .userConfirmation
        default:                 return nil   // unsupported — honest failure, not a fake pass
        }
    }
}
