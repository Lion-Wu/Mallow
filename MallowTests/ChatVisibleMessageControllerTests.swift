import XCTest
@testable import Mallow

@MainActor
final class ChatVisibleMessageControllerTests: XCTestCase {
    func testHydratingRefreshPublishesVisibleMessagesAndFingerprints() async {
        let controller = ChatVisibleMessageController()
        let sessionID = uuid(71)
        let first = chatMessage(id: uuid(72), content: "first")
        let editingBase = chatMessage(id: uuid(73), content: "editing")
        let hidden = chatMessage(id: uuid(74), content: "hidden")
        let reporter = VisibleMessageCountReporter()

        controller.refreshVisibleMessages(
            orderedMessages: [first, editingBase, hidden],
            editingBaseMessageID: editingBase.id,
            sessionID: sessionID,
            hydrating: true,
            onVisibleCountChange: reporter.append(_:)
        )

        await waitForVisibleMessageCount(1, in: controller)

        XCTAssertEqual(controller.visibleMessages.map(\.id), [first.id])
        XCTAssertEqual(controller.fingerprintCache[first.id], ContentFingerprint.make("first"))
        XCTAssertNil(controller.fingerprintCache[editingBase.id])
        XCTAssertNil(controller.fingerprintCache[hidden.id])
        XCTAssertEqual(reporter.counts, [1])
    }

    func testRefreshDefersWhileHydratingThenAppliesLatestMessages() async {
        let controller = ChatVisibleMessageController()
        let sessionID = uuid(75)
        let initial = chatMessage(id: uuid(76), content: "initial")
        let added = chatMessage(id: uuid(77), content: "added")
        let reporter = VisibleMessageCountReporter()

        controller.refreshVisibleMessages(
            orderedMessages: [initial],
            editingBaseMessageID: nil,
            sessionID: sessionID,
            hydrating: true,
            onVisibleCountChange: reporter.append(_:)
        )
        controller.refreshVisibleMessages(
            orderedMessages: [initial, added],
            editingBaseMessageID: nil,
            sessionID: sessionID,
            onVisibleCountChange: reporter.append(_:)
        )

        await waitForVisibleMessageCount(2, in: controller)

        XCTAssertEqual(controller.visibleMessages.map(\.id), [initial.id, added.id])
        XCTAssertEqual(controller.fingerprintCache[initial.id], ContentFingerprint.make("initial"))
        XCTAssertEqual(controller.fingerprintCache[added.id], ContentFingerprint.make("added"))
        XCTAssertEqual(reporter.counts, [1, 2])
    }

    func testRefreshDuringFingerprintAwaitCompletesHydrationAndAppliesPendingRefresh() async {
        let gate = ControlledFingerprintGate()
        let controller = ChatVisibleMessageController(
            fingerprintBuilder: { snapshots in
                await gate.wait()
                return Dictionary(uniqueKeysWithValues: snapshots.map {
                    ($0.0, ContentFingerprint.make($0.1))
                })
            }
        )
        let sessionID = uuid(79)
        let initial = chatMessage(id: uuid(80), content: "initial")
        let added = chatMessage(id: uuid(81), content: "added")
        let reporter = VisibleMessageCountReporter()

        controller.refreshVisibleMessages(
            orderedMessages: [initial],
            editingBaseMessageID: nil,
            sessionID: sessionID,
            hydrating: true,
            onVisibleCountChange: reporter.append(_:)
        )
        await waitForFingerprintBuilderStart(gate)

        controller.refreshVisibleMessages(
            orderedMessages: [initial, added],
            editingBaseMessageID: nil,
            sessionID: sessionID,
            onVisibleCountChange: reporter.append(_:)
        )

        XCTAssertTrue(controller.isHydratingSession)
        await gate.open()
        await waitForVisibleMessageCount(2, in: controller)

        XCTAssertFalse(controller.isHydratingSession)
        XCTAssertEqual(controller.visibleMessages.map(\.id), [initial.id, added.id])
        XCTAssertEqual(controller.fingerprintCache[added.id], ContentFingerprint.make("added"))
        XCTAssertEqual(reporter.counts, [1, 2])
    }

