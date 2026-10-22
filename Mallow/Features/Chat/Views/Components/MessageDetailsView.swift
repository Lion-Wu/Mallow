//
//  MessageDetailsView.swift
//  Mallow
//
//  Created by Lion Wu on 2026/01/07.
//

import SwiftUI

struct MessageDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    let message: ChatMessage
    let toolActivities: [ChatToolActivity]
    let toolActivityPlacements: [ChatToolActivityPlacement]
    let developerModeEnabled: Bool
    private let requestContextRows: [MessageDetailsRequestContextRow]

    init(
        message: ChatMessage,
        toolActivities: [ChatToolActivity] = [],
        toolActivityPlacements: [ChatToolActivityPlacement] = [],
        developerModeEnabled: Bool = false
    ) {
        self.message = message
        self.toolActivities = toolActivities
        self.toolActivityPlacements = toolActivityPlacements
        self.developerModeEnabled = developerModeEnabled
        self.requestContextRows = Self.makeRequestContextRows(for: message)
    }

    private enum MetricSourceBadge {
        case provider
        case local

        var icon: String {
            switch self {
            case .provider:
                return "cloud.fill"
            case .local:
                return "laptopcomputer"
            }
        }

        var color: Color {
            switch self {
            case .provider:
                return .blue
            case .local:
                return .secondary
            }
        }

        var legendText: LocalizedStringKey {
            switch self {
            case .provider:
                return "According to Model Provider"
            case .local:
                return "Recorded Locally"
            }
        }
    }

    private struct ToolTraceItem: Identifiable {
        let activity: ChatToolActivity
        let placement: ChatToolActivityPlacement?

        var id: String {
            activity.id
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                PlatformColor.groupedBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        sourceIndicatorsHeader
                        identitySection
                        branchingSection
                        sessionSection
                        contentSection
                        requestContextSection

                        if !message.isUser {
                            assistantGenerationSection
                            if message.generationRounds.isEmpty {
                                assistantTimingSection
                            } else {
                                generationRoundsSection
                            }
                            toolTraceSection
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 860, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .background(PlatformColor.groupedBackground)
#if os(iOS) || os(tvOS)
                .scrollContentBackground(.hidden)
#endif
            }
            .navigationTitle("Message Details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 640, minHeight: 640)
#endif
    }

    @ViewBuilder
    private var identitySection: some View {
        sectionBox("Identity", systemImage: "person.text.rectangle") {
            detailRow("Message ID", fieldKey: "id", source: .local) { valueCode(message.id.uuidString) }
            detailRow("Created At", fieldKey: "createdAt", source: message.createdAt == nil ? nil : .local) { valueDate(message.createdAt) }
            detailRow("Sender", fieldKey: "isUser", source: .local) { valueText(message.isUser ? String(localized: "User") : String(localized: "Assistant")) }
            detailRow("Active", fieldKey: "isActive", source: .local) { valueText(formatBool(message.isActive)) }
        }
    }

    @ViewBuilder
    private var branchingSection: some View {
        sectionBox("Branching", systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
            detailRow("Active Child Message ID", fieldKey: "activeChildMessageID", source: .local) { valueCode(formatUUID(message.activeChildMessageID)) }
            detailRow("Parent Message ID", fieldKey: "parentMessageID", source: .local) { valueCode(formatUUID(message.parentMessage?.id)) }
            detailRow("Child Messages", fieldKey: "childMessages.count", source: .local) { valueText("\(message.childMessages.count)") }

            if !message.childMessages.isEmpty {
                DisclosureGroup {
                    valueCode(message.childMessages.map(\.id.uuidString).joined(separator: "\n"))
                } label: {
                    fieldLabel("Child Message IDs", fieldKey: "childMessages[].id", source: .local)
                }
            }
        }
    }

    @ViewBuilder
    private var sessionSection: some View {
        sectionBox("Session", systemImage: "bubble.left.and.bubble.right") {
            detailRow("Chat Session ID", fieldKey: "session.id", source: .local) { valueCode(formatUUID(message.session?.id)) }
            detailRow("Chat Session Title", fieldKey: "session.title", source: .local) { valueText(message.session?.title) }
            detailRow("Active Root Message ID", fieldKey: "session.activeRootMessageID", source: .local) { valueCode(formatUUID(message.session?.activeRootMessageID)) }
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        sectionBox("Content", systemImage: "doc.text") {
            detailRow("Character Count", fieldKey: "characterCount", source: .local) { valueText("\(resolvedCharacterCount)") }
            detailRow("Image Attachments", fieldKey: "imageAttachments.count", source: .local) { valueText("\(message.imageAttachments.count)") }
            if !message.assistantSegments.isEmpty {
                detailRow("Assistant Segments", fieldKey: "assistantSegments", source: .local) {
                    valueCode(formatAssistantSegments(message.assistantSegments))
                }
            }
        }
    }

    @ViewBuilder
    private var requestContextSection: some View {
        sectionBox("Request Context", systemImage: "doc.text.magnifyingglass") {
            ForEach(requestContextRows) { row in
                requestContextRow(row)
            }
        }
    }

    @ViewBuilder
    private func requestContextRow(_ row: MessageDetailsRequestContextRow) -> some View {
        detailRow(row.title, fieldKey: row.fieldKey, source: .local) {
            switch row.value {
            case .text(let value):
                valueText(value)
            case .code(let value):
                valueCode(value)
            case .date(let value):
                valueDate(value)
            }
        }
    }

    @ViewBuilder
    private var generationRoundsSection: some View {
        sectionBox("Request Metadata", systemImage: "chart.xyaxis.line") {
            ForEach(Array(message.generationRounds.enumerated()), id: \.element.id) { index, round in
                DisclosureGroup {
                    generationRoundDetails(round)
                        .padding(.top, 8)
                } label: {
                    Text(String(format: String(localized: "Generation Round %d"), index + 1))
                        .font(.headline)
                }
            }
        }
    }

    @ViewBuilder
    private func generationRoundDetails(_ round: ChatGenerationRound) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            detailRow("Model Identifier", fieldKey: "requestedModel", source: .local) { valueCode(round.requestedModel) }
            if let model = round.providerModel {
                detailRow("Provider Model", fieldKey: "model", source: .provider) { valueCode(model) }
            }
            detailRow("Request ID", fieldKey: "id", source: .local) { valueCode(round.id.uuidString) }
            detailRow("Request URL", fieldKey: "requestURL", source: .local) { valueCode(round.requestURL) }
            detailRow("Request Style", fieldKey: "requestStyle", source: .local) { valueCode(round.requestStyle.rawValue) }
            detailRow("Requested Thinking Parameters", fieldKey: "requestedThinking", source: round.requestedThinking == nil ? nil : .local) {
                if let thinking = round.requestedThinking {
                    if thinking.isEmpty {
                        valueText(String(localized: "Default"))
                    } else {
                        valueCode(JSONValue.object(thinking).compactJSONString)
                    }
                } else {
                    valueText(nil)
                }
            }
            if !round.reportedThinking.isEmpty {
                detailRow("Reported Thinking Parameters", fieldKey: "providerFields", source: .provider) {
                    valueCode(JSONValue.object(round.reportedThinking).compactJSONString)
                }
            }
            if let previous = round.previousResponseID {
                detailRow("Request Previous Response ID", fieldKey: "previousResponseID", source: .local) { valueCode(previous) }
            }
            detailRow("Provider Response ID", fieldKey: "providerResponseID", source: round.providerResponseID == nil ? nil : .provider) { valueCode(round.providerResponseID) }
            detailRow("Finish Reason", fieldKey: "outcome", source: round.outcome == "completed" && round.finishReason != nil ? .provider : .local) { valueText(round.outcome == "completed" ? (round.finishReason ?? round.outcome) : round.outcome) }
            detailRow("Output Token Count", fieldKey: "usage.output_tokens", source: round.outputTokens == nil ? nil : .provider) { valueText(formatInt(round.outputTokens)) }
            if let input = round.inputTokens {
                detailRow(round.requestStyle == .anthropicMessages ? "Uncached Input Tokens" : "Input Token Count", fieldKey: "usage.input_tokens", source: .provider) { valueText(formatInt(input)) }
            }
            if let reasoning = round.reasoningTokens {
                detailRow("Reasoning Output Tokens", fieldKey: "usage.output_tokens_details", source: .provider) { valueText(formatInt(reasoning)) }
            }
            if let total = round.totalTokens {
                detailRow("Total Token Count", fieldKey: "usage.total_tokens", source: .provider) { valueText(formatInt(total)) }
            }
            if let cached = round.cachedTokens {
                detailRow("Cached Tokens", fieldKey: "usage.cached_tokens", source: .provider) { valueText(formatInt(cached)) }
            }
            if let written = round.cacheWriteTokens {
                detailRow("Cache Write Tokens", fieldKey: "usage.cache_write_tokens", source: .provider) { valueText(formatInt(written)) }
            }
            if let cost = round.reportedCost {
                detailRow("Reported Cost", fieldKey: "usage.cost", source: .provider) { valueText(formatDouble(cost, decimals: 8)) }
            }
            if let rate = round.providerTokensPerSecond {
                detailRow("Tokens Per Second", fieldKey: "tokens_per_second", source: .provider) { valueText(formatDouble(rate, decimals: 3)) }
            }
            if let ttft = round.providerTimeToFirstToken {
                detailRow("Time To First Token", fieldKey: "time_to_first_token_seconds", source: .provider) { valueText(formatInterval(ttft)) }
            }
            detailRow("Stream Started At", fieldKey: "startedAt", source: .local) { valueDate(round.startedAt) }
            detailRow("First Output At", fieldKey: "firstOutputAt", source: round.firstOutputAt == nil ? nil : .local) { valueDate(round.firstOutputAt) }
            detailRow("Stream Completed At", fieldKey: "endedAt", source: round.endedAt == nil ? nil : .local) { valueDate(round.endedAt) }
            detailRow("Time To First Output", fieldKey: "localTimeToFirstOutput", source: round.firstOutputAt == nil ? nil : .local) { valueText(formatInterval(round.localTimeToFirstOutput)) }
            detailRow("Response Duration", fieldKey: "localDuration", source: round.endedAt == nil ? nil : .local) { valueText(formatInterval(round.localDuration)) }
            if let created = round.providerCreatedAt {
                detailRow("Provider Created At", fieldKey: "created_at", source: .provider) { valueDate(created) }
            }
            if let completed = round.providerCompletedAt {
                detailRow("Provider Completed At", fieldKey: "completed_at", source: .provider) { valueDate(completed) }
            }
            if !round.toolCallIDs.isEmpty {
                detailRow("Tool Calls", fieldKey: "toolCallIDs", source: .provider) { valueCode(round.toolCallIDs.joined(separator: "\n")) }
            }
            if !round.providerFields.isEmpty {
                DisclosureGroup("Returned Provider Data") {
                    valueCode(JSONValue.object(round.providerFields).compactJSONString)
                }
            }
        }
    }

    @ViewBuilder
    private var assistantGenerationSection: some View {
        sectionBox("Generation", systemImage: "chart.xyaxis.line") {
            detailRow("Model Identifier", fieldKey: "modelIdentifier", source: .local) { valueCode(message.modelIdentifier) }
            detailRow("API Base URL", fieldKey: "apiBaseURL", source: .local) { valueCode(message.apiBaseURL) }
            detailRow("Thinking Setting", fieldKey: "thinkingOptionRawValue", source: .local) { valueText(formatThinkingOption(message.thinkingOptionRawValue)) }
            detailRow("Request ID", fieldKey: "requestID", source: .local) { valueCode(formatUUID(message.requestID)) }
            detailRow("Finish Reason", fieldKey: "finishReason", source: finishReasonSourceBadge) { valueText(message.finishReason) }
            detailRow("Error Description", fieldKey: "errorDescription", source: .local) { valueWrappedText(message.errorDescription) }
            if message.generationRounds.isEmpty {
                detailRow("Provider Response ID", fieldKey: "providerResponseID", source: message.providerResponseID == nil ? nil : .provider) { valueCode(message.providerResponseID) }
                if !message.providerResponseIDs.isEmpty {
                    detailRow("Provider Response IDs", fieldKey: "providerResponseIDs", source: .provider) {
                        valueCode(message.providerResponseIDs.enumerated().map { index, responseID in
                            "\(index + 1). \(responseID)"
                        }.joined(separator: "\n"))
                    }
                }
                detailRow("Output Token Count", fieldKey: "tokenCount", source: tokenCountSourceBadge) { valueText(formatInt(resolvedTokenCount)) }
                detailRow("Reasoning Output Tokens", fieldKey: "reasoningOutputTokenCount", source: reasoningTokenSourceBadge) { valueText(formatInt(message.reasoningOutputTokenCount)) }
                detailRow("Tokens Per Second", fieldKey: "tokensPerSecond", source: tokensPerSecondSourceBadge) { valueText(formatDouble(message.tokensPerSecondSource == "provider" ? message.tokensPerSecond : nil, decimals: 3)) }
                detailRow("Prompt Message Count", fieldKey: "promptMessageCount", source: message.promptMessageCount == nil ? nil : .local) { valueText(formatInt(message.promptMessageCount)) }
                detailRow("Prompt Character Count", fieldKey: "promptCharacterCount", source: message.promptCharacterCount == nil ? nil : .local) { valueText(formatInt(message.promptCharacterCount)) }
            }
        }
    }

    @ViewBuilder
    private var assistantTimingSection: some View {
        sectionBox("Timing", systemImage: "clock") {
            detailRow("Stream Started At", fieldKey: "streamStartedAt", source: message.streamStartedAt == nil ? nil : .local) { valueDate(message.streamStartedAt) }
            detailRow("First Token At", fieldKey: "streamFirstTokenAt", source: firstTokenAtSourceBadge) { valueDate(message.streamFirstTokenAt) }
            detailRow("Stream Completed At", fieldKey: "streamCompletedAt", source: message.streamCompletedAt == nil ? nil : .local) { valueDate(message.streamCompletedAt) }
            detailRow("Time To First Token", fieldKey: "timeToFirstToken", source: timeToFirstTokenSourceBadge) { valueText(formatInterval(message.timeToFirstToken)) }
            detailRow("Stream Duration", fieldKey: "streamDuration", source: message.streamDuration == nil ? nil : .local) { valueText(formatInterval(message.streamDuration)) }
            detailRow("Generation Duration", fieldKey: "generationDuration", source: message.generationDuration == nil ? nil : .local) { valueText(formatInterval(message.generationDuration)) }
        }
    }

    @ViewBuilder
    private func sectionBox<Content: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .labelStyle(.titleAndIcon)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(MessageDetailsChrome.sectionFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MessageDetailsChrome.sectionBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func detailRow<Value: View>(
        _ title: LocalizedStringKey,
        fieldKey: String,
        source: MetricSourceBadge? = nil,
        @ViewBuilder value: () -> Value
    ) -> some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 14) {
            fieldLabel(title, fieldKey: fieldKey, source: source)
                .frame(width: 240, alignment: .leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        #else
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(title, fieldKey: fieldKey, source: source)
            value()
        }
#endif
    }

    private func fieldLabel(_ title: LocalizedStringKey, fieldKey: String, source: MetricSourceBadge? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let source {
                    Image(systemName: source.icon)
                        .font(.caption2)
                        .foregroundStyle(source.color)
                }
            }
            Text(fieldKey)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospaced()
        }
    }

    private var toolTraceItems: [ToolTraceItem] {
        var seen = Set<String>()
        var items = toolActivityPlacements
            .sorted {
                if $0.offset == $1.offset {
                    return $0.id < $1.id
                }
                return $0.offset < $1.offset
            }
            .map { placement in
                seen.insert(placement.id)
                return ToolTraceItem(activity: placement.activity, placement: placement)
            }

        for activity in toolActivities.sorted(by: { $0.id < $1.id }) where !seen.contains(activity.id) {
            seen.insert(activity.id)
            items.append(ToolTraceItem(activity: activity, placement: nil))
        }
        return items
    }

    @ViewBuilder
    private var toolTraceSection: some View {
        sectionBox("Tool Trace", systemImage: "wrench.and.screwdriver") {
            let items = toolTraceItems
            detailRow("Tool Calls", fieldKey: "toolTrace.count", source: .local) {
                valueText(items.isEmpty ? String(localized: "None") : "\(items.count)")
            }

            if !items.isEmpty {
                detailRow("Used Tools", fieldKey: "toolTrace[].toolName", source: .local) {
                    valueCode(uniqueToolNames(from: items).joined(separator: "\n"))
                }

                ForEach(items) { item in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            detailRow("Activity ID", fieldKey: "toolTrace[].id", source: .local) {
                                valueCode(item.activity.id)
                            }
                            detailRow("Tool Name", fieldKey: "toolTrace[].toolName", source: .local) {
                                valueCode(item.activity.toolName)
                            }
                            detailRow("Title", fieldKey: "toolTrace[].title", source: .local) {
                                valueText(item.activity.title)
                            }
                            detailRow("Phase", fieldKey: "toolTrace[].phase", source: .local) {
                                valueText(formatToolPhase(item.activity.phase))
                            }
                            detailRow("Summary", fieldKey: "toolTrace[].summary", source: .local) {
                                valueWrappedText(item.activity.summary)
                            }
                            if let presentation = item.activity.presentation, !presentation.items.isEmpty {
                                detailRow("Displayed Items", fieldKey: "toolTrace[].presentation", source: .local) {
                                    ChatToolPresentationView(presentation: presentation)
                                }
                            }
                            if developerModeEnabled,
                               let resultPayload = item.activity.resultPayload,
                               !resultPayload.isEmpty {
                                detailRow("Result Payload", fieldKey: "toolTrace[].resultPayload", source: .local) {
                                    valueCode(JSONValue.object(resultPayload).debugPreviewJSONString(
                                        maxCharacters: 12_000,
                                        maxDepth: 8,
                                        maxCollectionItems: 80
                                    ))
                                }
                            }
                            detailRow("Placement Scope", fieldKey: "toolTrace[].scope", source: .local) {
                                valueText(item.placement?.scope.rawValue)
                            }
                            detailRow("Placement Offset", fieldKey: "toolTrace[].offset", source: .local) {
                                valueText(item.placement.map { "\($0.offset)" })
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: iconName(forToolName: item.activity.toolName))
                                .foregroundStyle(.secondary)
                            Text(item.activity.toolName)
                                .font(.subheadline.weight(.semibold))
                            Spacer(minLength: 8)
                            Text(formatToolPhase(item.activity.phase))
                                .font(.caption)
                                .foregroundStyle(color(for: item.activity.phase))
                        }
                    }
                }
            }
        }
    }

    private func sourceLegendRow(_ source: MetricSourceBadge) -> some View {
        HStack(spacing: 8) {
            Image(systemName: source.icon)
                .foregroundStyle(source.color)
                .font(.caption)
            Text(source.legendText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var sourceIndicatorsHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { sourceLegend }
            VStack(alignment: .leading, spacing: 8) { sourceLegend }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .appChromedContainer(cornerRadius: 10, shadowOpacity: 0.18)
    }

    private var sourceLegend: some View {
        Group {
            sourceLegendRow(.provider)
            sourceLegendRow(.local)
        }
    }

    private func metricSourceBadge(from raw: String?) -> MetricSourceBadge? {
        guard let raw else { return nil }
        switch raw {
        case "provider":
            return .provider
        case "local", "estimated":
            return .local
        default:
            return nil
        }
    }

    private var tokenCountSourceBadge: MetricSourceBadge? {
        guard resolvedTokenCount != nil else { return nil }
        if message.outputTokenCount != nil { return .provider }
        return metricSourceBadge(from: message.tokenCountSource)
    }

    private var resolvedTokenCount: Int? { message.tokenCount }

    private var resolvedCharacterCount: Int {
        message.characterCount
    }

    private var timeToFirstTokenSourceBadge: MetricSourceBadge? {
        guard message.timeToFirstToken != nil else { return nil }
        return metricSourceBadge(from: message.timeToFirstTokenSource)
    }

    private var tokensPerSecondSourceBadge: MetricSourceBadge? {
        guard message.tokensPerSecond != nil, message.tokensPerSecondSource == "provider" else { return nil }
        return metricSourceBadge(from: message.tokensPerSecondSource)
    }

    private var finishReasonSourceBadge: MetricSourceBadge? {
        guard message.finishReason != nil else { return nil }
        return metricSourceBadge(from: message.finishReasonSource)
    }

    private var reasoningTokenSourceBadge: MetricSourceBadge? {
        message.reasoningOutputTokenCount == nil ? nil : .provider
    }

    private var firstTokenAtSourceBadge: MetricSourceBadge? {
        guard message.streamFirstTokenAt != nil else { return nil }
        if let explicit = metricSourceBadge(from: message.streamFirstTokenAtSource) { return explicit }
        // Legacy timestamps were recorded locally or calculated from a provider duration;
        // the provider did not supply the absolute timestamp itself.
        return .local
    }

    private var horizontalValueIndicators: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private func valueCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PlatformColor.tertiaryGroupedBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(ChatTheme.chromeBorder, lineWidth: 1)
            )
    }

    private func valueCode(_ value: String?) -> some View {
        let raw = value ?? ""
        let isPlaceholder = raw.isEmpty
        let display = isPlaceholder ? String(localized: "Not Available") : raw
        return valueCard {
            ScrollView(.horizontal, showsIndicators: horizontalValueIndicators) {
                Text(display)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(isPlaceholder ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.vertical, 1)
            }
        }
    }

    private func valueText(_ value: String?) -> some View {
        let raw = value ?? ""
        let isPlaceholder = raw.isEmpty
        let display = isPlaceholder ? String(localized: "Not Available") : raw
        return valueCard {
            Text(display)
                .font(.body)
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
                .textSelection(.enabled)
        }
    }

    private func formatAssistantSegments(_ segments: [ChatAssistantSegment]) -> String {
        segments.enumerated().map { index, segment in
            let id = segment.itemID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let idLine = (id?.isEmpty == false) ? " id=\(id!)" : ""
            return "[\(index)] \(segment.kind.rawValue)\(idLine)\n\(segment.text)"
        }
        .joined(separator: "\n\n")
    }

    private func valueWrappedText(_ value: String?) -> some View {
        let raw = value ?? ""
        let isPlaceholder = raw.isEmpty
        let display = isPlaceholder ? String(localized: "Not Available") : raw
        return valueCard {
            Text(display)
                .font(.body)
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func valueDate(_ date: Date?) -> some View {
        if let date {
            let localized = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium)
            let iso = Self.isoFormatter.string(from: date)

            valueCard {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized)
                        .font(.body)
                    ScrollView(.horizontal, showsIndicators: horizontalValueIndicators) {
                        Text(iso)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(.vertical, 1)
                    }
                }
            }
        } else {
            valueText(nil)
        }
    }

    private func formatBool(_ value: Bool) -> String {
        value ? String(localized: "Yes") : String(localized: "No")
    }

    private func formatOptionalBool(_ value: Bool?) -> String? {
        guard let value else { return nil }
        return formatBool(value)
    }

    private func formatInt(_ value: Int?) -> String? {
        guard let value else { return nil }
        return String(value)
    }

    private func formatToolLoopLimit(_ value: Int?) -> String? {
        guard let value else { return nil }
        return value > 0 ? String(value) : String(localized: "Unlimited")
    }

    private func formatUUID(_ value: UUID?) -> String? {
        value?.uuidString
    }

    private func formatDouble(_ value: Double?, decimals: Int) -> String? {
        guard let value, value.isFinite else { return nil }
        return String(format: "%.\(decimals)f", value)
    }

    private func formatInterval(_ value: TimeInterval?) -> String? {
        guard let value else { return nil }
        return String(format: "%.3fs", value)
    }

    private func formatThinkingOption(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        guard let option = ModelThinkingOption.normalized(raw) else {
            return raw
        }
        return "\(option.displayName) (\(option.rawValue))"
    }

    private func uniqueToolNames(from items: [ToolTraceItem]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for item in items {
            let name = item.activity.toolName
            guard !seen.contains(name) else { continue }
            seen.insert(name)
            names.append(name)
        }
        return names
    }

    private func formatToolPhase(_ phase: ChatToolActivityPhase) -> String {
        switch phase {
        case .generating:
            return String(localized: "Generating")
        case .requested:
            return String(localized: "Requested")
        case .authorizing:
            return String(localized: "Authorizing")
        case .running:
            return String(localized: "Running")
        case .processing:
            return String(localized: "Processing")
        case .succeeded:
            return String(localized: "Succeeded")
        case .failed:
            return String(localized: "Failed")
        case .denied:
            return String(localized: "Denied")
        case .unsupported:
            return String(localized: "Unsupported")
        }
    }

    private func iconName(forToolName name: String) -> String {
        switch ChatToolID(toolName: name) {
        case .calendarListEvents, .calendarCreateEvent, .calendarDeleteEvent, .calendarShowEvents:
            return "calendar"
        case .remindersListReminders, .remindersCreateReminder, .remindersDeleteReminder, .remindersShowReminders:
            return "checklist"
        case .locationCurrent:
            return "location"
        case .motionDevice:
            return "gyroscope"
        case .deviceContext:
            return "desktopcomputer"
        case .clipboardGetText, .clipboardSetText:
            return "doc.on.clipboard"
        case .systemOpenURL:
            return "arrow.up.forward.app"
        case .systemGetTime:
            return "clock"
        case .javaScriptRun:
            return "curlybraces"
        case .none:
            return "wrench.and.screwdriver"
        }
    }

    private func color(for phase: ChatToolActivityPhase) -> Color {
        switch phase {
        case .generating, .requested, .authorizing, .running, .processing:
            return .secondary
        case .succeeded:
            return .green
        case .failed, .denied:
            return .orange
        case .unsupported:
            return .secondary
        }
    }

    @MainActor
    private static func makeRequestContextRows(for message: ChatMessage) -> [MessageDetailsRequestContextRow] {
        let rows: [MessageDetailsRequestContextRow] = [
            .code("Fingerprint", fieldKey: "requestContextFingerprint", value: message.requestContextFingerprint),
            .text(
                "Previous Response ID Used",
                fieldKey: "requestUsedPreviousResponseID",
                value: Self.formatOptionalBoolValue(message.requestUsedPreviousResponseID)
            ),
            .code("Request Previous Response ID", fieldKey: "requestPreviousResponseID", value: message.requestPreviousResponseID)
        ]

        return rows
    }

    private static func formatBoolValue(_ value: Bool) -> String {
        value ? String(localized: "Yes") : String(localized: "No")
    }

    private static func formatOptionalBoolValue(_ value: Bool?) -> String? {
        guard let value else { return nil }
        return formatBoolValue(value)
    }

    private static func formatThinkingOptionValue(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        guard let option = ModelThinkingOption.normalized(raw) else {
            return raw
        }
        return "\(option.displayName) (\(option.rawValue))"
    }
}

