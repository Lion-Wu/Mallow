import XCTest
@testable import Mallow

final class VoiceRecordingStartCoordinatorTests: XCTestCase {
    func testRestartRequestIsDeferredUntilCurrentStartCompletes() {
        var coordinator = VoiceRecordingStartCoordinator()
        let attemptID = coordinator.beginStart { uuid(43) }

        XCTAssertTrue(coordinator.requestRestartAfterStartIfNeeded())
        XCTAssertEqual(coordinator.completeStart(attemptID: uuid(44)), .stale)
        XCTAssertEqual(coordinator.completeStart(attemptID: attemptID), .restartRequested)
        XCTAssertFalse(coordinator.isStartingRecording)
        XCTAssertFalse(coordinator.pendingRestartAfterStart)
    }

    func testCancelStartTasksClearsStateAndCancelsTasks() {
        var coordinator = VoiceRecordingStartCoordinator()
        let task = sleepingTask()
        let watchdog = sleepingTask()
        _ = coordinator.beginStart { uuid(47) }
        coordinator.registerStartRecordingTask(task)
        coordinator.registerStartWatchdogTask(watchdog)

        coordinator.cancelStartTasks()

        XCTAssertFalse(coordinator.isStartingRecording)
        XCTAssertNil(coordinator.startAttemptID)
        XCTAssertTrue(task.isCancelled)
        XCTAssertTrue(watchdog.isCancelled)
    }
}
