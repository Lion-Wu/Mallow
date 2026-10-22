//
//  ChatMessage.swift
//  Mallow
//
//  Created by Lion Wu on 2024.11.04.
//

import Foundation
import SwiftData

enum ChatAssistantSegmentKind: String, Codable, Sendable {
    case reasoning
    case text
}

struct ChatAssistantSegment: Codable, Equatable, Sendable {
    var kind: ChatAssistantSegmentKind
    var itemID: String?
    var text: String
}

enum AssistantStreamSegment: Equatable, Sendable {
    case reasoning(id: String?, text: String)
    case text(id: String?, text: String)
    case tool(ChatToolActivityPlacement)
}

@Model
final class ChatMessage {
    // MARK: - Identity
    var id: UUID

    // MARK: - Branching
    var activeChildMessageID: UUID?
    // Imported conflict copies retain their original identity across exchanges.
    var importSourceMessageID: UUID?

    // MARK: - Content
    var messageDocumentData: Data?
    @Transient private var cachedDocument: ChatMessageDocument?
    @Transient var transientAssistantSegments: [ChatAssistantSegment]?
    @Transient var assistantSegmentsNeedPersistence = false
    @Transient var assistantSegmentsSynchronizedForPersistence = false
    var imageAttachmentsData: Data?
    var isUser: Bool
    var isActive: Bool
    var createdAt: Date?

    // MARK: - Telemetry & Metadata
    var modelIdentifier: String?
    var apiBaseURL: String?
    var thinkingOptionRawValue: String?
    var requestID: UUID?
    var providerResponseID: String?
    var requestContextFingerprint: String?
    var requestUsedPreviousResponseID: Bool?
    var requestPreviousResponseID: String?
    var streamStartedAt: Date?
    var streamFirstTokenAt: Date?
    var streamFirstTokenAtSource: String?
    var streamCompletedAt: Date?
    var timeToFirstToken: TimeInterval?
    var outputTokenCount: Int?
    var reasoningOutputTokenCount: Int?
    var tokensPerSecond: Double?
    var tokenCountSource: String?
    var timeToFirstTokenSource: String?
    var tokensPerSecondSource: String?
    var finishReasonSource: String?
    var promptMessageCount: Int?
    var promptCharacterCount: Int?
    var finishReason: String?
    var errorDescription: String?

    // MARK: - Relation
    @Relationship(inverse: \ChatSession.messages) var session: ChatSession?
    @Relationship(inverse: \ChatMessage.childMessages) var parentMessage: ChatMessage?
    @Relationship var childMessages: [ChatMessage]

    // MARK: - Init
    init(
        content: String,
        assistantSegments: [ChatAssistantSegment] = [],
        openAIResponsesConversationItems: [JSONValue] = [],
        imageAttachments: [ChatImageAttachment] = [],
        isUser: Bool,
        isActive: Bool = true,
        createdAt: Date? = Date(),
        activeChildMessageID: UUID? = nil,
        modelIdentifier: String? = nil,
        apiBaseURL: String? = nil,
        thinkingOptionRawValue: String? = nil,
        requestID: UUID? = nil,
        providerResponseID: String? = nil,
        requestContextFingerprint: String? = nil,
        requestUsedPreviousResponseID: Bool? = nil,
        requestPreviousResponseID: String? = nil,
        streamStartedAt: Date? = nil,
        streamFirstTokenAt: Date? = nil,
        streamFirstTokenAtSource: String? = nil,
        streamCompletedAt: Date? = nil,
        timeToFirstToken: TimeInterval? = nil,
        outputTokenCount: Int? = nil,
        reasoningOutputTokenCount: Int? = nil,
        tokensPerSecond: Double? = nil,
        tokenCount: Int? = nil,
        tokenCountSource: String? = nil,
        timeToFirstTokenSource: String? = nil,
        tokensPerSecondSource: String? = nil,
        finishReasonSource: String? = nil,
        promptMessageCount: Int? = nil,
        promptCharacterCount: Int? = nil,
        finishReason: String? = nil,
        errorDescription: String? = nil,
        toolActivityPlacements: [ChatToolActivityPlacement] = [],
        session: ChatSession? = nil,
        parentMessage: ChatMessage? = nil,
        childMessages: [ChatMessage] = []
    ) {
        self.id = UUID()
        self.activeChildMessageID = activeChildMessageID
        self.transientAssistantSegments = assistantSegments
        self.assistantSegmentsNeedPersistence = false
        self.assistantSegmentsSynchronizedForPersistence = false
        self.imageAttachmentsData = ChatImageAttachment.encodeList(imageAttachments)
        self.isUser = isUser
        self.isActive = isActive
        self.createdAt = createdAt
        self.modelIdentifier = modelIdentifier
        self.apiBaseURL = apiBaseURL
        self.thinkingOptionRawValue = thinkingOptionRawValue
        self.requestID = requestID
        self.providerResponseID = providerResponseID
        self.requestContextFingerprint = requestContextFingerprint
        self.requestUsedPreviousResponseID = requestUsedPreviousResponseID
        self.requestPreviousResponseID = requestPreviousResponseID
        self.streamStartedAt = streamStartedAt
        self.streamFirstTokenAt = streamFirstTokenAt
        self.streamFirstTokenAtSource = streamFirstTokenAtSource
        self.streamCompletedAt = streamCompletedAt
        self.timeToFirstToken = timeToFirstToken
        self.outputTokenCount = outputTokenCount ?? (tokenCountSource == "provider" ? tokenCount : nil)
        self.reasoningOutputTokenCount = reasoningOutputTokenCount
        self.tokensPerSecond = tokensPerSecond
        self.tokenCountSource = tokenCountSource
        self.timeToFirstTokenSource = timeToFirstTokenSource
        self.tokensPerSecondSource = tokensPerSecondSource
        self.finishReasonSource = finishReasonSource

        self.promptMessageCount = promptMessageCount
        self.promptCharacterCount = promptCharacterCount
        self.finishReason = finishReason
        self.errorDescription = errorDescription

        self.session = session
        self.parentMessage = parentMessage
        self.childMessages = childMessages
        let initialDocument = ChatMessageDocument(
            text: content,
            segments: assistantSegments,
            protocolItems: openAIResponsesConversationItems,
            toolPlacements: toolActivityPlacements
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            self.messageDocumentData = try encoder.encode(initialDocument)
        } catch {
            preconditionFailure("Invalid initial message document: \(error)")
        }
        self.cachedDocument = initialDocument
        self.assistantSegmentsNeedPersistence = true
        session?.registerTransientMessagePersistence(self)
    }
}

