import XCTest
@testable import Mira

@MainActor
final class AgentTaskLifecycleTests: XCTestCase {
    private let manager = AgentTaskManager.shared

    override func tearDown() {
        for task in manager.activeTasks {
            manager.remove(task.id)
        }
        super.tearDown()
    }

    func testQueuedTaskTransitionsToRunningThenCompleted() {
        let id = manager.start(title: "Background research", status: .queued)
        XCTAssertEqual(task(id)?.status, .queued)

        manager.update(id, status: .running, subtitle: "Searching", progress: 0.5)
        XCTAssertEqual(task(id)?.status, .running)
        XCTAssertEqual(task(id)?.subtitle, "Searching")
        XCTAssertEqual(task(id)?.progress, 0.5)

        manager.finish(id, success: true, summary: "Research complete")
        XCTAssertEqual(task(id)?.status, .completed)
        XCTAssertEqual(task(id)?.subtitle, "Research complete")
        XCTAssertEqual(task(id)?.progress, 1)
    }

    func testRunningTaskTransitionsToFailed() {
        let id = manager.start(title: "Background research")

        manager.finish(id, success: false, summary: "Service unavailable")

        XCTAssertEqual(task(id)?.status, .failed)
        XCTAssertEqual(task(id)?.subtitle, "Service unavailable")
        XCTAssertEqual(task(id)?.progress, 1)
    }

    func testUnknownTaskUpdatesAreIgnored() {
        let existingID = manager.start(title: "Existing task", status: .queued)
        let snapshot = manager.activeTasks

        manager.update(UUID(), status: .running, progress: 0.8)
        manager.finish(UUID(), success: false)

        XCTAssertEqual(manager.activeTasks, snapshot)
        XCTAssertEqual(task(existingID)?.status, .queued)
    }

    func testProgressUpdatesAreClampedToValidRange() {
        let id = manager.start(title: "Clamped task")

        manager.update(id, progress: 2)
        XCTAssertEqual(task(id)?.progress, 1)

        manager.update(id, progress: -1)
        XCTAssertEqual(task(id)?.progress, 0)
    }

    private func task(_ id: UUID) -> AgentActivity? {
        manager.activeTasks.first { $0.id == id }
    }
}