    func testCancelledHydrationCannotPublishOverReplacementHydration() async {
        let gate = ControlledFingerprintGate()
        let controller = ChatVisibleMessageController(
            fingerprintBuilder: { snapshots in
                await gate.wait()
                return Dictionary(uniqueKeysWithValues: snapshots.map {
                    ($0.0, ContentFingerprint.make($0.1))
                })
            }
        )
        let sessionID = uuid(82)
        let stale = chatMessage(id: uuid(83), content: "stale")
        let stalePending = chatMessage(id: uuid(90), content: "stale pending")
        let replacement = chatMessage(id: uuid(84), content: "replacement")
        let reporter = VisibleMessageCountReporter()

        controller.refreshVisibleMessages(
            orderedMessages: [stale],
            editingBaseMessageID: nil,
            sessionID: sessionID,
            hydrating: true,
            onVisibleCountChange: reporter.append(_:)
        )
        await waitForFingerprintBuilderStart(gate)
        controller.refreshVisibleMessages(
            orderedMessages: [stale, stalePending],
            editingBaseMessageID: nil,
            sessionID: sessionID,
            onVisibleCountChange: reporter.append(_:)
        )

        controller.cancelHydration()
        controller.refreshVisibleMessages(
            orderedMessages: [replacement],
            editingBaseMessageID: nil,
            sessionID: sessionID,
            hydrating: true,
            onVisibleCountChange: reporter.append(_:)
        )
        controller.applyContentFingerprintUpdate(
            messageID: replacement.id,
            fingerprint: ContentFingerprint.make(replacement.content)
        )
        await gate.open()
        await waitForVisibleMessageCount(1, in: controller)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertFalse(controller.isHydratingSession)
        XCTAssertEqual(controller.visibleMessages.map(\.id), [replacement.id])
        XCTAssertNil(controller.fingerprintCache[stale.id])
        XCTAssertNil(controller.fingerprintCache[stalePending.id])
        XCTAssertEqual(
            controller.fingerprintCache[replacement.id],
            ContentFingerprint.make("replacement")
        )
    }

    func testReplacementHydrationDiscardsPendingRefreshOwnedByPreviousGeneration() async {
        let gate = ControlledFingerprintGate()
        let controller = ChatVisibleMessageController(
            fingerprintBuilder: { snapshots in
                await gate.wait()
                return Dictionary(uniqueKeysWithValues: snapshots.map {
                    ($0.0, ContentFingerprint.make($0.1))
                })
            }
        )
        let staleSessionID = uuid(85)
        let replacementSessionID = uuid(86)
        let stale = chatMessage(id: uuid(87), content: "stale")
        let stalePending = chatMessage(id: uuid(88), content: "stale pending")
        let replacement = chatMessage(id: uuid(89), content: "replacement")
        let reporter = VisibleMessageCountReporter()

        controller.refreshVisibleMessages(
            orderedMessages: [stale],
            editingBaseMessageID: nil,
            sessionID: staleSessionID,
            hydrating: true,
            onVisibleCountChange: reporter.append(_:)
        )
        await waitForFingerprintBuilderStart(gate)
        controller.refreshVisibleMessages(
            orderedMessages: [stale, stalePending],
            editingBaseMessageID: nil,
            sessionID: staleSessionID,
            onVisibleCountChange: reporter.append(_:)
        )

        controller.refreshVisibleMessages(
            orderedMessages: [replacement],
            editingBaseMessageID: nil,
            sessionID: replacementSessionID,
            hydrating: true,
            onVisibleCountChange: reporter.append(_:)
        )
        await gate.open()
        await waitForVisibleMessageCount(1, in: controller)

        XCTAssertFalse(controller.isHydratingSession)
        XCTAssertEqual(controller.visibleMessages.map(\.id), [replacement.id])
        XCTAssertNil(controller.fingerprintCache[stale.id])
        XCTAssertNil(controller.fingerprintCache[stalePending.id])
        XCTAssertEqual(
            controller.fingerprintCache[replacement.id],
            ContentFingerprint.make("replacement")
        )
    }

    private func waitForFingerprintBuilderStart(_ gate: ControlledFingerprintGate) async {
        for _ in 0..<200 {
            if await gate.hasWaiter {
                return
            }
            await Task.yield()
        }
        XCTFail("Fingerprint builder did not start")
    }

    private func waitForVisibleMessageCount(_ expectedCount: Int, in controller: ChatVisibleMessageController) async {
        for _ in 0..<200 where controller.isHydratingSession || controller.visibleMessages.count != expectedCount {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

@MainActor
private final class VisibleMessageCountReporter {
    private(set) var counts: [Int] = []

    func append(_ count: Int) {
        counts.append(count)
    }
}

private actor ControlledFingerprintGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var hasWaiter: Bool {
        !waiters.isEmpty
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
