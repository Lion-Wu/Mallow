//
//  ChatRequestContextBuilder.swift
//  Mallow
//
//  Created by Codex on 2026.06.24.
//

import CryptoKit
import Foundation

enum ChatRequestContextBuilder {
    /// Hash the effective transport configuration, excluding the history.
    /// History is hashed separately with the completed assistant output at the same logical boundary.
    static func fingerprint(
        request: URLRequest,
        endpoint: ChatAPIEndpointCandidate,
        includeImagesInUserContent: Bool
    ) throws -> String {
        guard let data = request.httpBody,
              var body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = request.url,
              let method = request.httpMethod else {
            throw ChatNetworkError.invalidRequestHistory
        }
        for key in ["input", "messages", "previous_response_id"] {
            body.removeValue(forKey: key)
        }
        let payload: [String: Any] = [
            "version": 2,
            "provider": endpoint.provider.rawValue,
            "format": endpoint.style.rawValue,
            "method": method,
            "url": url.absoluteString,
            "headers": request.allHTTPHeaderFields ?? [:],
            "body": body,
            "includeImages": includeImagesInUserContent
        ]
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }
}

/// Captured before transport starts. Only the completed history digest is persisted.
struct ChatContinuationSeed: Equatable, Sendable {
    let configurationFingerprint: String
    let history: [JSONValue]

    func fingerprint(appending message: ChatRequestSourceMessage? = nil) throws -> String {
        var items = history
        if let message { items.append(try Self.historyItem(message)) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(JSONValue.object([
            "configuration": .string(configurationFingerprint),
            "history": .array(items)
        ]))
        return "history-v2:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func historyItem(_ message: ChatRequestSourceMessage) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func value<T: Encodable>(_ value: T) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
        }
        return .object([
            "role": .string(message.isUser ? "user" : "assistant"),
            "content": .string(message.content),
            "requestContent": .string(ChatRequestPayloadProjector.requestContent(for: message)),
            "segments": try value(message.assistantSegments),
            "protocolItems": .array(message.openAIResponsesConversationItems),
            "tools": try value(message.toolActivityPlacements),
            "images": .array(message.imageAttachments.map { image in
                .object([
                    "mimeType": .string(image.mimeType),
                    "digest": .string(SHA256.hash(data: image.data).map { String(format: "%02x", $0) }.joined())
                ])
            })
        ])
    }
}
