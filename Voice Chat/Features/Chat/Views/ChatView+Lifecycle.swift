//
//  ChatView+Lifecycle.swift
//  Voice Chat
//
//  Created by OpenAI on 2026.06.14.
//

import SwiftUI

extension ChatView {
    func handleChatViewAppear() {
        initialRenderCoordinator.begin()
        prepareSessionPresentation()
    }

    func handleChatViewDisappear() {
        visibleMessageController.cancelHydration()
        scrollInteractionState.clearNavigation()
        cancelOverflowTransitionScroll()
        expectAssistantResponseHaptics = false
        didTriggerResponseStartHaptic = false
#if os(iOS) || os(macOS) || os(visionOS)
        imageImportDriver.cancelAll()
        imageImportDriver.cleanupPendingPreview()
#endif
    }

    func handleSessionTransition() {
        initialRenderCoordinator.begin()
        prepareSessionPresentation()
    }

    private func prepareSessionPresentation() {
        resetScrollMetricsForSessionTransition()
        refreshVisibleMessages(hydrating: true)
        scheduleSearchNavigationIfNeeded(chatSessionsViewModel.searchNavigationTarget)
    }

    func handleBranchTransition() {
        resetHistoryScrollAnchor()
        // Branch snapshots are replaced atomically by the visible-message
        // controller. Keep the current snapshot on screen while any missing
        // fingerprints are prepared instead of restarting the initial
        // presentation gate and blanking the entire conversation.
        refreshVisibleMessages()
    }

    func handleVisibleMessageCountChange() {
        guard initialRenderCoordinator.isReady else { return }
        if consumeScrollToBottomAfterSendIfNeeded() {
            return
        }
        if attemptSearchTargetScroll() {
            return
        }
        // Message counts arrive before the new rows have been laid out.
        // Geometry owns bottom following once those rows have their actual size.
    }

    func handleInitialContentReady() {
        guard initialRenderCoordinator.isReady else { return }
        // Geometry owns size-change anchoring. An explicit bottom command here
        // can resolve against a page's placeholder height and later overwrite
        // the offset for its fully rendered content.
        revealOlderMessagesIfNeeded()
        _ = attemptSearchTargetScroll(animated: false)
    }

    func handleScrollViewAppear() {
        DispatchQueue.main.async {
            if !attemptSearchTargetScroll(),
               !scrollInteractionState.hasSearchInterruption(
                   currentTarget: currentSearchNavigationTarget()
               ) {
                if !initialRenderCoordinator.isReady {
                    return
                }
                if consumeScrollToBottomAfterSendIfNeeded(animated: false) {
                    return
                }
                if shouldUseBottomScrollAnchor {
                    scrollToBottom(animated: false)
                }
            }
        }
    }

    var textHapticsEnabled: Bool {
        !voiceOverlayVM.isPresented
    }

    func triggerTextHaptic(_ event: AppHapticEvent) {
        guard textHapticsEnabled else { return }
        AppHaptics.trigger(event)
    }
}
