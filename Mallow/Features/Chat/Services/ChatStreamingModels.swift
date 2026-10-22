//
//  ChatModel.swift
//  Mallow
//
//  Created by Lion Wu on 2024/1/8.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Streaming Chunk Models

struct ChatCompletionChunk: Decodable {
    var id: String?
    var object: String?
    var created: Int?
    var model: String?
    var choices: [Choice]?
    var usage: ChatCompletionUsage?
    var timings: LlamaServerTimings?
}

struct Choice: Decodable {
    var index: Int?
    var finish_reason: String?
    var delta: Delta?
}

struct ChatResponseMetadata: Sendable, Equatable {
    var generationRound: ChatGenerationRound?
    var providerResponseID: String?
    var continuationSeed: ChatContinuationSeed?
    var requestUsedPreviousResponseID: Bool?
    var requestPreviousResponseID: String?
    var outputTokenCount: Int?
    var reasoningOutputTokenCount: Int?
    var tokensPerSecond: Double?
    var timeToFirstTokenSeconds: Double?
    var finishReason: String?

    static let empty = ChatResponseMetadata()

    var hasAnyValue: Bool {
        generationRound != nil ||
        providerResponseID != nil ||
        continuationSeed != nil ||
        requestUsedPreviousResponseID != nil ||
        requestPreviousResponseID != nil ||
        outputTokenCount != nil ||
        reasoningOutputTokenCount != nil ||
        tokensPerSecond != nil ||
        timeToFirstTokenSeconds != nil ||
        finishReason != nil
    }

    mutating func merge(_ update: ChatResponseMetadata) {
        if let generationRound = update.generationRound { self.generationRound = generationRound }
        if let seed = update.continuationSeed { continuationSeed = seed }
        if let providerResponseID = update.providerResponseID,
           !providerResponseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.providerResponseID = providerResponseID
        }
        if let requestUsedPreviousResponseID = update.requestUsedPreviousResponseID {
            self.requestUsedPreviousResponseID = requestUsedPreviousResponseID
            if !requestUsedPreviousResponseID {
                self.requestPreviousResponseID = nil
            }
        }
        if update.requestUsedPreviousResponseID != false,
           let requestPreviousResponseID = update.requestPreviousResponseID,
           !requestPreviousResponseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.requestPreviousResponseID = requestPreviousResponseID
            if update.requestUsedPreviousResponseID == nil {
                self.requestUsedPreviousResponseID = true
            }
        }
        if let outputTokenCount = update.outputTokenCount, outputTokenCount >= 0 {
            self.outputTokenCount = outputTokenCount
        }
        if let reasoningOutputTokenCount = update.reasoningOutputTokenCount, reasoningOutputTokenCount >= 0 {
            self.reasoningOutputTokenCount = reasoningOutputTokenCount
        }
        if let tokensPerSecond = update.tokensPerSecond, tokensPerSecond.isFinite, tokensPerSecond >= 0 {
            self.tokensPerSecond = tokensPerSecond
        }
        if let timeToFirstTokenSeconds = update.timeToFirstTokenSeconds,
           timeToFirstTokenSeconds.isFinite,
           timeToFirstTokenSeconds >= 0 {
            self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        }
        if let finishReason = update.finishReason,
           !finishReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.finishReason = finishReason
        }
    }
}

