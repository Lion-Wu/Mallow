//
//  ChatVisibleMessageController.swift
//  Mallow
//
//  Created by Codex on 2026/6/13.
//

import Combine
import Foundation

@MainActor
final class ChatVisibleMessageController {
    typealias FingerprintBuilder = @Sendable (
        [(UUID, String)]
    ) async -> [UUID: ContentFingerprint]

    let presentation = ChatMessageListPresentation()
    private var contentStates: [UUID: ChatMessageContentState] = [:]

    var visibleMessages: [ChatMessage] {
        presentation.visibleMessages
    }

    var fingerprintCache: [UUID: ContentFingerprint] {
        state.fingerprintCache
    }

    var isHydratingSession: Bool {
        presentation.isHydratingSession
    }

    private var state = ChatVisibleMessageHydrationState()
    private var pendingRefresh: PendingRefresh?
    private let fingerprintBuilder: FingerprintBuilder
    private var onHydrationStateChange: @MainActor @Sendable (Bool) -> Void = { _ in }

    init(fingerprintBuilder: FingerprintBuilder? = nil) {
        self.fingerprintBuilder = fingerprintBuilder ?? { snapshots in
            await Task.detached(priority: .userInitiated) {
                let fingerprints = Self.buildFingerprints(from: snapshots)
                let renderSnapshots = snapshots.compactMap { entry -> (UUID, String, ContentFingerprint)? in
                    guard let fingerprint = fingerprints[entry.0] else { return nil }
                    return (entry.0, entry.1, fingerprint)
                }
                MessageRenderCache.shared.prewarmThinkParts(renderSnapshots)
                return fingerprints
            }.value
        }
    }

    func refreshVisibleMessages(
        orderedMessages: [ChatMessage],
        editingBaseMessageID: UUID?,
        sessionID: UUID,
        hydrating: Bool = false,
        onVisibleCountChange: @MainActor @Sendable @escaping (Int) -> Void,
        onHydrationStateChange: @MainActor @Sendable @escaping (Bool) -> Void = { _ in }
    ) {
        self.onHydrationStateChange = onHydrationStateChange
        if !hydrating, state.deferRefreshIfHydrating() {
            pendingRefresh = PendingRefresh(
                ownerToken: state.refreshGeneration,
                orderedMessages: orderedMessages,
                editingBaseMessageID: editingBaseMessageID,
                sessionID: sessionID,
                onVisibleCountChange: onVisibleCountChange
            )
            publishStateSnapshot()
            return
        }
        if !hydrating {
            pendingRefresh = nil
        }

        let token = state.nextRefreshToken()
        if hydrating {
            beginHydration(
                orderedMessages: orderedMessages,
                editingBaseMessageID: editingBaseMessageID,
                sessionID: sessionID,
                token: token,
                onVisibleCountChange: onVisibleCountChange
            )
            return
        }

        let newVisible = ChatVisibleMessagesCoordinator.visibleMessages(
            from: orderedMessages,
            editingBaseMessageID: editingBaseMessageID
        )

        updateVisibleMessages(newVisible, sessionID: sessionID, token: token, onVisibleCountChange: onVisibleCountChange)
    }

    func applyContentFingerprintUpdate(messageID: UUID, fingerprint: ContentFingerprint) {
        guard state.fingerprintCache[messageID] != fingerprint else { return }
        state.applyContentFingerprintUpdate(messageID: messageID, fingerprint: fingerprint)
        contentStates[messageID]?.update(fingerprint)
    }

    func contentState(for messageID: UUID) -> ChatMessageContentState {
        if let existing = contentStates[messageID] { return existing }
        let content = ChatMessageContentState(fingerprint: state.fingerprintCache[messageID])
        contentStates[messageID] = content
        return content
    }

    func cancelHydration() {
        pendingRefresh = nil
        state.cancelHydration()
        onHydrationStateChange(false)
        publishStateSnapshot()
    }

