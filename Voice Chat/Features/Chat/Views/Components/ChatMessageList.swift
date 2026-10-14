//
//  ChatMessageList.swift
//  Voice Chat
//
//  Created by Codex on 2026.06.13.
//

import SwiftUI

@MainActor
struct ChatMessageList: View, Equatable {
    nonisolated let visibleMessageController: ChatVisibleMessageController
    @ObservedObject var presentation: ChatMessageListPresentation
    @Environment(\.chatInitialRenderCoordinator) private var initialRenderCoordinator
    nonisolated let historyAnchorMessageID: UUID?
    nonisolated let branchRenderEpoch: Int
    nonisolated let isLoading: Bool
    nonisolated let streamingAssistantMessageID: UUID?
    nonisolated let isPriming: Bool
    nonisolated let isToolContinuationLoading: Bool
    nonisolated let isRetrying: Bool
    nonisolated let retryAttempt: Int
    nonisolated let retryLastError: String?
    nonisolated let longWaitNotice: ChatStreamLongWaitNotice?
    nonisolated let messageToolActivities: [UUID: [ChatToolActivity]]
    nonisolated let messageToolActivityPlacements: [UUID: [ChatToolActivityPlacement]]
    nonisolated let developerModeEnabled: Bool
    nonisolated let activeSearchHighlightTargetID: UUID?
    nonisolated let availableMessageWidth: CGFloat
    nonisolated let messageListBottomInset: CGFloat
    nonisolated let horizontalPadding: CGFloat
    nonisolated let topPadding: CGFloat
    nonisolated let isInitialContentReady: Bool
    let searchHighlightQuery: (ChatMessage) -> String?
    let onSelectText: (String) -> Void
    let onRegenerate: (ChatMessage) -> Void
    let onEditUserMessage: (ChatMessage) -> Void
    let onSwitchVersion: (ChatMessage) -> Void
    let onRetry: (ChatMessage) -> Void
    let onLongWaitRetry: () -> Void
    let onAuthorizeTool: (String, Bool) -> Void