/// Statistics belong to one HTTP generation, including tool-call generations.
/// Provider fields are stored once; normalized values are read-only projections.
struct ChatGenerationRound: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let requestStyle: ChatRequestStyle
    let requestedModel: String
    let requestURL: String
    let startedAt: Date
    let previousResponseID: String?
    // Nil means unavailable; an empty dictionary means no thinking override was sent.
    var requestedThinking: [String: JSONValue]?
    var firstOutputAt: Date?
    var endedAt: Date?
    var outcome: String?
    var hasFinalUsage = false
    var providerFields: [String: JSONValue] = [:]
    var toolCallIDs: [String] = []

    static let thinkingParameterKeys: Set<String> = ["reasoning", "reasoning_effort", "thinking", "output_config"]

    var reportedThinking: [String: JSONValue] {
        providerFields.filter { Self.thinkingParameterKeys.contains($0.key) }
    }

    var providerResponseID: String? { string("id") ?? string("response_id") }
    var providerModel: String? { string("model") }
    var finishReason: String? {
        if let reason = string("finish_reason") ?? string("stop_reason") { return reason }
        guard let status = string("status"), ["completed", "incomplete", "failed", "cancelled"].contains(status) else { return nil }
        return status
    }
    var outputTokens: Int? {
        guard hasFinalUsage else { return nil }
        return integer("usage", "output_tokens") ?? integer("usage", "completion_tokens")
            ?? integer("stats", "total_output_tokens") ?? integer("timings", "predicted_n")
    }
    var inputTokens: Int? {
        guard hasFinalUsage else { return nil }
        return integer("usage", "input_tokens") ?? integer("usage", "prompt_tokens")
            ?? integer("stats", "input_tokens") ?? integer("timings", "prompt_n")
    }
    var reasoningTokens: Int? {
        guard hasFinalUsage else { return nil }
        return integer("usage", "output_tokens_details", "reasoning_tokens")
            ?? integer("usage", "output_tokens_details", "thinking_tokens")
            ?? integer("usage", "completion_tokens_details", "reasoning_tokens")
            ?? integer("stats", "reasoning_output_tokens")
    }
    var totalTokens: Int? { hasFinalUsage ? integer("usage", "total_tokens") : nil }
    var cachedTokens: Int? {
        guard hasFinalUsage else { return nil }
        return integer("usage", "input_tokens_details", "cached_tokens")
            ?? integer("usage", "prompt_tokens_details", "cached_tokens")
            ?? integer("usage", "cache_read_input_tokens") ?? integer("timings", "cache_n")
    }
    var cacheWriteTokens: Int? {
        guard hasFinalUsage else { return nil }
        return integer("usage", "input_tokens_details", "cache_write_tokens")
            ?? integer("usage", "prompt_tokens_details", "cache_write_tokens")
            ?? integer("usage", "cache_creation_input_tokens")
    }
    var reportedCost: Double? { hasFinalUsage ? number("usage", "cost") : nil }
    var providerTokensPerSecond: Double? {
        guard hasFinalUsage else { return nil }
        return number("stats", "tokens_per_second") ?? number("timings", "predicted_per_second")
    }
    var providerTimeToFirstToken: Double? {
        number("stats", "time_to_first_token_seconds") ?? number("timings", "time_to_first_token_seconds")
    }
    var localTimeToFirstOutput: TimeInterval? { firstOutputAt.map { $0.timeIntervalSince(startedAt) } }
    var localDuration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
    var providerCreatedAt: Date? { (number("created_at") ?? number("created")).map(Date.init(timeIntervalSince1970:)) }
    var providerCompletedAt: Date? { number("completed_at").map(Date.init(timeIntervalSince1970:)) }

    mutating func absorb(_ dictionary: [String: Any]) {
        let type = (dictionary["type"] as? String) ?? ""
        let payload = (dictionary["response"] as? [String: Any])
            ?? (dictionary["result"] as? [String: Any])
            ?? (dictionary["message"] as? [String: Any]) ?? dictionary
        let fields = ["id", "response_id", "model", "provider", "created", "created_at", "completed_at",
                      "status", "finish_reason", "native_finish_reason", "stop_reason", "stop_sequence",
                      "usage", "stats", "timings", "service_tier", "system_fingerprint", "tool_usage",
                      "incomplete_details", "error"]
        for key in fields + Self.thinkingParameterKeys.sorted() {
            if let value = payload[key] {
                providerFields[key] = Self.merging(providerFields[key], JSONValue.normalized(value))
            }
        }
        if requestStyle == .lmStudioRESTV1,
           let model = payload["model_instance_id"] as? String,
           !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            providerFields["model"] = .string(model)
        }
        if let choice = (dictionary["choices"] as? [[String: Any]])?.first {
            for key in ["finish_reason", "native_finish_reason"] {
                if let value = choice[key] as? String { providerFields[key] = .string(value) }
            }
            if let delta = choice["delta"] as? [String: Any], let calls = delta["tool_calls"] as? [[String: Any]] {
                for call in calls { recordToolCallID(call["id"] as? String) }
            }
        }
        if let delta = dictionary["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
            providerFields["stop_reason"] = .string(reason)
        }
        if let item = dictionary["item"] as? [String: Any], item["type"] as? String == "function_call" {
            recordToolCallID(item["call_id"] as? String)
        }
        if let block = dictionary["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
            recordToolCallID(block["id"] as? String)
        }
        let containsUsage = payload["usage"] is [String: Any] || payload["stats"] is [String: Any]
            || payload["timings"] is [String: Any]
        switch requestStyle {
        case .anthropicMessages:
            if containsUsage && (type == "message_delta" && finishReason != nil || type == "message" || type.isEmpty && finishReason != nil) { hasFinalUsage = true }
        case .openAIResponses:
            if containsUsage && (["response.completed", "response.done", "response.incomplete", "response.failed"].contains(type)
                || type.isEmpty && ["completed", "incomplete", "failed"].contains(string("status") ?? "")) { hasFinalUsage = true }
        case .openAIChatCompletions:
            let usageOnly = (dictionary["choices"] as? [[String: Any]])?.isEmpty == true
            if containsUsage && (finishReason != nil || usageOnly || dictionary["object"] as? String == "chat.completion") { hasFinalUsage = true }
        case .lmStudioRESTV1:
            if containsUsage && (["chat.end", "response.completed"].contains(type) || type.isEmpty) { hasFinalUsage = true }
        }
    }

    private mutating func recordToolCallID(_ id: String?) {
        guard let id, !id.isEmpty, !toolCallIDs.contains(id) else { return }
        toolCallIDs.append(id)
    }

    private static func merging(_ previous: JSONValue?, _ update: JSONValue) -> JSONValue {
        guard case var .object(object) = previous, case let .object(changes) = update else { return update }
        for (key, value) in changes { object[key] = merging(object[key], value) }
        return .object(object)
    }

    private func value(_ path: [String]) -> JSONValue? {
        var current: JSONValue = .object(providerFields)
        for key in path {
            guard case let .object(object) = current, let next = object[key] else { return nil }
            current = next
        }
        return current
    }
    private func string(_ key: String) -> String? {
        guard case let .string(value) = providerFields[key], !value.isEmpty else { return nil }
        return value
    }
    private func number(_ path: String...) -> Double? {
        guard case let .number(value) = value(path), value.isFinite, value >= 0 else { return nil }
        return value
    }
    private func integer(_ path: String...) -> Int? {
        guard case let .number(value) = value(path), value.isFinite, value >= 0,
              value < Double(Int.max), value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }
}

