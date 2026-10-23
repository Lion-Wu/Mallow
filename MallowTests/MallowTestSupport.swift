import XCTest
@testable import Mallow

enum TestDate {
    static let reference = Date(timeIntervalSinceReferenceDate: 0)

    static func offset(_ seconds: TimeInterval) -> Date {
        reference.addingTimeInterval(seconds)
    }
}

extension XCTestCase {
    func decodedBody(from data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    func jsonData(_ string: String) throws -> Data {
        try XCTUnwrap(string.data(using: .utf8))
    }

    func decodedAnthropicEvent(_ string: String) throws -> AnthropicStreamEvent {
        try JSONDecoder().decode(AnthropicStreamEvent.self, from: jsonData(string))
    }

    func decodedLMStudioEvent(_ string: String) throws -> LMStudioChatStreamEvent {
        try JSONDecoder().decode(LMStudioChatStreamEvent.self, from: jsonData(string))
    }

    func modelInfo(id: String, supportsImageInput: Bool? = nil) -> ModelInfo {
        ModelInfo(
            id: id,
            object: nil,
            created: nil,
            owned_by: nil,
            type: nil,
            arch: nil,
            input_modalities: nil,
            modalities: nil,
            vision: nil,
            multimodal: nil,
            supports_vision: nil,
            supports_image_input: supportsImageInput,
            capabilities: nil,
            details: nil,
            model_info: nil,
            reasoning: nil,
            supported_parameters: nil
        )
    }

    func chatMessage(
        id: UUID = UUID(),
        content: String,
        isUser: Bool = true,
        createdAt: Date = TestDate.reference
    ) -> ChatMessage {
        let message = ChatMessage(content: content, isUser: isUser, createdAt: createdAt)
        message.id = id
        return message
    }

    func uuid(_ tail: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, tail))
    }

    func sleepingTask() -> Task<Void, Never> {
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
