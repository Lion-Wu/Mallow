import XCTest
@testable import Mallow

final class TTSPlaybackStateTests: XCTestCase {
    func testPlaybackFullyLoadedTracksRealtimeFinalizationAndOutstandingRequests() {
        let pendingRealtime = TTSPlaybackState(
            textSegmentCount: 1,
            audioChunkIsLoaded: [true],
            chunkDurations: [1],
            currentChunkIndex: 1,
            isRealtimeMode: true,
            realtimeFinalized: false
        )
        XCTAssertFalse(pendingRealtime.isPlaybackFullyLoaded)

        let finalizedRealtime = TTSPlaybackState(
            textSegmentCount: 1,
            audioChunkIsLoaded: [true],
            chunkDurations: [1],
            currentChunkIndex: 1,
            isRealtimeMode: true,
            realtimeFinalized: true
        )
        XCTAssertTrue(finalizedRealtime.isPlaybackFullyLoaded)

        let queuedRequest = TTSPlaybackState(
            textSegmentCount: 0,
            audioChunkIsLoaded: [],
            chunkDurations: [],
            inFlightIndexes: [0]
        )
        XCTAssertFalse(queuedRequest.isPlaybackFullyLoaded)
    }

    func testRealtimePlaybackCannotFinishBeforeStreamFinalization() {
        let pendingRealtime = TTSPlaybackState(
            textSegmentCount: 1,
            audioChunkIsLoaded: [true],
            chunkDurations: [1],
            currentTime: 1,
            totalDuration: 1,
            isRealtimeMode: true,
            realtimeFinalized: false
        )
        let finalizedRealtime = TTSPlaybackState(
            textSegmentCount: 1,
            audioChunkIsLoaded: [true],
            chunkDurations: [1],
            currentTime: 1,
            totalDuration: 1,
            isRealtimeMode: true,
            realtimeFinalized: true
        )

        XCTAssertFalse(pendingRealtime.playbackFinished)
        XCTAssertFalse(pendingRealtime.playbackFinished(at: 1))
        XCTAssertTrue(finalizedRealtime.playbackFinished)
    }
}