struct ChatCompletionUsage: Decodable {
    var completion_tokens: Int?
    var total_tokens: Int?
    var completion_tokens_details: ChatCompletionUsageDetails?
}

struct ChatCompletionUsageDetails: Decodable {
    var reasoning_tokens: Int?
}

struct LlamaServerTimings: Decodable {
    var cache_n: Int?
    var prompt_n: Int?
    var predicted_n: Int?
    var predicted_per_second: Double?
    var time_to_first_token_seconds: Double?
}

/// Decodes reasoning fields produced by LM Studio v0.3.23 and later.
struct ReasoningValue: Codable {
    let text: String

    init(from decoder: Decoder) throws {
        if let single = try? String(from: decoder) {
            self.text = single
            return
        }
        if let obj = try? AnyDict(from: decoder) {
            if let s = obj.dict["content"]?.stringValue ?? obj.dict["text"]?.stringValue {
                self.text = s
                return
            }
            let joined = obj.dict.values.compactMap { $0.stringValue }.joined()
            if !joined.isEmpty {
                self.text = joined
                return
            }
        }
        if let arr = try? [AnyDict](from: decoder) {
            let collected = arr.compactMap { item in
                item.dict["content"]?.stringValue ?? item.dict["text"]?.stringValue
            }.joined()
            self.text = collected
            return
        }
        self.text = ""
    }
}

