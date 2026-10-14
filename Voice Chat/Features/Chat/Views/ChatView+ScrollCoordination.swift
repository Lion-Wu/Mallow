//
//  ChatView+ScrollCoordination.swift
//  Voice Chat
//
//  Created by OpenAI on 2026.06.14.
//

import SwiftUI

extension ChatView {
    var visibleMessages: [ChatMessage] {
        visibleMessageController.visibleMessages
    }

    func refreshVisibleMessages(hydrating: Bool = false) {
        visibleMessageController.refreshVisibleMessages(
            orderedMessages: viewModel.orderedMessagesCached(),
            editingBaseMessageID: viewModel.editingBaseMessageID,
            sessionID: viewModel.chatSession.id,
            hydrating: hydrating,
            onVisibleCountChange: { count in
                if visibleMessageCount != count {
                    visibleMessageCount = count
                }
                onMessagesCountChange(count)
            },
            onHydrationStateChange: { isHydrating in
                if isHydratingSession != isHydrating {
                    isHydratingSession = isHydrating
                }
            }
        )
    }

    static func visibleSearchText(for message: ChatMessage) -> String {
        message.assistantText
    }

    func visibleSearchSnapshots() -> [ChatSearchScrollMessageSnapshot] {
        visibleMessages.map {
            ChatSearchScrollMessageSnapshot(id: $0.id, searchText: Self.visibleSearchText(for: $0))
        }
    }

    func currentSearchNavigationTarget() -> ChatSearchNavigationTarget? {
        guard let target = chatSessionsViewModel.searchNavigationTarget,
              target.sessionID == viewModel.chatSession.id else {
            return nil
        }
        return target
    }

    func searchHighlightQuery(for message: ChatMessage) -> String? {
        scrollInteractionState.highlightQuery(
            for: message.id,
            currentTarget: currentSearchNavigationTarget()
        )
    }

    func scheduleSearchNavigationIfNeeded(_ target: ChatSearchNavigationTarget?) {
        if target?.sessionID != viewModel.chatSession.id {
            scrollStateStorage.searchScrollDecision = nil
        }
        guard scrollInteractionState.scheduleSearchNavigationIfNeeded(
            target,
            sessionID: viewModel.chatSession.id
        ) else { return }

        cancelOverflowTransitionScroll()
        _ = attemptSearchTargetScroll(animated: initialRenderCoordinator.isReady)
    }

    func resetScrollMetricsForSessionTransition() {
        scrollStateStorage.searchScrollDecision = nil
        scrollStateStorage.latestViewportMetrics = nil
        scrollState.resetForSessionTransition()
        scrollPosition = ScrollPosition(edge: .bottom)
        resetHistoryScrollAnchor()
        scrollStateStorage.hasUserScrolled = false
        scrollStateStorage.isFollowingBottom = true
        scrollStateStorage.isUserScrollActive = false
        showScrollToBottomButton = false
    }

    func scrollToBottomAfterOverflowTransitionIfNeeded(wasPastComposerOverflowThreshold: Bool) {
        guard canActivateComposerOverflowBottomAnchor else { return }
        guard !wasPastComposerOverflowThreshold, shouldTriggerComposerOverflowScroll else { return }
        guard !scrollInteractionState.hasSearchInterruption(currentTarget: currentSearchNavigationTarget()) else {
            return
        }

        scrollState.requestOverflowTransitionScrollToBottom()
    }

    func cancelOverflowTransitionScroll() {
        scrollState.cancelOverflowTransitionScroll()
    }

    @discardableResult
    func consumeOverflowTransitionScrollToBottomIfNeeded() -> Bool {
        scrollToBottomForOverflowTransitionIfReady()
    }

