import Foundation

struct ChatToolGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: LocalizedStringResource
    let icon: String
}

struct ChatToolRegistration: Sendable {
    let definition: ChatToolDefinition
    let group: ChatToolGroup
    let title: @Sendable () -> String
    let summary: @Sendable ([String: Any]) -> String?
    let execute: @Sendable (ChatToolArgumentReader) async throws -> ChatToolExecutionPayload

    func isEnabled(_ settings: ToolUseSettings) -> Bool {
        settings.isGroupEnabled(group.id)
    }
}

struct ChatToolRegistry: Sendable {
    let registrations: [ChatToolRegistration]
    private let byName: [String: ChatToolRegistration]
    private let byID: [ChatToolID: ChatToolRegistration]

    init(_ registrations: [ChatToolRegistration]) throws {
        var byName: [String: ChatToolRegistration] = [:]
        var byID: [ChatToolID: ChatToolRegistration] = [:]
        for registration in registrations {
            let name = registration.definition.name
            guard (1...64).contains(name.utf8.count), name.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
            }) else {
                throw ChatToolError.invalidArguments("Tool names must contain 1–64 ASCII letters, digits, underscores, or hyphens.")
            }
            guard byName[registration.definition.name] == nil,
                  byID[registration.definition.id] == nil else {
                throw ChatToolError.invalidArguments("Duplicate tool identity or model name.")
            }
            byName[registration.definition.name] = registration
            byID[registration.definition.id] = registration
        }
        self.registrations = registrations
        self.byName = byName
        self.byID = byID
    }

    var definitions: [ChatToolDefinition] { registrations.map(\.definition) }

    var groups: [ChatToolGroup] {
        var seen = Set<String>()
        return registrations.compactMap { seen.insert($0.group.id).inserted ? $0.group : nil }
    }

    func registration(named name: String) -> ChatToolRegistration? { byName[name] }
    func registration(id: ChatToolID) -> ChatToolRegistration? { byID[id] }

    static let builtIn = builtIn(services: ChatToolServices())

    static func builtIn(services: ChatToolServices) -> ChatToolRegistry {
        let registrations =
            CalendarToolModule.registrations(services: services) +
            RemindersToolModule.registrations(services: services) +
            LocationToolModule.registrations(services: services) +
            MotionToolModule.registrations(services: services) +
            DeviceToolModule.registrations(services: services) +
            ClipboardToolModule.registrations(services: services) +
            URLToolModule.registrations(services: services) +
            TimeToolModule.registrations(services: services) +
            JavaScriptToolModule.registrations(services: services)
        do {
            return try ChatToolRegistry(registrations)
        } catch {
            preconditionFailure("Invalid built-in tool catalog: \(error)")
        }
    }

    func enabled(using settings: ToolUseSettings) throws -> ChatToolRegistry {
        try ChatToolRegistry(settings.isEnabled ? registrations.filter { $0.isEnabled(settings) } : [])
    }

    func title(for name: String) -> String { registration(named: name)?.title() ?? name }

    func summary(for call: ChatToolCallEnvelope, resultSummary: String? = nil) -> String? {
        ChatToolFormatting.joinedSummary(
            registration(named: call.name)?.summary(ChatToolFormatting.decodedArguments(call.argumentsJSON)),
            resultSummary
        )
    }
}

struct ChatToolServices: Sendable {
    var calendarTool: any CalendarToolServing = EventKitCalendarTool()
    var remindersTool: any RemindersToolServing = EventKitRemindersTool()
    var locationTool: any LocationToolServing = CoreLocationTool()
    var motionTool: any MotionToolServing = CoreMotionTool()
    var deviceTool: any DeviceContextToolServing = SystemDeviceContextTool()
    var clipboardTool: any ClipboardToolServing = SystemClipboardTool()
    var systemActionTool: any SystemActionToolServing = DefaultSystemActionTool()
    var javaScriptRuntimeTool: any JavaScriptRuntimeToolServing = SandboxedJavaScriptRuntimeTool()
}

struct ChatToolExecutionContext: Sendable {
    let registry: ChatToolRegistry
    let currentSettings: @Sendable () async -> ToolUseSettings
    let authorize: @Sendable (ChatToolAuthorizationRequest) async -> Bool
    var willExecute: @Sendable () async -> Void = {}
}
