import Foundation

// MARK: - Failure Type

enum FailureType: String, Codable {
    case overestimated
    case underestimated
    case ignored
    case rejected
}

// MARK: - Failure Record

struct FailureRecord: Codable, Identifiable {
    let id: UUID
    let category: String
    let predictedImpact: Double
    let actualImpact: Double
    let errorDelta: Double
    let failureType: FailureType
    let timestamp: Date
}

// MARK: - Outcome Evaluation

struct OutcomeEvaluation: Codable, Identifiable {
    let id: UUID
    let jobId: UUID
    let appliedCategories: [String]
    let predictedImpact: Double
    let actualImpact: Double
    let errorDelta: Double
    let evaluatedAt: Date
}