    private func beginHydration(
        orderedMessages: [ChatMessage],
        editingBaseMessageID: UUID?,
        sessionID: UUID,
        token: UUID,
        onVisibleCountChange: @MainActor @Sendable @escaping (Int) -> Void
    ) {
        let target = ChatVisibleMessagesCoordinator.visibleMessages(
            from: orderedMessages,
            editingBaseMessageID: editingBaseMessageID
        )

        pendingRefresh = nil
        state.beginHydration(token: token)
        onHydrationStateChange(true)
        publishStateSnapshot()
        MessageRenderCache.shared.clear()

        let snapshots = ChatVisibleMessagesCoordinator.fingerprintSnapshots(from: target)
        let buildFingerprints = fingerprintBuilder
        let fingerprintTask = Task {
            await buildFingerprints(snapshots)
        }

        state.hydrationTask = Task { @MainActor [weak self, target, fingerprintTask, token] in
            guard let self else { return }
            let fingerprints = await fingerprintTask.value
            guard !Task.isCancelled,
                  state.shouldApply(token: token) else {
                return
            }
            // Publish one complete ordering. Progressive prefixes repeatedly
            // rebuild layout and are not viewport-based loading.
            state.appendHydratedMessages(target)
            state.applyHydratedFingerprints(fingerprints)
            finalizeVisibleState(targetCount: target.count, sessionID: sessionID, onVisibleCountChange: onVisibleCountChange)

            guard state.finishHydration(token: token) else { return }
            onHydrationStateChange(false)
            publishStateSnapshot()

            if state.consumePendingRefreshAfterHydration() {
                let refresh = pendingRefresh.flatMap { pending in
                    pending.ownerToken == token ? pending : nil
                } ?? PendingRefresh(
                    ownerToken: token,
                    orderedMessages: orderedMessages,
                    editingBaseMessageID: editingBaseMessageID,
                    sessionID: sessionID,
                    onVisibleCountChange: onVisibleCountChange
                )
                pendingRefresh = nil
                publishStateSnapshot()
                refreshVisibleMessages(
                    orderedMessages: refresh.orderedMessages,
                    editingBaseMessageID: refresh.editingBaseMessageID,
                    sessionID: refresh.sessionID,
                    onVisibleCountChange: refresh.onVisibleCountChange
                )
            }
        }
        publishStateSnapshot()
    }

    private func updateVisibleMessages(
        _ newVisible: [ChatMessage],
        sessionID: UUID,
        token: UUID,
        onVisibleCountChange: @MainActor @Sendable @escaping (Int) -> Void
    ) {
        let newVisibleCopy = newVisible
        let plan = ChatVisibleMessagesCoordinator.fingerprintPlan(
            for: newVisibleCopy,
            cache: state.fingerprintCache
        )

        if plan.missingSnapshots.isEmpty {
            state.applyVisibleMessagesWithoutMissingFingerprints(
                newVisibleCopy,
                visibleIDs: plan.visibleIDs
            )
            finalizeVisibleState(targetCount: newVisibleCopy.count, sessionID: sessionID, onVisibleCountChange: onVisibleCountChange)
            publishStateSnapshot()
            return
        }

        Task { @MainActor [weak self, plan, newVisibleCopy, token] in
            guard let self else { return }
            let newFingerprints = await fingerprintBuilder(
                plan.missingSnapshots
            )
            guard state.shouldApply(token: token) else { return }

            state.applyVisibleMessagesWithMissingFingerprints(
                newVisibleCopy,
                newFingerprints: newFingerprints,
                visibleIDs: plan.visibleIDs
            )
            finalizeVisibleState(targetCount: newVisibleCopy.count, sessionID: sessionID, onVisibleCountChange: onVisibleCountChange)
            publishStateSnapshot()
        }
    }

    private func finalizeVisibleState(
        targetCount: Int,
        sessionID: UUID,
        onVisibleCountChange: @MainActor @Sendable (Int) -> Void
    ) {
        if state.shouldReportVisibleCount(targetCount: targetCount, sessionID: sessionID) {
            onVisibleCountChange(targetCount)
        }
    }