extension ChatMessage {
    private var document: ChatMessageDocument {
        get {
            if let cachedDocument { return cachedDocument }
            // Persisted documents are validated at the store boundary before UI access.
            if let messageDocumentData {
                do {
                    let value = try JSONDecoder().decode(ChatMessageDocument.self, from: messageDocumentData)
                    cachedDocument = value
                    return value
                } catch {
                    preconditionFailure("Unvalidated message document: \(error)")
                }
            }
            preconditionFailure("Missing message document")
        }
        set {
            cachedDocument = newValue
            assistantSegmentsNeedPersistence = true
            assistantSegmentsSynchronizedForPersistence = false
            session?.registerTransientMessagePersistence(self)
        }
    }

    var content: String {
        get { document.content }
        set { var value = document; value.text = newValue; document = value }
    }

    var characterCount: Int {
        document.segments.isEmpty ? content.count : document.segments.reduce(0) { $0 + $1.text.count }
    }

    var tokenCount: Int? {
        guard generationRounds.isEmpty else { return nil }
        return outputTokenCount
    }

    var generationRounds: [ChatGenerationRound] {
        get { document.generationRounds }
        set { var value = document; value.generationRounds = newValue; document = value }
    }

    var streamDuration: TimeInterval? {
        guard let start = streamStartedAt, let end = streamCompletedAt else { return nil }
        return end.timeIntervalSince(start)
    }

    var generationDuration: TimeInterval? {
        guard let first = streamFirstTokenAt, let end = streamCompletedAt else { return nil }
        return end.timeIntervalSince(first)
    }

    // Import/export projections; these are never stored separately.
    var assistantSegmentsData: Data? {
        get { Self.encodeAssistantSegments(assistantSegments) }
        set { assistantSegments = Self.decodeAssistantSegments(from: newValue) }
    }
    var openAIResponsesConversationItemsData: Data? {
        get { Self.encodeOpenAIResponsesConversationItems(openAIResponsesConversationItems) }
        set { openAIResponsesConversationItems = Self.decodeOpenAIResponsesConversationItems(from: newValue) }
    }
    var toolActivityPlacementsData: Data? {
        get { Self.encodeToolActivityPlacements(toolActivityPlacements) }
        set { toolActivityPlacements = Self.decodeToolActivityPlacements(from: newValue) }
    }

    func installDocument(_ data: Data) throws {
        let decoded = try JSONDecoder().decode(ChatMessageDocument.self, from: data)
        cachedDocument = decoded
        transientAssistantSegments = nil
        messageDocumentData = data
        assistantSegmentsNeedPersistence = false
        assistantSegmentsSynchronizedForPersistence = false
    }

