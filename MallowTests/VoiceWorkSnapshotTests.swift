import XCTest
@testable import Mallow

final class VoiceWorkSnapshotTests: XCTestCase {
    func testListeningStartBlocksOnChatAndAudioWorkButAutoResumeOnlyBlocksOnAudio() {
        XCTAssertTrue(snapshot(isChatLoading: true).blocksListeningStart)
        XCTAssertTrue(snapshot(isChatPriming: true).blocksListeningStart)
        XCTAssertTrue(snapshot(isPlaybackRequested: true).blocksListeningStart)
        XCTAssertTrue(snapshot(isPlaybackRequested: true).hasActiveVoiceWork)
        XCTAssertFalse(snapshot(isChatLoading: true).blocksAutoResume)
        XCTAssertTrue(snapshot(isAudioPlaying: true).blocksAutoResume)
        XCTAssertTrue(snapshot(hasAudioRequests: true).blocksAutoResume)
        XCTAssertFalse(snapshot().blocksListeningStart)
    }

    private func snapshot(
        isRealtimeMode: Bool = false,
        isAudioLoading: Bool = false,
        isAudioPlaying: Bool = false,
        isPlaybackRequested: Bool = false,
        hasAudioRequests: Bool = false,
        isChatLoading: Bool = false,
        isChatPriming: Bool = false,
        isWaitingForToolAuthorization: Bool = false
    ) -> VoiceWorkSnapshot {
        VoiceWorkSnapshot(
            isRealtimeMode: isRealtimeMode,
            isAudioLoading: isAudioLoading,
            isAudioPlaying: isAudioPlaying,
            isPlaybackRequested: isPlaybackRequested,
            hasAudioRequests: hasAudioRequests,
            isChatLoading: isChatLoading,
            isChatPriming: isChatPriming,
            isWaitingForToolAuthorization: isWaitingForToolAuthorization
        )
    }
}