    private func publishStateSnapshot() {
        let previousStartID = presentation.publishedState.firstRenderedMessageID
        let startID: UUID?
        if let previousStartID, state.visibleMessages.contains(where: { $0.id == previousStartID }) {
            startID = previousStartID
        } else if let previousStartID,
                  let previousIndex = presentation.visibleMessages.firstIndex(where: { $0.id == previousStartID }),
                  !state.visibleMessages.isEmpty {
            // A branch can replace the first rendered message. Preserve the
            // expanded history boundary instead of collapsing back to the tail.
            startID = state.visibleMessages[min(previousIndex, state.visibleMessages.count - 1)].id
        } else {
            startID = state.visibleMessages.last(where: \.isUser)?.id ?? state.visibleMessages.last?.id
        }
        let next = PublishedState(
            visibleMessages: state.visibleMessages,
            firstRenderedMessageID: startID,
            isHydratingSession: state.isHydratingSession
        )
        for (id, content) in contentStates {
            content.update(state.fingerprintCache[id])
        }
        guard !presentation.publishedState.isEquivalent(to: next) else { return }
        let ids = Set(state.visibleMessages.map(\.id))
        contentStates = contentStates.filter { ids.contains($0.key) }
        presentation.publishedState = next
    }

    nonisolated private static func buildFingerprints(from snapshots: [(UUID, String)]) -> [UUID: ContentFingerprint] {
        var map: [UUID: ContentFingerprint] = [:]
        map.reserveCapacity(snapshots.count)
        for snap in snapshots {
            map[snap.0] = ContentFingerprint.make(snap.1)
        }
        return map
    }
}

@MainActor
final class ChatMessageContentState: ObservableObject {
    @Published private(set) var fingerprint: ContentFingerprint?

    init(fingerprint: ContentFingerprint?) {
        self.fingerprint = fingerprint
    }

    func update(_ fingerprint: ContentFingerprint?) {
        guard self.fingerprint != fingerprint else { return }
        self.fingerprint = fingerprint
    }
}

@MainActor
final class ChatMessageListPresentation: ObservableObject {
    @Published fileprivate var publishedState = PublishedState()

    var visibleMessages: [ChatMessage] { publishedState.visibleMessages }
    var isHydratingSession: Bool { publishedState.isHydratingSession }
    var renderedMessages: ArraySlice<ChatMessage> { visibleMessages[firstRenderedIndex...] }

    private var firstRenderedIndex: Int {
        visibleMessages.firstIndex { $0.id == publishedState.firstRenderedMessageID } ?? 0
    }

    @discardableResult
    func revealMessage(_ id: UUID) -> Bool {
        guard let index = visibleMessages.firstIndex(where: { $0.id == id }),
              index < firstRenderedIndex else { return false }
        publishedState.firstRenderedMessageID = id
        return true
    }

    @discardableResult
    func revealOlderMessages(viewportHeight: CGFloat, contentHeight: CGFloat) -> Bool {
        let start = firstRenderedIndex
        guard start > 0, viewportHeight > 0, contentHeight > 0 else { return false }
        let averageHeight = contentHeight / CGFloat(visibleMessages.count - start)
        let requiredHeight = max(viewportHeight, 2 * viewportHeight - contentHeight)
        let count = max(1, Int(ceil(requiredHeight / max(averageHeight, 1))))
        publishedState.firstRenderedMessageID = visibleMessages[max(0, start - count)].id
        return true
    }
}

fileprivate struct PublishedState {
    var visibleMessages: [ChatMessage] = []
    var firstRenderedMessageID: UUID?
    var isHydratingSession = false

    func isEquivalent(to other: PublishedState) -> Bool {
        guard isHydratingSession == other.isHydratingSession,
              firstRenderedMessageID == other.firstRenderedMessageID,
              visibleMessages.count == other.visibleMessages.count else {
            return false
        }
        return zip(visibleMessages, other.visibleMessages).allSatisfy {
            $0.id == $1.id && $0 === $1
        }
    }
}

private struct PendingRefresh {
    let ownerToken: UUID
    let orderedMessages: [ChatMessage]
    let editingBaseMessageID: UUID?
    let sessionID: UUID
    let onVisibleCountChange: @MainActor @Sendable (Int) -> Void
}