    func persistDocument() throws {
        var value = document
        if let transientAssistantSegments { value.segments = transientAssistantSegments }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(value)
        messageDocumentData = encoded
        cachedDocument = value
    }

    var imageAttachments: [ChatImageAttachment] {
        get { ChatImageAttachment.decodeList(from: imageAttachmentsData) }
        set { imageAttachmentsData = ChatImageAttachment.encodeList(newValue) }
    }

    var hasImageAttachments: Bool {
        !(imageAttachmentsData?.isEmpty ?? true) && !imageAttachments.isEmpty
    }

    var imageAttachmentsFingerprint: Int {
        imageAttachmentsData?.hashValue ?? 0
    }

    var toolActivityPlacements: [ChatToolActivityPlacement] {
        get { document.toolPlacements }
        set { var value = document; value.toolPlacements = newValue; document = value }
    }

    var providerResponseIDs: [String] {
        generationRounds.compactMap(\.providerResponseID)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var assistantSegments: [ChatAssistantSegment] {
        get { transientAssistantSegments ?? document.segments }
        set {
            transientAssistantSegments = newValue
            var value = document
            value.segments = newValue
            if value.text == newValue.filter({ $0.kind == .text }).map(\.text).joined() { value.text = "" }
            document = value
        }
    }

    var openAIResponsesConversationItems: [JSONValue] {
        get { document.protocolItems }
        set { var value = document; value.protocolItems = newValue; document = value }
    }

    var assistantText: String {
        let segments = assistantSegments
        let text = segments
            .filter { $0.kind == .text }
            .map(\.text)
            .joined()
        if !text.isEmpty || !segments.isEmpty {
            return text
        }
        return content.extractThinkParts().body
    }

    var assistantReasoningText: String? {
        let segments = assistantSegments
        let reasoning = segments
            .filter { $0.kind == .reasoning }
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !reasoning.isEmpty || !segments.isEmpty {
            return reasoning.isEmpty ? nil : reasoning
        }
        return content.extractThinkParts().think
    }

    var hasAssistantSegments: Bool {
        !assistantSegments.isEmpty
    }

    var hasAssistantOutput: Bool {
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if !assistantSegments.isEmpty {
            return true
        }
        if !toolActivityPlacements.isEmpty {
            return true
        }
        return false
    }

    var hasAssistantContinuationContent: Bool {
        !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            toolActivityPlacements.contains { $0.activity.phase.isPersistentToolTracePhase } ||
            openAIResponsesConversationItems.contains {
                ($0.jsonObject as? [String: Any])?["type"] as? String == "function_call_output"
            }
    }

    var renderFingerprintSource: String {
        let segments = assistantSegments
        guard !segments.isEmpty else { return content }
        let segmentSource = segments
            .map { "\($0.kind.rawValue):\($0.itemID ?? ""):\($0.text)" }
            .joined(separator: "\u{1F}")
        return content + "\u{1E}" + segmentSource
    }

    func appendAssistantSegment(_ segment: AssistantStreamSegment) {
        switch segment {
        case let .reasoning(id, text):
            appendAssistantSegment(kind: .reasoning, itemID: id, text: text)
        case let .text(id, text):
            appendAssistantSegment(kind: .text, itemID: id, text: text)
        case .tool:
            break
        }
    }

    var thinkingOption: ModelThinkingOption? {
        get {
            thinkingOptionRawValue.flatMap(ModelThinkingOption.normalized)
        }
        set {
            thinkingOptionRawValue = newValue?.rawValue
        }
    }

    private static func encodeToolActivityPlacements(_ placements: [ChatToolActivityPlacement]) -> Data? {
        guard !placements.isEmpty else { return nil }
        return try? JSONEncoder().encode(placements)
    }

    private static func decodeToolActivityPlacements(from data: Data?) -> [ChatToolActivityPlacement] {
        guard let data, !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([ChatToolActivityPlacement].self, from: data)) ?? []
    }

    private func appendAssistantSegment(kind: ChatAssistantSegmentKind, itemID: String?, text: String) {
        guard !text.isEmpty else { return }
        var segments = transientAssistantSegments
            ?? document.segments
        if let index = segments.indices.last,
           segments[index].kind == kind,
           segments[index].itemID == itemID {
            segments[index].text += text
        } else {
            segments.append(ChatAssistantSegment(kind: kind, itemID: itemID, text: text))
        }
        assistantSegments = segments
    }

    func hydrateAssistantSegmentsIfNeeded() {
        guard transientAssistantSegments == nil else { return }
        transientAssistantSegments = document.segments
        assistantSegmentsNeedPersistence = false
        assistantSegmentsSynchronizedForPersistence = false
    }