    // Scroll-position changes rebuild the parent, but do not change list inputs.
    // Presentation and individual content observers still publish their own updates.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.visibleMessageController === rhs.visibleMessageController
            && lhs.historyAnchorMessageID == rhs.historyAnchorMessageID
            && lhs.branchRenderEpoch == rhs.branchRenderEpoch
            && lhs.isLoading == rhs.isLoading
            && lhs.streamingAssistantMessageID == rhs.streamingAssistantMessageID
            && lhs.isPriming == rhs.isPriming
            && lhs.isToolContinuationLoading == rhs.isToolContinuationLoading
            && lhs.isRetrying == rhs.isRetrying
            && lhs.retryAttempt == rhs.retryAttempt
            && lhs.retryLastError == rhs.retryLastError
            && lhs.longWaitNotice == rhs.longWaitNotice
            && lhs.messageToolActivities == rhs.messageToolActivities
            && lhs.messageToolActivityPlacements == rhs.messageToolActivityPlacements
            && lhs.developerModeEnabled == rhs.developerModeEnabled
            && lhs.activeSearchHighlightTargetID == rhs.activeSearchHighlightTargetID
            && lhs.availableMessageWidth == rhs.availableMessageWidth
            && lhs.messageListBottomInset == rhs.messageListBottomInset
            && lhs.horizontalPadding == rhs.horizontalPadding
            && lhs.topPadding == rhs.topPadding
            && lhs.isInitialContentReady == rhs.isInitialContentReady
    }

    private var visibleMessages: ArraySlice<ChatMessage> {
        presentation.renderedMessages
    }

    // Bound the dependency graph affected by one row's changing height. The
    // boundaries use full-transcript indices, so prepending a rendered page or
    // appending a message does not move existing rows between hosting roots.
    private var messageGroups: [ChatMessageGroup] {
        let groupSize = 32
        var groups: [ChatMessageGroup] = []
        var start = visibleMessages.startIndex
        while start < visibleMessages.endIndex {
            let groupID = start / groupSize
            let end = min((groupID + 1) * groupSize, visibleMessages.endIndex)
            groups.append(ChatMessageGroup(id: groupID, messages: visibleMessages[start..<end]))
            start = end
        }
        return groups
    }

    var body: some View {
        core
            .task(id: presentation.renderedMessages.first?.id) {
                guard let initialRenderCoordinator, !initialRenderCoordinator.isReady,
                      !presentation.isHydratingSession else { return }
                let generation = initialRenderCoordinator.generation
                await Task.yield()
                guard !Task.isCancelled else { return }
                initialRenderCoordinator.finishCollecting(generation: generation)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .frame(maxWidth: contentColumnMaxWidth(availableWidth: availableMessageWidth))
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var core: some View {
        let historyAnchorID = historyAnchorMessageID ?? visibleMessages.first?.id
        let visibleMessageIDs = Set(visibleMessages.map(\.id))
        let statusHostID = inlineStatusHostMessageID(in: Array(visibleMessages))
        let animationKey = ChatMessageListAnimationKey(
            messageIDs: presentation.visibleMessages.map(\.id),
            standaloneStatus: standaloneStatusAnimationKey(
                statusHostID: statusHostID
            )
        )

        return VStack(spacing: 0) {
            ForEach(messageGroups) { group in
                ChatMessageGroupHost(
                    inputs: ChatMessageGroupInputs(
                        rows: group.messages.map { rowInputs($0, visibleMessageIDs: visibleMessageIDs, statusHostID: statusHostID) },
                        historyAnchorID: historyAnchorID
                    ),
                    width: max(0, contentColumnMaxWidth(availableWidth: availableMessageWidth) - 2 * horizontalPadding)
                ) {
                    VStack(spacing: 0) {
                        ForEach(group.messages, id: \.id) { message in
                            messageContent(message, visibleMessageIDs: visibleMessageIDs, statusHostID: statusHostID)
                                .modifier(ChatMessageGeometry(
                                    messageID: message.id,
                                    isHistoryAnchor: message.id == historyAnchorID,
                                    isSearchTarget: searchHighlightQuery(message) != nil,
                                    coordinateSpace: "ChatMessageGroup"
                                ))
                                .transition(ChatScrollContentMotion.transition)
                        }
                    }
                }
                .transition(ChatScrollContentMotion.transition)
            }

            if statusHostID == nil, isRetrying {
                AssistantAlignedRetryingBubble(
                    attempt: retryAttempt,
                    lastError: retryLastError,
                    maxBubbleWidth: availableMessageWidth
                )
                .padding(.bottom, 12)
                .transition(ChatScrollContentMotion.transition)
            } else if statusHostID == nil, let longWaitNotice {
                AssistantAlignedLongWaitBubble(
                    notice: longWaitNotice,
                    onRetry: onLongWaitRetry,
                    maxBubbleWidth: availableMessageWidth
                )
                .padding(.bottom, 12)
                .transition(ChatScrollContentMotion.transition)
            }
            ChatAnimatedStatus(isPresented: statusHostID == nil && !isRetrying && longWaitNotice == nil && (isPriming || isToolContinuationLoading)) {
                AssistantAlignedLoadingBubble(maxBubbleWidth: availableMessageWidth)
                    .padding(.bottom, 12)
            }

            Color.clear
                .frame(height: messageListBottomInset)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ChatScrollMeasurementsKey.self,
                            value: ChatScrollMeasurements(bottomAnchorMaxY: proxy.frame(in: .named("ChatScroll")).maxY)
                        )
                    }
                }
        }
        .coordinateSpace(name: "ChatContent")
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ChatScrollMeasurementsKey.self,
                    value: ChatScrollMeasurements(
                        contentHeight: proxy.size.height,
                        initialRenderGeneration: initialRenderCoordinator?.layoutGeneration
                    )
                )
            }
        }
        .animation(
            isInitialContentReady
                ? ChatScrollContentMotion.animation
                : nil,
            value: animationKey
        )
    }

    private func rowInputs(_ message: ChatMessage, visibleMessageIDs: Set<UUID>, statusHostID: UUID?) -> ChatMessageRowInputs {
        let isStatusHost = statusHostID == message.id
        let highlightQuery = searchHighlightQuery(message)
        return ChatMessageRowInputs(
            contentControllerID: ObjectIdentifier(visibleMessageController),
            messageID: message.id,
            branchRenderEpoch: branchRenderEpoch,
            isStreamingAssistant: isLoading && message.id == streamingAssistantMessageID,
            isInlineStatusHost: isStatusHost,
            isRetrying: isStatusHost && isRetrying,
            retryAttempt: isStatusHost && isRetrying ? retryAttempt : 0,
            retryLastError: isStatusHost && isRetrying ? retryLastError : nil,
            longWaitNotice: isStatusHost ? longWaitNotice : nil,
            toolActivities: messageToolActivities[message.id] ?? [],
            toolActivityPlacements: messageToolActivityPlacements[message.id] ?? [],
            developerModeEnabled: developerModeEnabled,
            searchHighlightQuery: highlightQuery,
            searchHighlightID: highlightQuery == nil ? nil : activeSearchHighlightTargetID,
            availableMessageWidth: availableMessageWidth,
            isInitialContentReady: isInitialContentReady,
            isParentVisible: message.parentMessage.map { visibleMessageIDs.contains($0.id) } ?? false
        )
    }

    private func messageContent(_ message: ChatMessage, visibleMessageIDs: Set<UUID>, statusHostID: UUID?) -> some View {
        ChatMessageContentObserver(
            state: visibleMessageController.contentState(for: message.id)
        ) { fingerprint in
            if !shouldInlineErrorMessage(message, visibleMessageIDs: visibleMessageIDs) {
                messageRow(for: message, fingerprint: fingerprint, inlineStatusHostID: statusHostID)
                    .padding(.bottom, 12)
            }
        }
    }

    private func standaloneStatusAnimationKey(statusHostID: UUID?) -> String {
        guard statusHostID == nil else { return "inline" }
        if isRetrying {
            return "retry-\(retryAttempt)-\(retryLastError ?? "")"
        }
        if let longWaitNotice {
            return "long-wait-\(String(describing: longWaitNotice))"
        }
        return isPriming || isToolContinuationLoading ? "loading" : "none"
    }

    private func messageRow(for message: ChatMessage, fingerprint: ContentFingerprint?, inlineStatusHostID: UUID?) -> some View {
        let isStreamingAssistant = isLoading && message.id == streamingAssistantMessageID
        let isInlineStatusHost = inlineStatusHostID == message.id
        let showButtons = !(isStreamingAssistant || isInlineStatusHost)
        let fingerprint = fingerprint ?? ContentFingerprint.make(message.renderFingerprintSource)
        let highlightQuery = searchHighlightQuery(message)
        let searchHighlightID = highlightQuery == nil ? nil : activeSearchHighlightTargetID
        let messageActivityPlacements = mergedToolActivityPlacements(for: message)
        let messageActivities = mergedToolActivities(
            storedPlacements: message.toolActivityPlacements,
            runtimeActivities: messageToolActivities[message.id] ?? [],
            mergedPlacements: messageActivityPlacements
        )
        let inlineErrorMessage = inlineErrorMessage(for: message)
        let inlineErrorFingerprint = inlineErrorMessage.map { ContentFingerprint.make($0.content) }
        let key = VoiceMessageEqKey(
            id: message.id,
            isUser: message.isUser,
            isActive: message.isActive,
            imageAttachmentsFP: message.imageAttachmentsFingerprint,
            branchRenderEpoch: branchRenderEpoch,
            showActionButtons: showButtons,
            layoutWidth: availableMessageWidth.rounded(),
            contentFP: fingerprint,
            inlineErrorFP: inlineErrorFingerprint,
            inlineLoading: isInlineStatusHost && !isRetrying && longWaitNotice == nil,
            inlineRetryAttempt: isInlineStatusHost && isRetrying ? retryAttempt : nil,
            inlineRetryLastError: isInlineStatusHost && isRetrying ? retryLastError : nil,
            inlineLongWaitNotice: isInlineStatusHost && !isRetrying ? longWaitNotice : nil,
            toolActivityPlacements: messageActivityPlacements,
            developerModeEnabled: developerModeEnabled,
            searchHighlightID: searchHighlightID
        )

        return EquatableRender(value: key) {
            VoiceMessageView(
                message: message,
                isStreamingAssistant: isStreamingAssistant,
                showActionButtons: showButtons,
                developerModeEnabled: developerModeEnabled,
                maxBubbleWidth: availableMessageWidth,
                contentFingerprint: fingerprint,
                inlineErrorMessage: inlineErrorMessage,
                inlineLoading: isInlineStatusHost && !isRetrying && longWaitNotice == nil,
                inlineRetryAttempt: isInlineStatusHost && isRetrying ? retryAttempt : nil,
                inlineRetryLastError: isInlineStatusHost && isRetrying ? retryLastError : nil,
                inlineLongWaitNotice: isInlineStatusHost && !isRetrying ? longWaitNotice : nil,
                toolActivities: messageActivities,
                toolActivityPlacements: messageActivityPlacements,
                searchHighlightQuery: highlightQuery,
                onSelectText: onSelectText,
                onRegenerate: onRegenerate,
                onEditUserMessage: onEditUserMessage,
                onSwitchVersion: onSwitchVersion,
                onRetry: onRetry,
                onLongWaitRetry: onLongWaitRetry,
                onAuthorizeTool: onAuthorizeTool
            )
        }
        .equatable()
    }

    private func inlineStatusHostMessageID(in messages: [ChatMessage]) -> UUID? {
        ChatInlineStatusHostResolver.resolve(
            in: messages,
            hasTransientStatus: isRetrying || longWaitNotice != nil || isPriming || isToolContinuationLoading
        )
    }

    private func shouldInlineErrorMessage(_ message: ChatMessage, visibleMessageIDs: Set<UUID>) -> Bool {
        guard message.content.hasPrefix("!error:"),
              let parent = message.parentMessage,
              !parent.isUser,
              visibleMessageIDs.contains(parent.id),
              parent.activeChildMessageID == message.id else {
            return false
        }
        return true
    }

    private func inlineErrorMessage(for message: ChatMessage) -> ChatMessage? {
        guard !message.isUser,
              !message.content.hasPrefix("!error:"),
              let activeChildMessageID = message.activeChildMessageID else {
            return nil
        }
        return message.childMessages.first {
            $0.id == activeChildMessageID && $0.content.hasPrefix("!error:")
        }
    }

    private func mergedToolActivityPlacements(for message: ChatMessage) -> [ChatToolActivityPlacement] {
        var merged = message.toolActivityPlacements
        for placement in messageToolActivityPlacements[message.id] ?? [] {
            if let index = merged.firstIndex(where: { $0.id == placement.id }) {
                merged[index] = placement
            } else {
                merged.append(placement)
            }
        }
        return merged
    }

    private func mergedToolActivities(
        storedPlacements: [ChatToolActivityPlacement],
        runtimeActivities: [ChatToolActivity],
        mergedPlacements: [ChatToolActivityPlacement]
    ) -> [ChatToolActivity] {
        var activities = storedPlacements.map(\.activity)
        for activity in runtimeActivities {
            if let index = activities.firstIndex(where: { $0.id == activity.id }) {
                activities[index] = activity
            } else {
                activities.append(activity)
            }
        }
        var placementOrder: [String: Int] = [:]
        for (index, placement) in mergedPlacements.enumerated() where placementOrder[placement.id] == nil {
            placementOrder[placement.id] = index
        }
        return activities.sorted {
            let lhs = placementOrder[$0.id] ?? Int.max
            let rhs = placementOrder[$1.id] ?? Int.max
            if lhs == rhs {
                return $0.id < $1.id
            }
            return lhs < rhs
        }
    }
}