    @discardableResult
    func scrollToBottomForOverflowTransitionIfReady() -> Bool {
        let decision = scrollState.consumeOverflowTransitionScrollToBottomIfReady(
            metrics: currentScrollMetrics,
            hasSearchInterruption: scrollInteractionState.hasSearchInterruption(
                currentTarget: currentSearchNavigationTarget()
            ),
            hasViewport: scrollStateStorage.latestViewportMetrics != nil
        )
        guard decision == .scrollToBottom else {
            return false
        }

        if !scrollStateStorage.isFollowingBottom {
            scrollToBottom(animated: initialRenderCoordinator.isReady)
        }
        return true
    }

    func requestScrollToBottomAfterSend() {
        scrollStateStorage.searchScrollDecision = nil
        scrollState.requestScrollToBottomAfterSend(
            visibleCount: visibleMessages.count,
            bottomMessageID: visibleMessages.last?.id
        )
        scrollInteractionState.prepareScrollToBottomAfterSend()
    }

    func cancelScrollToBottomAfterSend() {
        scrollState.cancelScrollToBottomAfterSend()
    }

    @discardableResult
    func consumeScrollToBottomAfterSendIfNeeded(animated: Bool = true) -> Bool {
        guard scrollState.consumeScrollToBottomAfterSendIfReady(
            visibleCount: visibleMessages.count,
            bottomMessageID: visibleMessages.last?.id,
            hasViewport: scrollStateStorage.latestViewportMetrics != nil
        ) else { return false }

        // An existing bottom follower will move with the new row's geometry.
        // Do not overwrite that target with the pre-insertion content height.
        if !scrollStateStorage.isFollowingBottom {
            scrollToBottom(animated: animated)
        }
        return true
    }

    @discardableResult
    func attemptSearchTargetScroll(animated: Bool = true) -> Bool {
        guard initialRenderCoordinator.isReady || initialRenderCoordinator.layoutGeneration != nil else {
            return false
        }
        guard let decision = ChatSearchScrollCoordinator.resolveScrollTarget(
            pending: scrollInteractionState.pendingSearchScrollTarget,
            sessionID: viewModel.chatSession.id,
            visibleMessages: visibleSearchSnapshots()
        ),
              scrollStateStorage.latestViewportMetrics != nil else {
            return false
        }

        resetHistoryScrollAnchor()
        scrollStateStorage.isFollowingBottom = false
        if scrollStateStorage.searchScrollDecision?.targetID != decision.targetID {
            scrollStateStorage.lastSearchScrollOffset = nil
        }
        scrollStateStorage.searchScrollDecision = decision
        scrollStateStorage.animateSearchScroll = animated
        // The target can be outside the mounted history window. Its geometry
        // acknowledges insertion and subsequent asynchronous Markdown layout.
        visibleMessageController.presentation.revealMessage(decision.messageID)
        if let metrics = scrollStateStorage.latestViewportMetrics {
            _ = applySearchScroll(using: metrics)
        }
        return true
    }