    @discardableResult
    func synchronizeAssistantSegmentsForPersistence() throws -> Bool {
        guard assistantSegmentsNeedPersistence,
              !assistantSegmentsSynchronizedForPersistence else {
            return false
        }
        try persistDocument()
        assistantSegmentsSynchronizedForPersistence = true
        return true
    }

    func markAssistantSegmentsPersisted() {
        guard assistantSegmentsNeedPersistence,
              assistantSegmentsSynchronizedForPersistence else {
            return
        }
        assistantSegmentsNeedPersistence = false
        assistantSegmentsSynchronizedForPersistence = false
    }

    func markAssistantSegmentsPersistenceFailed() {
        guard assistantSegmentsNeedPersistence else { return }
        assistantSegmentsSynchronizedForPersistence = false
    }

    private static func encodeAssistantSegments(_ segments: [ChatAssistantSegment]) -> Data? {
        guard !segments.isEmpty else { return nil }
        return try? JSONEncoder().encode(segments)
    }

    private static func decodeAssistantSegments(from data: Data?) -> [ChatAssistantSegment] {
        guard let data, !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([ChatAssistantSegment].self, from: data)) ?? []
    }

    private static func encodeOpenAIResponsesConversationItems(_ items: [JSONValue]) -> Data? {
        guard !items.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(items)
    }

    private static func decodeOpenAIResponsesConversationItems(from data: Data?) -> [JSONValue] {
        guard let data, !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([JSONValue].self, from: data)) ?? []
    }
}

extension ChatMessage {
    var requestSource: ChatRequestSourceMessage {
        ChatRequestSourceMessage(
            content: content, isUser: isUser, imageAttachments: imageAttachments,
            providerResponseID: providerResponseID, requestContextFingerprint: requestContextFingerprint,
            assistantSegments: assistantSegments,
            openAIResponsesConversationItems: openAIResponsesConversationItems,
            toolActivityPlacements: toolActivityPlacements, createdAt: createdAt
        )
    }
}

/// One durable content representation. Display text and protocol replay are projections.
struct ChatMessageDocument: Codable, Equatable, Sendable {
    var text: String
    var segments: [ChatAssistantSegment]
    var protocolItems: [JSONValue]
    var toolPlacements: [ChatToolActivityPlacement]
    var generationRounds: [ChatGenerationRound] = []

    var content: String {
        segments.isEmpty || !text.isEmpty ? text : segments.filter { $0.kind == .text }.map(\.text).joined()
    }

    init(text: String = "", segments: [ChatAssistantSegment] = [],
         protocolItems: [JSONValue] = [], toolPlacements: [ChatToolActivityPlacement] = []) {
        self.text = !segments.isEmpty && text == segments.filter({ $0.kind == .text }).map(\.text).joined() ? "" : text
        self.segments = segments
        self.protocolItems = protocolItems
        self.toolPlacements = toolPlacements
    }

    private struct StoredSegment: Codable {
        let kind: ChatAssistantSegmentKind
        let itemID: String?
        let text: String?
        let source: [TextReference]?
    }

    private struct TextReference: Codable {
        let item: Int
        let field: String
        let part: Int
    }

    private struct StoredToolPlacement: Codable {
        var placement: ChatToolActivityPlacement
        var resultItem: Int?
        var argumentsItem: Int?
        var decodeArguments: Bool?
    }