/// Evaluates message-dependent properties inside the row's observation scope.
/// Streaming content does not invalidate the list or inspect unrelated messages.
private struct ChatMessageContentObserver<Content: View>: View {
    @ObservedObject var state: ChatMessageContentState
    @ViewBuilder let content: (ContentFingerprint?) -> Content

    var body: some View {
        content(state.fingerprint)
    }
}

struct ChatMessageListAnimationKey: Equatable {
    let messageIDs: [UUID]
    let standaloneStatus: String
}

enum ChatInlineStatusHostResolver {
    static func resolve(
        in messages: [ChatMessage],
        hasTransientStatus: Bool
    ) -> UUID? {
        guard hasTransientStatus else { return nil }
        return messages.last(where: {
            !$0.isUser && $0.isActive && !$0.content.hasPrefix("!error:")
        })?.id
    }
}

// Row inputs are independent of scroll position and message content updates.
// Each group bridges only its changed inputs into its native hosting root.
private struct ChatMessageRowInputs: Equatable, Sendable {
    let contentControllerID: ObjectIdentifier
    let messageID: UUID
    let branchRenderEpoch: Int
    let isStreamingAssistant: Bool
    let isInlineStatusHost: Bool
    let isRetrying: Bool
    let retryAttempt: Int
    let retryLastError: String?
    let longWaitNotice: ChatStreamLongWaitNotice?
    let toolActivities: [ChatToolActivity]
    let toolActivityPlacements: [ChatToolActivityPlacement]
    let developerModeEnabled: Bool
    let searchHighlightQuery: String?
    let searchHighlightID: UUID?
    let availableMessageWidth: CGFloat
    let isInitialContentReady: Bool
    let isParentVisible: Bool
}