    func updateScrollMetrics(_ metrics: ChatScrollViewportMetrics) {
        scrollStateStorage.latestViewportMetrics = metrics
        // Scroll geometry is owned by the scroll container. UIKit-backed SwiftUI
        // scroll views do not reliably emit KVO notifications for their bounds.
        markdownViewportCoordinator.invalidateViewport()
        let viewportChanged = abs(metrics.viewportHeight - scrollState.viewportHeight) > 0.5
        let layoutChanged = abs(metrics.contentHeight - scrollState.contentHeight) > 0.5 || viewportChanged
        // Layout growth temporarily increases the distance to the bottom;
        // only user motion can change the reader's follow intent.
        if scrollStateStorage.isUserScrollActive, !layoutChanged {
            scrollStateStorage.isFollowingBottom = metrics.bottomAnchorMaxY - metrics.viewportHeight <= 1
        }
        let contentOffsetY = metrics.contentHeight - metrics.bottomAnchorMaxY + layoutMetrics.messageListTopPadding
        // Content-space anchors do not depend on scroll position. Combining
        // an asynchronously reported row frame with a newer viewport offset
        // would turn ordinary scrolling into repeated prepend compensation.
        let measuredAnchor = metrics.historyAnchor
        var prependedHeight: CGFloat = 0
        if let retained = scrollStateStorage.retainedHistoryAnchor,
           let measuredAnchor, retained.messageID == measuredAnchor.messageID {
            prependedHeight = measuredAnchor.positionY - retained.positionY
            scrollStateStorage.retainedHistoryAnchor = measuredAnchor
        }
        scrollStateStorage.measuredHistoryAnchor = measuredAnchor
        if isExpandingHistory {
            if scrollStateStorage.retainedHistoryAnchor != nil {
                // Wait for the retained row to move before another page can
                // load; content height can arrive before its anchor geometry.
                if abs(prependedHeight) > 0.5 { isExpandingHistory = false }
            } else if abs(metrics.contentHeight - scrollState.contentHeight) > 0.5 {
                isExpandingHistory = false
            }
        }
        enqueueScrollMetricUpdate(
            contentHeight: metrics.contentHeight,
            viewportHeight: metrics.viewportHeight,
            bottomAnchorMaxY: metrics.bottomAnchorMaxY
        )
        if !initialRenderCoordinator.isReady,
           let generation = metrics.initialRenderGeneration,
           initialRenderCoordinator.layoutGeneration == generation {
            // Filling an undersized initial page is part of initial layout, not
            // a visible history insertion after the transcript has appeared.
            if metrics.contentHeight < metrics.viewportHeight,
               visibleMessageController.presentation.renderedMessages.startIndex > 0,
               !scrollInteractionState.hasSearchInterruption(currentTarget: currentSearchNavigationTarget()) {
                initialRenderCoordinator.beginCollecting()
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    _ = visibleMessageController.presentation.revealOlderMessages(
                        viewportHeight: metrics.viewportHeight,
                        contentHeight: metrics.contentHeight
                    )
                }
                return
            }
            _ = attemptSearchTargetScroll(animated: false)
            let positionIsReady: Bool
            if let decision = scrollStateStorage.searchScrollDecision {
                positionIsReady = metrics.searchTarget?.messageID == decision.messageID
                    && scrollStateStorage.lastSearchScrollOffset.map { abs($0 - contentOffsetY) <= 0.5 } == true
            } else {
                positionIsReady = scrollInteractionState.pendingSearchScrollTarget == nil
                    && metrics.bottomAnchorMaxY <= metrics.viewportHeight + 0.5
            }
            // The outer layout and its initial scroll position are separate
            // commits. Enable interaction only after both are acknowledged.
            if positionIsReady, let generation = metrics.initialRenderGeneration {
                initialRenderCoordinator.markTranscriptLaidOut(generation: generation)
            }
        }
        if applySearchScroll(using: metrics) { return }
        let shouldAnchorBottom = layoutChanged
            && scrollStateStorage.isFollowingBottom
            && !scrollInteractionState.hasSearchInterruption(currentTarget: currentSearchNavigationTarget())
        if shouldAnchorBottom {
            #if os(iOS)
            // Let the scroll view follow keyboard safe-area changes in the system's
            // layout transaction. An explicit offset here interrupts that animation.
            if viewportChanged, initialRenderCoordinator.isReady { return }
            #endif
            let target = max(0, metrics.contentHeight + layoutMetrics.messageListTopPadding - metrics.viewportHeight)
            if initialRenderCoordinator.isReady, target >= contentOffsetY || viewportChanged, viewModel.isLoading || !viewportChanged {
                // Final text layout and footer insertion can follow request completion.
                // Keep their bottom-follow animation continuous with streamed growth.
                withAnimation(.easeOut(duration: 0.25)) {
                    scrollPosition.scrollTo(y: target)
                }
            } else {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                // A shrinking message layout already supplies intermediate heights. Following
                // them directly keeps the offset inside the current scrollable bounds.
                withTransaction(transaction) { scrollPosition.scrollTo(y: target) }
            }
            return
        }
        if abs(prependedHeight) > 0.5 {
            // Prepending history preserves the reader's position and gesture velocity.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            transaction.scrollPositionUpdatePreservesVelocity = true
            withTransaction(transaction) {
                scrollPosition.scrollTo(y: contentOffsetY + prependedHeight)
            }
            return
        }
        revealOlderMessagesIfNeeded()
    }

    private func applySearchScroll(using metrics: ChatScrollViewportMetrics) -> Bool {
        guard let decision = scrollStateStorage.searchScrollDecision,
              let target = metrics.searchTarget, target.messageID == decision.messageID else { return false }
        let contentOffsetY = metrics.contentHeight - metrics.bottomAnchorMaxY + layoutMetrics.messageListTopPadding
        let anchorY = CGFloat(decision.anchorY)
        let nextOffset = min(
            max(0, metrics.contentHeight + layoutMetrics.messageListTopPadding - metrics.viewportHeight),
            max(0, layoutMetrics.messageListTopPadding + target.frame.minY + anchorY * (target.frame.height - metrics.viewportHeight))
        )
        if scrollInteractionState.pendingSearchScrollTarget != nil {
            scrollInteractionState.applySearchScrollDecision(decision)
        }
        // Intermediate animation offsets do not change the destination. Only
        // a new target or a change in its measured layout requires positioning.
        if let previousOffset = scrollStateStorage.lastSearchScrollOffset,
           abs(previousOffset - nextOffset) <= 0.5 { return true }
        scrollStateStorage.lastSearchScrollOffset = nextOffset
        let animated = scrollStateStorage.animateSearchScroll
        scrollStateStorage.animateSearchScroll = false
        if abs(nextOffset - contentOffsetY) > 0.5 {
            var transaction = Transaction(animation: animated ? .easeInOut(duration: 0.28) : nil)
            transaction.disablesAnimations = !animated
            withTransaction(transaction) { scrollPosition.scrollTo(y: nextOffset) }
        }
        return true
    }

    func revealOlderMessagesIfNeeded() {
        // An active search highlight can remain while the reader browses older
        // history. Only an unapplied search jump conflicts with prepending rows.
        guard initialRenderCoordinator.isReady, !isExpandingHistory,
              scrollInteractionState.pendingSearchScrollTarget == nil else { return }
        let metrics = currentScrollMetrics
        let distanceFromTop = max(0, metrics.contentHeight - metrics.bottomAnchorMaxY)
        guard metrics.contentHeight < metrics.viewportHeight
                || (scrollStateStorage.hasUserScrolled && distanceFromTop < metrics.viewportHeight) else { return }
        if scrollStateStorage.retainedHistoryAnchor == nil,
           scrollStateStorage.hasUserScrolled,
           metrics.contentHeight >= metrics.viewportHeight,
           let anchor = scrollStateStorage.measuredHistoryAnchor {
            historyAnchorMessageID = anchor.messageID
            scrollStateStorage.retainedHistoryAnchor = anchor
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isExpandingHistory = visibleMessageController.presentation.revealOlderMessages(
                viewportHeight: metrics.viewportHeight,
                contentHeight: metrics.contentHeight
            )
        }
    }

    func enqueueScrollMetricUpdate(
        contentHeight nextContentHeight: CGFloat? = nil,
        viewportHeight nextViewportHeight: CGFloat? = nil,
        bottomAnchorMaxY nextBottomAnchorMaxY: CGFloat? = nil
    ) {
        scrollState.enqueueMetricUpdate(
            contentHeight: nextContentHeight,
            viewportHeight: nextViewportHeight,
            bottomAnchorMaxY: nextBottomAnchorMaxY
        )

        applyPendingScrollMetricUpdate()
    }

    func applyPendingScrollMetricUpdate() {
        let update = scrollState.applyPendingMetricUpdate(
            messageListBottomInset: layoutMetrics.messageListBottomInset,
            threshold: scrollToBottomButtonVisibilityThreshold
        )

        if update.didUpdate {
            if update.didUpdateScrollableGeometry {
                scrollToBottomAfterOverflowTransitionIfNeeded(
                    wasPastComposerOverflowThreshold: update.wasPastComposerOverflowThreshold
                )
            }
            let didAutoScroll =
                consumeOverflowTransitionScrollToBottomIfNeeded()
                || (update.didUpdateScrollableGeometry && consumeScrollToBottomAfterSendIfNeeded(animated: initialRenderCoordinator.isReady))
            if didAutoScroll {
                hideScrollToBottomButton()
            } else {
                updateScrollToBottomVisibility()
            }
        }
    }

    func handleAccessibilityScroll(_ edge: Edge) {
        scrollStateStorage.searchScrollDecision = nil
        let metrics = currentScrollMetrics
        guard metrics.viewportHeight > 0 else { return }
        let offset = metrics.contentHeight - metrics.bottomAnchorMaxY + layoutMetrics.messageListTopPadding
        // Accessibility page actions also use leading/trailing for a vertical
        // scroll view: the previous-page action arrives with the trailing edge.
        let direction: CGFloat = edge == .top || edge == .trailing ? -1 : 1
        scrollStateStorage.hasUserScrolled = true
        let target = max(0, offset + direction * metrics.viewportHeight)
        scrollStateStorage.isFollowingBottom = target >= max(0, metrics.contentHeight + layoutMetrics.messageListTopPadding - metrics.viewportHeight)
        scrollPosition.scrollTo(y: target)
        // A page request at the top can leave the offset unchanged, so there
        // may be no geometry callback to start loading the previous page.
        revealOlderMessagesIfNeeded()
    }

    func handleScrollPhaseChange(_ phase: ScrollPhase) {
        let wasUserScrollActive = scrollStateStorage.isUserScrollActive
        scrollStateStorage.isUserScrollActive = phase == .tracking || phase == .interacting || phase == .decelerating
        if phase == .tracking || phase == .interacting {
            scrollStateStorage.searchScrollDecision = nil
            scrollStateStorage.hasUserScrolled = true
            scrollStateStorage.isFollowingBottom = false
            revealOlderMessagesIfNeeded()
        } else if phase == .idle, wasUserScrollActive {
            scrollStateStorage.isFollowingBottom = currentScrollMetrics.bottomAnchorDistanceBelowViewport <= 1
        }
    }

    func scrollToBottom(animated: Bool = true) {
        scrollStateStorage.searchScrollDecision = nil
        scrollStateStorage.isFollowingBottom = true
        guard let metrics = scrollStateStorage.latestViewportMetrics else { return }
        let action = {
            scrollPosition.scrollTo(y: max(0, metrics.contentHeight + layoutMetrics.messageListTopPadding - metrics.viewportHeight))
        }
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                action()
            }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction, action)
        }
    }

    func updateScrollToBottomVisibility() {
        guard currentScrollMetrics.viewportHeight > 0 else {
            hideScrollToBottomButton()
            return
        }

        // Content growth precedes bottom-follow positioning by a layout pass.
        // That transient distance does not mean the reader left the bottom.
        let shouldShow = !scrollStateStorage.isFollowingBottom
            && shouldShowScrollToBottomButtonForCurrentGeometry
        if shouldShow != showScrollToBottomButton {
            withAnimation(.easeInOut(duration: 0.2)) {
                showScrollToBottomButton = shouldShow
                scrollState.showScrollToBottomButton = shouldShow
            }
        }
    }

    func hideScrollToBottomButton() {
        if showScrollToBottomButton {
            showScrollToBottomButton = false
            scrollState.showScrollToBottomButton = false
        }
    }

    func updateAvailableMessageWidth(_ width: CGFloat) {
        let cleanedWidth = max(width, 0)
        guard abs(cleanedWidth - availableMessageWidth) > 0.5 else { return }
        resetHistoryScrollAnchor()
        availableMessageWidth = cleanedWidth
    }

    func resetHistoryScrollAnchor() {
        historyAnchorMessageID = nil
        scrollStateStorage.measuredHistoryAnchor = nil
        scrollStateStorage.retainedHistoryAnchor = nil
        isExpandingHistory = false
    }
}
