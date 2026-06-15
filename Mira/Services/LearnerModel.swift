import Foundation

// MARK: - Learner Model (Teaching System M4)
//
// Answers, honestly, "what does this user know, how well, and where did they
// leave off?" — DERIVED from the append-only learning journal (the M2 telemetry
// events), never stored as a primary fact. Same two-layer model as Phase 15
// (OutcomeAssessment → OutcomeSummary): facts recorded, conclusions recomputed.
// See docs/architecture/teaching_system.md §4.
//
// Honesty: a skill with no journal events is "not yet assessed" — never a
// fabricated mastery number. And mastery EARNED through observation outranks
// mastery "learned" via self-confirmation: provenance drives confidence.

enum MasteryStatus: Equatable { case notAssessed, inProgress, mastered }
enum MasteryConfidence: String { case low, medium, high }

struct SkillProgress: Equatable {
    let skillId:      String
    let status:       MasteryStatus
    let mastery:      Double?          // 0–1, nil when not assessed
    let confidence:   MasteryConfidence
    let completions:  Int              // full end-to-end completions
    let lastActivity: Date?
    let reviewDue:    Bool
    /// stepId after which to resume; nil = start fresh (no in-progress session).
    let resumeAfterStepId: String?

    static func notAssessed(_ id: String) -> SkillProgress {
        SkillProgress(skillId: id, status: .notAssessed, mastery: nil,
                      confidence: .low, completions: 0, lastActivity: nil,
                      reviewDue: false, resumeAfterStepId: nil)
    }
}

@MainActor
final class LearnerModel: ObservableObject {
    static let shared = LearnerModel()
    private init() {}

    // Tunables.
    private let masteryThreshold = 0.80      // mastered at/above this
    private let masteryDecay     = 0.45      // mastery = 1 - decay^completions
    private let reviewAfterDays  = 7.0       // mastered skill unpracticed this long → review

    /// Recompute a skill's progress from the journal. Pure derivation, no storage.
    func progress(forSkillId skillId: String) -> SkillProgress {
        let mine: [TelemetryRecord] = TelemetryService.shared.records.filter { $0.properties["skillId"] == skillId }
        let recs: [TelemetryRecord] = mine.sorted { $0.timestamp < $1.timestamp }
        guard !recs.isEmpty else { return .notAssessed(skillId) }

        // Full completions (every step done).
        let completions = recs.filter(Self.isFullCompletion).count

        // Provenance mix across completed steps — quality of the evidence.
        let stepCompletes = recs.filter { $0.event == "step_completed" }
        let observed = stepCompletes.filter { $0.properties["groundedBy"] == "observation" }.count
        let obsFraction = stepCompletes.isEmpty ? 0 : Double(observed) / Double(stepCompletes.count)

        let mastery = 1 - pow(masteryDecay, Double(completions))
        let lastActivity = recs.last?.timestamp

        let status: MasteryStatus = mastery >= masteryThreshold ? .mastered : .inProgress
        let confidence: MasteryConfidence = {
            if completions == 0 { return .low }
            if obsFraction < 0.5 { return .medium }     // leaned on self-report
            return completions >= 2 ? .high : .medium
        }()

        let reviewDue: Bool = {
            guard status == .mastered, let last = lastActivity else { return false }
            return Date().timeIntervalSince(last) > reviewAfterDays * 86_400
        }()

        return SkillProgress(
            skillId: skillId, status: status, mastery: mastery, confidence: confidence,
            completions: completions, lastActivity: lastActivity, reviewDue: reviewDue,
            resumeAfterStepId: resumeAnchor(in: recs))
    }

    /// The stepId after which to resume: the last completed step of the most
    /// recent session, UNLESS that session finished (then start fresh).
    private func resumeAnchor(in recs: [TelemetryRecord]) -> String? {
        guard let lastStartIdx = recs.lastIndex(where: { $0.event == "lesson_started" }) else { return nil }
        let session = recs[lastStartIdx...]
        // Session finished fully → no mid-resume.
        if session.contains(where: Self.isFullCompletion) { return nil }
        return session.last(where: { $0.event == "step_completed" })?.properties["stepId"]
    }

    /// A `lesson_completed` event where every step was completed.
    private static func isFullCompletion(_ rec: TelemetryRecord) -> Bool {
        guard rec.event == "lesson_completed",
              let c = Int(rec.properties["completedSteps"] ?? ""),
              let t = Int(rec.properties["totalSteps"] ?? "") else { return false }
        return c == t
    }

    /// Has any ringed target in this lesson actually landed on a real run? Derived
    /// from the journal — `step_grounded` with `grounded=true`. This is the honest
    /// basis for clearing a scaffolded lesson's "Unverified" badge: the ring is
    /// only proven once it's been observed to land, never by authoring alone.
    func hasGroundedRun(forSkillId skillId: String) -> Bool {
        TelemetryService.shared.records.contains {
            $0.event == "step_grounded"
                && $0.properties["skillId"] == skillId
                && $0.properties["grounded"] == "true"
        }
    }

    /// Resolves the resume index for a loaded skill (next step after the anchor).
    /// Returns 0 when there's nothing to resume.
    func resumeIndex(for skill: TeachingSkill) -> Int {
        let p = progress(forSkillId: skill.id)
        guard let anchor = p.resumeAfterStepId,
              let idx = skill.steps.firstIndex(where: { $0.id == anchor }) else { return 0 }
        return min(idx + 1, skill.steps.count - 1)
    }
}