private struct ChatMessageGroup: Identifiable {
    let id: Int
    let messages: ArraySlice<ChatMessage>
}

private struct ChatMessageGroupInputs: Equatable, Sendable {
    let rows: [ChatMessageRowInputs]
    let historyAnchorID: UUID?
}

// Group-local preferences must not merge with transcript-space measurements
// through the native hosting preference bridge.
private struct ChatMessageGroupMeasurementsKey: PreferenceKey {
    static var defaultValue: ChatScrollMeasurements { ChatScrollMeasurements() }

    static func reduce(value: inout ChatScrollMeasurements, nextValue: () -> ChatScrollMeasurements) {
        ChatScrollMeasurementsKey.reduce(value: &value, nextValue: nextValue)
    }
}

@MainActor
private struct ChatMessageGroupHost<Content: View>: View {
    let inputs: ChatMessageGroupInputs
    let width: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var measurements = ChatScrollMeasurements()

    var body: some View {
        ChatMessageRowHost(inputs: inputs, width: width, onMeasurements: { measurements = $0 }) {
            content().coordinateSpace(name: "ChatMessageGroup")
        }
        .equatable()
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ChatScrollMeasurementsKey.self,
                    value: translatedMeasurements(origin: geometry.frame(in: .named("ChatContent")).origin)
                )
            }
        }
    }

    private func translatedMeasurements(origin: CGPoint) -> ChatScrollMeasurements {
        var translated = ChatScrollMeasurements()
        if let anchor = measurements.historyAnchor {
            translated.historyAnchor = ChatHistoryAnchor(messageID: anchor.messageID, positionY: anchor.positionY + origin.y)
        }
        if let target = measurements.searchTarget {
            translated.searchTarget = ChatSearchTargetGeometry(
                messageID: target.messageID,
                frame: target.frame.offsetBy(dx: origin.x, dy: origin.y)
            )
        }
        return translated
    }
}