private struct MessageDetailsRequestContextRow: Identifiable {
    enum Value {
        case text(String?)
        case code(String?)
        case date(Date?)
    }

    let id: String
    let title: LocalizedStringKey
    let fieldKey: String
    let value: Value

    static func text(_ title: LocalizedStringKey, fieldKey: String, value: String?) -> Self {
        Self(id: fieldKey, title: title, fieldKey: fieldKey, value: .text(value))
    }

    static func code(_ title: LocalizedStringKey, fieldKey: String, value: String?) -> Self {
        Self(id: fieldKey, title: title, fieldKey: fieldKey, value: .code(value))
    }

    static func date(_ title: LocalizedStringKey, fieldKey: String, value: Date?) -> Self {
        Self(id: fieldKey, title: title, fieldKey: fieldKey, value: .date(value))
    }
}

private enum MessageDetailsChrome {
    static var sectionFill: Color {
        Color.primary.opacity(0.045)
    }

    static var sectionBorder: Color {
        Color.primary.opacity(0.08)
    }
}

#Preview {
    let message: ChatMessage = {
        let session = ChatSession(title: "Preview Session")
        let now = Date()
        let message = ChatMessage(
            content: "Hello from the assistant.",
            isUser: false,
            isActive: false,
            createdAt: now.addingTimeInterval(-12),
            modelIdentifier: "preview-model",
            apiBaseURL: "http://localhost:1234",
            thinkingOptionRawValue: ModelThinkingOption.high.rawValue,
            requestID: UUID(),
            streamStartedAt: now.addingTimeInterval(-12),
            streamFirstTokenAt: now.addingTimeInterval(-11),
            streamCompletedAt: now.addingTimeInterval(-10),
            timeToFirstToken: 1.0,
            tokenCount: 42,
            promptMessageCount: 6,
            promptCharacterCount: 512,
            finishReason: "stop",
            errorDescription: nil,
            session: session
        )
        session.messages.append(message)
        return message
    }()

    MessageDetailsView(message: message)
        .modelContainer(for: [ChatSession.self, ChatMessage.self, AppSettings.self], inMemory: true)
}
