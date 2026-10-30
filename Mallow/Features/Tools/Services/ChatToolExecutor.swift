import Foundation

protocol ChatToolExecuting: Sendable {
    func execute(_ call: ChatToolCallEnvelope, context: ChatToolExecutionContext) async -> ChatToolResultEnvelope
    func prepareTools(settings: ToolUseSettings) async throws -> ChatToolRegistry
}

struct ChatToolExecutor: ChatToolExecuting {
    private let registry: ChatToolRegistry

    init(registry: ChatToolRegistry = .builtIn) {
        self.registry = registry
    }

    func prepareTools(settings: ToolUseSettings) async throws -> ChatToolRegistry {
        try ChatToolCatalog.prepareBuiltIn(settings: settings, registry: registry)
    }

    func execute(_ call: ChatToolCallEnvelope, context: ChatToolExecutionContext) async -> ChatToolResultEnvelope {
        do {
            try Task.checkCancellation()
            guard let registration = context.registry.registration(named: call.name) else {
                throw ChatToolError.unknownTool(call.name)
            }
            let settings = await context.currentSettings()
            guard settings.isEnabled, registration.isEnabled(settings) else { throw ChatToolError.disabled }
            let reader = try ChatToolArgumentReader(argumentsJSON: call.argumentsJSON)
            try ChatToolSchemaValidator.validate(reader.argumentsValue, against: registration.definition.parametersSchema)
            let decision = ChatToolAuthorizationPolicy.decision(for: registration.definition, settings: settings)
            var approved = false
            switch decision {
            case .allow: break
            case let .deny(message): throw ChatToolError.denied(message)
            case .ask:
                approved = await context.authorize(ChatToolAuthorizationRequest(
                    id: UUID().uuidString, toolName: call.name, title: registration.title(),
                    operationKind: registration.definition.operationKind, argumentsSummary: call.argumentsJSON
                ))
                guard approved else {
                    throw ChatToolError.denied(String(localized: "TOOLS_CALL_DENIED", defaultValue: "Tool call was denied by the user."))
                }
            }
            try Task.checkCancellation()
            let current = await context.currentSettings()
            guard current.isEnabled, registration.isEnabled(current) else { throw ChatToolError.disabled }
            if !approved, ChatToolAuthorizationPolicy.decision(for: registration.definition, settings: current) != .allow {
                throw ChatToolError.denied(String(localized: "TOOLS_CALL_DENIED", defaultValue: "Tool call was denied by the user."))
            }
            await context.willExecute()
            try Task.checkCancellation()
            let result = try await registration.execute(reader)
            return ChatToolResultEnvelope(
                callID: call.callID, name: call.name, status: result.status,
                payload: result.payload, summary: result.summary, presentation: result.presentation
            )
        } catch let error as ChatToolError {
            return failureResult(for: call, error: error)
        } catch is CancellationError {
            return failureResult(for: call, error: .failed(String(localized: "COMMON_STATUS_CANCELLED", defaultValue: "Cancelled.")))
        } catch {
            return failureResult(for: call, error: .failed(error.localizedDescription))
        }
    }

    private func failureResult(for call: ChatToolCallEnvelope, error: ChatToolError) -> ChatToolResultEnvelope {
        ChatToolResultEnvelope(
            callID: call.callID, name: call.name, status: error.resultStatus,
            payload: ["error": .string(error.localizedDescription)], summary: error.localizedDescription
        )
    }
}

struct ChatToolExecutionPayload: Equatable, Sendable {
    let payload: [String: JSONValue]
    let summary: String
    var presentation: ChatToolPresentation? = nil
    var status: ChatToolResultStatus = .success
}