private struct ChatMessageGeometry: ViewModifier {
    let messageID: UUID
    let isHistoryAnchor: Bool
    let isSearchTarget: Bool
    let coordinateSpace: String

    func body(content: Content) -> some View {
        content.background {
            if isHistoryAnchor || isSearchTarget {
                GeometryReader { geometry in
                    let frame = geometry.frame(in: .named(coordinateSpace))
                    Color.clear.preference(
                        key: ChatMessageGroupMeasurementsKey.self,
                        value: ChatScrollMeasurements(
                            historyAnchor: isHistoryAnchor ? ChatHistoryAnchor(messageID: messageID, positionY: frame.minY) : nil,
                            searchTarget: isSearchTarget ? ChatSearchTargetGeometry(messageID: messageID, frame: frame) : nil
                        )
                    )
                }
            }
        }
    }
}

@MainActor
private struct ChatMessageRowHost<Content: View>: Equatable {
    let inputs: ChatMessageGroupInputs
    let width: CGFloat
    var onMeasurements: ((ChatScrollMeasurements) -> Void)? = nil
    @ViewBuilder let content: () -> Content

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // Content and SwiftData observations live inside the host. Only changed
        // row inputs should update hosted content and invalidate intrinsic sizing.
        lhs.inputs == rhs.inputs && lhs.width == rhs.width
    }

    @MainActor
    final class Coordinator {
        let content = HostedContent()
        weak var initialRender: ChatInitialRenderCoordinator?
        var generation: UInt64?
        private var sources: ChatInitialRenderSources?
        private var actualSize: CGSize?
        private var messageIDs: [UUID] = []
        private var width: CGFloat?

        func configure(_ next: ChatInitialRenderCoordinator?, messageIDs: [UUID], width: CGFloat) {
            guard initialRender !== next || generation != next?.generation
                    || self.messageIDs != messageIDs || self.width != width else { return }
            cancel()
            sources = nil
            initialRender = next
            generation = next?.generation
            self.messageIDs = messageIDs
            self.width = width
            // Reconfirm groups that gained rows, preserving acknowledgements for
            // unchanged groups whose measurement preferences will not fire again.
            if let next, let generation {
                next.beginHosting(self, generation: generation)
            }
        }

        func finish(_ sources: ChatInitialRenderSources) {
            self.sources = sources
            finishIfLaidOut()
        }

        func laidOut(size: CGSize) {
            actualSize = size
            finishIfLaidOut()
        }

        private func finishIfLaidOut() {
            // Parsed content and the native host's bounds arrive separately.
            // A placeholder-sized host must not release the presentation gate.
            guard let sources, let contentSize = sources.size, let actualSize,
                  sources.rendered.isSuperset(of: sources.renderers) else { return }
            #if os(macOS)
            // NSHostingView rounds its intrinsic size up to whole points; the
            // SwiftUI geometry preference still reports the fractional size.
            let expectedSize = CGSize(width: ceil(contentSize.width), height: ceil(contentSize.height))
            #else
            let expectedSize = contentSize
            #endif
            guard abs(expectedSize.width - actualSize.width) <= 0.5,
                  abs(expectedSize.height - actualSize.height) <= 0.5 else { return }
            initialRender?.finishHosting(self, sources: sources)
        }

        func cancel() {
            guard let generation else { return }
            initialRender?.finishHosting(self, sources: ChatInitialRenderSources(generation: generation))
        }
    }

    @Observable
    final class HostedContent {
        var view = AnyView(EmptyView())
    }

    private struct HostingRoot: View {
        let content: HostedContent

        var body: some View { content.view }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeRoot(environment: EnvironmentValues, coordinator: Coordinator) -> AnyView {
        coordinator.content.view = root(environment: environment, coordinator: coordinator)
        return AnyView(HostingRoot(content: coordinator.content))
    }

    private func updateRoot(environment: EnvironmentValues, coordinator: Coordinator, transaction: Transaction) {
        // Keep the hosting root stable so inserted rows receive the original
        // SwiftUI transaction instead of losing their insertion transition.
        withTransaction(transaction) {
            coordinator.content.view = root(environment: environment, coordinator: coordinator)
        }
    }

    private func root(environment: EnvironmentValues, coordinator: Coordinator) -> AnyView {
        coordinator.configure(environment.chatInitialRenderCoordinator, messageIDs: inputs.rows.map(\.messageID), width: width)
        let generation = environment.chatInitialRenderCoordinator?.isReady == false
            ? coordinator.generation : nil
        return AnyView(
            content()
                .environment(\.self, environment)
                .frame(width: width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    if let generation {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ChatInitialRenderSourcesKey.self,
                                value: ChatInitialRenderSources(generation: generation, size: geometry.size)
                            )
                        }
                    }
                }
                // The native host can still be animating its previous height.
                // Accept that height without recentering the newly expanded rows.
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .onPreferenceChange(ChatMessageGroupMeasurementsKey.self) { measurements in
                    onMeasurements?(measurements)
                }
                .onPreferenceChange(ChatInitialRenderSourcesKey.self) { [weak coordinator] sources in
                    if let sources { coordinator?.finish(sources) }
                }
        )
    }
}