    private enum CodingKeys: String, CodingKey {
        case version, text, segments, protocolItems, toolPlacements, generationRounds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported message document version")
        }
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        generationRounds = try container.decodeIfPresent([ChatGenerationRound].self, forKey: .generationRounds) ?? []
        let items = try container.decode([JSONValue].self, forKey: .protocolItems)
        protocolItems = items
        let tools = try container.decode([StoredToolPlacement].self, forKey: .toolPlacements)
        toolPlacements = try tools.map { stored in
            var placement = stored.placement
            if let index = stored.argumentsItem {
                guard items.indices.contains(index), case let .object(item) = items[index],
                      case let .string(arguments) = item["arguments"] else {
                    throw DecodingError.dataCorruptedError(forKey: .toolPlacements, in: container, debugDescription: "Invalid tool arguments reference")
                }
                placement.activity.modelRequestPayload?["arguments_json"] = .string(arguments)
            }
            if stored.decodeArguments == true {
                guard case let .string(arguments) = placement.activity.modelRequestPayload?["arguments_json"] else {
                    throw DecodingError.dataCorruptedError(forKey: .toolPlacements, in: container, debugDescription: "Missing tool arguments")
                }
                placement.activity.modelRequestPayload?["arguments"] = try JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8))
            }
            if let index = stored.resultItem {
                guard let result = Self.toolResult(at: index, in: items) else {
                    throw DecodingError.dataCorruptedError(forKey: .toolPlacements, in: container, debugDescription: "Invalid tool result reference")
                }
                placement.activity.resultPayload = result
            }
            return placement
        }
        segments = []
        let stored = try container.decode([StoredSegment].self, forKey: .segments)
        for segment in stored {
            let resolved: String
            if let sources = segment.source {
                let values = sources.compactMap { Self.text(at: $0, in: items) }
                guard values.count == sources.count else {
                    throw DecodingError.dataCorruptedError(forKey: .segments, in: container, debugDescription: "Invalid protocol text reference")
                }
                resolved = values.joined()
            } else if let value = segment.text, segment.source == nil {
                resolved = value
            } else {
                throw DecodingError.dataCorruptedError(forKey: .segments, in: container, debugDescription: "Invalid protocol text reference")
            }
            segments.append(.init(kind: segment.kind, itemID: segment.itemID, text: resolved))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        if segments.isEmpty || !text.isEmpty { try container.encode(text, forKey: .text) }
        if !generationRounds.isEmpty { try container.encode(generationRounds, forKey: .generationRounds) }
        try container.encode(protocolItems, forKey: .protocolItems)
        let tools = toolPlacements.map { placement in
            var stored = StoredToolPlacement(placement: placement)
            if case let .string(arguments) = placement.activity.modelRequestPayload?["arguments_json"] {
                if let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)),
                   decoded == placement.activity.modelRequestPayload?["arguments"] {
                    stored.decodeArguments = true
                    stored.placement.activity.modelRequestPayload?.removeValue(forKey: "arguments")
                }
                if let index = protocolItems.indices.first(where: { index in
                    guard case let .object(item) = protocolItems[index] else { return false }
                    return item["type"] == .string("function_call") &&
                        item["call_id"] == .string(placement.activity.id) &&
                        item["arguments"] == .string(arguments)
                }) {
                    stored.argumentsItem = index
                    stored.placement.activity.modelRequestPayload?.removeValue(forKey: "arguments_json")
                }
            }
            if let result = placement.activity.resultPayload,
               let index = protocolItems.indices.first(where: { index in
                   guard case let .object(item) = protocolItems[index],
                         item["call_id"] == .string(placement.activity.id) else { return false }
                   return Self.toolResult(at: index, in: protocolItems) == result
               }) {
                stored.resultItem = index
                stored.placement.activity.resultPayload = nil
            }
            return stored
        }
        try container.encode(tools, forKey: .toolPlacements)
        // Provider output owns its text. Rendering segments reference it instead of copying it.
        let stored = segments.map { segment in
            let source = reference(for: segment)
            return StoredSegment(kind: segment.kind, itemID: segment.itemID,
                                 text: source == nil ? segment.text : nil, source: source)
        }
        try container.encode(stored, forKey: .segments)
    }

    private func reference(for segment: ChatAssistantSegment) -> [TextReference]? {
        for (index, value) in protocolItems.enumerated() {
            guard case let .object(item) = value else { continue }
            if let id = segment.itemID, item["id"] != .string(id) { continue }
            let field = segment.kind == .reasoning ? "summary" : "content"
            guard case let .array(parts) = item[field] else { continue }
            var references: [TextReference] = []
            for part in parts.indices {
                let reference = TextReference(item: index, field: field, part: part)
                if Self.text(at: reference, in: protocolItems) == segment.text { return [reference] }
                if Self.text(at: reference, in: protocolItems) != nil { references.append(reference) }
            }
            if references.compactMap({ Self.text(at: $0, in: protocolItems) }).joined() == segment.text {
                return references
            }
        }
        return nil
    }

    private static func text(at reference: TextReference, in items: [JSONValue]) -> String? {
        guard items.indices.contains(reference.item),
              case let .object(item) = items[reference.item],
              case let .array(parts) = item[reference.field],
              parts.indices.contains(reference.part),
              case let .object(part) = parts[reference.part],
              case let .string(text) = part["text"] else { return nil }
        return text
    }

    private static func toolResult(at index: Int, in items: [JSONValue]) -> [String: JSONValue]? {
        guard items.indices.contains(index),
              case let .object(item) = items[index],
              item["type"] == .string("function_call_output"),
              case let .string(output) = item["output"],
              let result = try? JSONDecoder().decode([String: JSONValue].self, from: Data(output.utf8)) else { return nil }
        return result
    }
}