struct AnyDecodable: Decodable {
    let value: Any

    var stringValue: String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            value = s
        } else if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let obj = try? AnyDict(from: decoder) {
            value = obj.dict
        } else if let arr = try? [AnyDecodable](from: decoder) {
            value = arr.map { $0.value }
        } else {
            value = NSNull()
        }
    }
}

fileprivate struct DynamicCodingKey: CodingKey {
    let stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}

struct AnyDict: Decodable {
    let dict: [String: AnyDecodable]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var result: [String: AnyDecodable] = [:]
        for key in container.allKeys {
            result[key.stringValue] = try container.decode(AnyDecodable.self, forKey: key)
        }
        self.dict = result
    }
}

struct Delta: Decodable {
    var role: String?
    var content: String?
    var reasoning: ReasoningValue?
    var reasoning_content: String?
    var reasoning_details: [JSONValue]?

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoning
        case reasoning_content
        case reasoning_details
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try? container.decodeIfPresent(String.self, forKey: .role)
        reasoning = try? container.decodeIfPresent(ReasoningValue.self, forKey: .reasoning)
        reasoning_content = try? container.decodeIfPresent(String.self, forKey: .reasoning_content)
        reasoning_details = try? container.decodeIfPresent([JSONValue].self, forKey: .reasoning_details)

        if let text = try? container.decodeIfPresent(String.self, forKey: .content) {
            content = text
            return
        }
        if let loose = try? container.decodeIfPresent(AnyDecodable.self, forKey: .content) {
            let flattened = Self.flattenedContentText(from: loose.value)
            content = flattened.isEmpty ? nil : flattened
            return
        }
        content = nil
    }

    private static func flattenedContentText(from value: Any) -> String {
        if let text = value as? String {
            return text
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let object = value as? [String: AnyDecodable] {
            for key in ["text", "content", "value", "delta"] {
                if let candidate = object[key] {
                    let flattened = flattenedContentText(from: candidate.value)
                    if !flattened.isEmpty {
                        return flattened
                    }
                }
            }
            return object.values.map { flattenedContentText(from: $0.value) }.joined()
        }
        if let array = value as? [Any] {
            return array.map(flattenedContentText(from:)).joined()
        }
        return ""
    }
}

enum ChatNetworkError: Error {
    case invalidURL
    case invalidRequestHistory
    case unsupportedImageInput
    case modelInformationUnavailable
    case serverError(statusCode: Int?, message: String)
    case timeout(String)
    case emptyResponse
}

struct ChatIncompleteResponseError: LocalizedError, Sendable {
    let message: String
    let segments: [AssistantStreamSegment]
    let metadata: ChatResponseMetadata

    var errorDescription: String? { message }
}

extension ChatNetworkError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return NSLocalizedString("NETWORK_INVALID_API_URL", value: "Invalid API URL", comment: "Shown when the configured chat API URL is invalid")
        case .invalidRequestHistory:
            return NSLocalizedString(
                "CHAT_BRANCH_REQUEST_FAILED", value: "Unable to build a request from the selected conversation branch.",
                comment: "Shown when a chat branch does not end with the intended user message"
            )
        case .unsupportedImageInput:
            return NSLocalizedString(
                "MODEL_IMAGE_INPUT_UNSUPPORTED", value: "The selected model does not support image input.",
                comment: "Shown when retry settings cannot preserve the request's image inputs"
            )
        case .modelInformationUnavailable:
            return NSLocalizedString(
                "MODEL_INFO_NOT_READY", value: "Model information is not ready. Wait for loading to finish, or fetch models again in Settings.",
                comment: "Shown when sending is blocked until model metadata is available"
            )
        case .serverError(_, let message):
            return message
        case .timeout(let message):
            return message
        case .emptyResponse:
            return NSLocalizedString(
                "PROVIDER_EMPTY_RESPONSE", value: "Server returned an empty response",
                comment: "Shown when the request completes without any assistant output"
            )
        }
    }
}
