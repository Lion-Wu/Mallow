import XCTest
@testable import Mallow

@MainActor
final class VoiceVisionCaptureCoordinatorTests: XCTestCase {
    func testPresentationRequiresImageCapableSession() {
        var coordinator = VoiceVisionCaptureCoordinator()

        XCTAssertFalse(coordinator.present(
            isAvailable: false,
            isRecording: true,
            isSendSuppressed: false
        ))
        XCTAssertFalse(coordinator.state.isPresented)
        XCTAssertFalse(coordinator.state.isRecording)
    }

    func testHeldUtteranceKeepsSamplesAcrossRecordingPause() throws {
        var coordinator = VoiceVisionCaptureCoordinator()
        let start = TestDate.reference

        XCTAssertTrue(coordinator.present(
            isAvailable: true,
            isRecording: true,
            isSendSuppressed: true,
            now: start
        ))
        coordinator.appendSample(
            data: Data([1]),
            mimeType: "image/png",
            isAvailable: true,
            now: start.addingTimeInterval(0.5)
        )

        coordinator.updateRecordingState(
            isRecording: false,
            isAvailable: true,
            isSendSuppressed: true
        )
        coordinator.beginUtteranceIfNeeded(
            isAvailable: true,
            isSendSuppressed: true,
            now: start.addingTimeInterval(2)
        )
        coordinator.appendSample(
            data: Data([2]),
            mimeType: nil,
            isAvailable: true,
            now: start.addingTimeInterval(2.5)
        )

        let selected = coordinator.selectedAttachments(
            isAvailable: true,
            now: start.addingTimeInterval(4)
        )
        XCTAssertEqual(try selected.map { try $0.loadData() }, [Data([1]), Data([2])])
        XCTAssertEqual(coordinator.state.sampleCount, 2)
    }
}