#if os(macOS)
extension ChatMessageRowHost: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> ChatRowNSHostingController {
        let host = ChatRowNSHostingController(rootView: makeRoot(environment: context.environment, coordinator: context.coordinator))
        host.onLayout = { [weak coordinator = context.coordinator] size in coordinator?.laidOut(size: size) }
        host.sizingOptions = [.intrinsicContentSize]
        host.safeAreaRegions = []
        return host
    }

    func updateNSViewController(_ host: ChatRowNSHostingController, context: Context) {
        updateRoot(environment: context.environment, coordinator: context.coordinator, transaction: context.transaction)
    }

    static func dismantleNSViewController(_ host: ChatRowNSHostingController, coordinator: Coordinator) {
        coordinator.cancel()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController host: ChatRowNSHostingController, context: Context) -> CGSize? {
        host.view.intrinsicContentSize
    }
}
#else
extension ChatMessageRowHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ChatRowUIHostingController {
        let host = ChatRowUIHostingController(rootView: makeRoot(environment: context.environment, coordinator: context.coordinator))
        host.onLayout = { [weak coordinator = context.coordinator] size in coordinator?.laidOut(size: size) }
        // Publish size changes through the controller's container-sizing path.
        // Intrinsic-size invalidation alone can leave the parent at the initial
        // placeholder height after asynchronous Markdown rendering completes.
        host.sizingOptions = [.preferredContentSize]
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        return host
    }

    func updateUIViewController(_ host: ChatRowUIHostingController, context: Context) {
        updateRoot(environment: context.environment, coordinator: context.coordinator, transaction: context.transaction)
    }

    static func dismantleUIViewController(_ host: ChatRowUIHostingController, coordinator: Coordinator) {
        coordinator.cancel()
    }
}
#endif

#if os(macOS)
@MainActor
private final class ChatRowNSHostingController: NSHostingController<AnyView> {
    var onLayout: ((CGSize) -> Void)?

    override func viewDidLayout() {
        super.viewDidLayout()
        onLayout?(view.bounds.size)
    }
}
#else
@MainActor
private final class ChatRowUIHostingController: UIHostingController<AnyView> {
    var onLayout: ((CGSize) -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?(view.bounds.size)
    }
}
#endif
