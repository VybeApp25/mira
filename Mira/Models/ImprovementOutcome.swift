import Foundation

// MARK: - Improvement Outcome
//
// Computed from completed websiteImprovement job metadata.
// Never persisted separately — derived on demand from AgentJobStore.

struct ImprovementOutcome {
    let jobId: UUID
    let entryId: UUID?
    let createdAt: Date

    let visualDelta: Double
    let conversionDelta: Double
    let mobileDelta: Double
    let accessibilityDelta: Double
    let brandDelta: Double

    var averageDelta: Double {
        (visualDelta + conversionDelta + mobileDelta + accessibilityDelta + brandDelta) / 5.0
    }
}

// MARK: - Aggregated summary

struct ImprovementOutcomeSummary {
    let count: Int
    let avgVisual: Double
    let avgConversion: Double
    let avgMobile: Double
    let avgAccessibility: Double
    let avgBrand: Double
    let avgOverall: Double

    static let empty = ImprovementOutcomeSummary(
        count: 0,
        avgVisual: 0, avgConversion: 0, avgMobile: 0,
        avgAccessibility: 0, avgBrand: 0, avgOverall: 0
    )

    @MainActor
    static func compute(from jobs: [AgentJob]) -> ImprovementOutcomeSummary {
        let outcomes = jobs.compactMap { ImprovementOutcome(job: $0) }
        guard !outcomes.isEmpty else { return .empty }

        func avg(_ values: [Double]) -> Double {
            values.reduce(0, +) / Double(values.count)
        }

        return ImprovementOutcomeSummary(
            count:           outcomes.count,
            avgVisual:       avg(outcomes.map(\.visualDelta)),
            avgConversion:   avg(outcomes.map(\.conversionDelta)),
            avgMobile:       avg(outcomes.map(\.mobileDelta)),
            avgAccessibility: avg(outcomes.map(\.accessibilityDelta)),
            avgBrand:        avg(outcomes.map(\.brandDelta)),
            avgOverall:      avg(outcomes.map(\.averageDelta))
        )
    }
}

// MARK: - Init from AgentJob metadata

extension ImprovementOutcome {
    init?(job: AgentJob) {
        guard job.type == .websiteImprovement,
              job.status == .completed,
              let meta = job.result?.metadata,
              let preV  = meta["preVisual"].flatMap(Int.init),
              let postV = meta["postVisual"].flatMap(Int.init),
              let preC  = meta["preConversion"].flatMap(Int.init),
              let postC = meta["postConversion"].flatMap(Int.init),
              let preM  = meta["preMobile"].flatMap(Int.init),
              let postM = meta["postMobile"].flatMap(Int.init),
              let preA  = meta["preAccessibility"].flatMap(Int.init),
              let postA = meta["postAccessibility"].flatMap(Int.init),
              let preB  = meta["preBrand"].flatMap(Int.init),
              let postB = meta["postBrand"].flatMap(Int.init)
        else { return nil }

        self.jobId            = job.id
        self.entryId          = job.editSourceEntryId
        self.createdAt        = job.completedAt ?? job.createdAt
        self.visualDelta      = Double(postV - preV)
        self.conversionDelta  = Double(postC - preC)
        self.mobileDelta      = Double(postM - preM)
        self.accessibilityDelta = Double(postA - preA)
        self.brandDelta       = Double(postB - preB)
    }
}
