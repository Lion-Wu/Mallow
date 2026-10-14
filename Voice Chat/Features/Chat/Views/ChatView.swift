//
//  ChatView.swift
//  Voice Chat
//
//  Created by Lion Wu on 2024/1/8.
//

import SwiftUI
import SwiftStreamingMarkdown
import Foundation
import SwiftData

struct ChatView: View {
    @EnvironmentObject var chatSessionsViewModel: ChatSessionsViewModel
    @EnvironmentObject var audioManager: GlobalAudioManager
    @EnvironmentObject var errorCenter: AppErrorCenter
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject var viewModel: ChatViewModel
    @State var textFieldHeight: CGFloat = InputMetrics.defaultHeight
    @State var editingBannerHeight: CGFloat = 0
    @State var availableMessageWidth: CGFloat = 680
    @FocusState var isInputFocused: Bool

    @State var textSelectionSheetItem: TextSelectionSheetItem?

    @State var inputOverflow: Bool = false
    @State var showFullScreenComposer: Bool = false

    // High-frequency message geometry is imperative coordination state. Only the
    // derived visibility boolean below participates in SwiftUI observation.
    @State var scrollStateStorage = ChatScrollStateStorage()
    @State var showScrollToBottomButton: Bool = false
    // Track offsets and edges; message ID tracking is only needed for an explicit search jump.
    @State var scrollPosition = ScrollPosition(edge: .bottom)
    @State var isExpandingHistory = false
    @State var historyAnchorMessageID: UUID?
    @State var branchRenderEpoch: Int = 0
    @State var scrollInteractionState = ChatScrollInteractionState()
    @State var activeAlert: ChatAlert?
    @State var expectAssistantResponseHaptics: Bool = false
    @State var didTriggerResponseStartHaptic: Bool = false
    // The list observes structural presentation state; each row observes only its
    // own content state. The composer does not observe streamed fingerprints.
    @State var visibleMessageController = ChatVisibleMessageController()
    @State var visibleMessageCount: Int = 0
    @State var isHydratingSession: Bool = false
    @State var initialRenderCoordinator = ChatInitialRenderCoordinator()
    @State var markdownViewportCoordinator = MarkdownViewportCoordinator()
#if os(iOS) || os(macOS) || os(visionOS)
    @StateObject var imageImportDriver = ChatImageAttachmentImportDriver()
#endif

    // View model that coordinates the realtime voice overlay.
    @EnvironmentObject var voiceOverlayVM: VoiceChatOverlayViewModel

    var onMessagesCountChange: @MainActor @Sendable (Int) -> Void = { _ in }

    init(
        viewModel: ChatViewModel,
        onMessagesCountChange: @MainActor @Sendable @escaping (Int) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.onMessagesCountChange = onMessagesCountChange
    }

    var scrollState: ChatScrollState {
        get { scrollStateStorage.value }
        nonmutating set { scrollStateStorage.value = newValue }
    }

}
