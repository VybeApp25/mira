import XCTest
@testable import Mira

final class HUDStateMachineTests: XCTestCase {
    func testVoiceInteractionFollowsExpectedLifecycle() {
        let requestDate = Date(timeIntervalSince1970: 1_000)

        let listening = HUDReducer.reduce(.idle, .userInvokedVoice, now: requestDate)
        XCTAssertEqual(listening, .listening(transcript: nil))

        let thinking = HUDReducer.reduce(listening, .speechEnded, now: requestDate)
        XCTAssertEqual(thinking, .thinking(route: .higherModel, startedAt: requestDate))

        let speaking = HUDReducer.reduce(thinking, .speechPlaybackStarted("Hello"), now: requestDate)
        XCTAssertEqual(speaking, .speaking(textPreview: "Hello"))

        let completed = HUDReducer.reduce(speaking, .speechPlaybackEnded, now: requestDate)
        XCTAssertEqual(completed, .idle)
    }

    func testTextAndBackgroundWorkerRoutesEnterThinking() {
        let requestDate = Date(timeIntervalSince1970: 2_000)

        XCTAssertEqual(
            HUDReducer.reduce(.idle, .userSubmittedText("Summarize this"), now: requestDate),
            .thinking(route: .higherModel, startedAt: requestDate)
        )
        XCTAssertEqual(
            HUDReducer.reduce(.idle, .workerStarted("Research"), now: requestDate),
            .thinking(route: .backgroundWorker(name: "Research"), startedAt: requestDate)
        )
    }

    func testIllegalEventsLeaveStateUnchanged() {
        let requestDate = Date(timeIntervalSince1970: 3_000)
        let thinking = HUDState.thinking(route: .tool(name: "Calendar"), startedAt: requestDate)

        XCTAssertEqual(HUDReducer.reduce(.idle, .speechEnded, now: requestDate), .idle)
        XCTAssertEqual(HUDReducer.reduce(thinking, .speechPlaybackEnded, now: requestDate), thinking)
        XCTAssertEqual(
            HUDReducer.reduce(.speaking(textPreview: "Still speaking"), .errorDismissed, now: requestDate),
            .speaking(textPreview: "Still speaking")
        )
    }

    func testUserInvocationInterruptsSpeakingAndReturnsToListening() {
        let interrupted = HUDReducer.reduce(
            .speaking(textPreview: "Previous response"),
            .userInvokedVoice
        )

        XCTAssertEqual(interrupted, .listening(transcript: nil))
    }

    func testCancelAndRecoverableErrorRecoveryReturnToIdle() {
        let failed = HUDReducer.reduce(
            .thinking(route: .higherModel, startedAt: .distantPast),
            .errorOccurred("Network unavailable", recoverable: true)
        )
        XCTAssertEqual(failed, .error(message: "Network unavailable", recoverable: true))
        XCTAssertEqual(HUDReducer.reduce(failed, .errorDismissed), .idle)

        XCTAssertEqual(
            HUDReducer.reduce(.speaking(textPreview: "Cancel me"), .cancelRequested),
            .idle
        )
    }
}
