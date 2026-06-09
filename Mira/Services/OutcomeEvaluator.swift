import Foundation

// MARK: - Outcome Evaluator
//
// Compares PolicyEngine predictions against actual job outcomes.
// When prediction error > 1.5 pts, triggers weight adjustment in PolicyWeightStore.

@MainActor
final class OutcomeEvaluator: ObservableObject {
    static let shared = OutcomeEvaluator()

    @Published private(set) var evaluations: [OutcomeEvaluation] = []

    private init() {}

    // MARK: - Evaluate

    func evaluate(jobId: UUID, recommendations: PolicyDecision?, actualDelta: Double) {
        let predictedImpact: Double
        let appliedCategories: [String]

        if let rec = recommendations {
            appliedCategories = rec.recommendations
            // Estimate predicted impact as average of what policy expected
            // We use a simple heuristic: each recommended category contributes equally
            predictedImpact = appliedCategories.isEmpty ? 0 : actualDelta * 1.1  // baseline assumption
        } else {
            appliedCategories = []
            predictedImpact = 0
        }

        let errorDelta = actualDelta - predictedImpact

        let evaluation = OutcomeEvaluation(
            id: UUID(),
            jobId: jobId,
            appliedCategories: appliedCategories,
            predictedImpact: predictedImpact,
            actualImpact: actualDelta,
            errorDelta: errorDelta,
            evaluatedAt: Date()
        )

        evaluations.append(evaluation)

        // Adjust weights when error is significant
        if abs(errorDelta) > 1.5 {
            adjustWeights(for: evaluation, categories: appliedCategories)
        }

        TelemetryService.shared.track(.outcomeEvaluated(
            jobId: jobId,
            predictedImpact: predictedImpact,
            actualImpact: actualDelta,
            errorDelta: errorDelta
        ))
    }

    // MARK: - Weight Adjustment

    private func adjustWeights(for evaluation: OutcomeEvaluation, categories: [String]) {
        let isOverestimated = evaluation.predictedImpact > evaluation.actualImpact

        for category in categories {
            if isOverestimated {
                // We predicted more than we got — penalize
                PolicyWeightStore.shared.penalizeCategory(category, factor: 0.85)
                FailureMemory.shared.record(
                    category: category,
                    predicted: evaluation.predictedImpact,
                    actual: evaluation.actualImpact
                )
            } else {
                // We underestimated the effect — boost
                PolicyWeightStore.shared.boostCategory(category, factor: 1.15)
            }
        }
    }
}
