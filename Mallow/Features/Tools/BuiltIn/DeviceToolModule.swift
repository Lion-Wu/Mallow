import Foundation

extension ChatToolID {
    static let deviceContext = ChatToolID(rawValue: "device_get_context")
}

enum DeviceToolModule {
    static let group = ChatToolGroup(id: "deviceContext", title: LocalizedStringResource("TOOLS_DEVICE_CONTEXT", defaultValue: "Device Context"), icon: "desktopcomputer")

    static func registrations(services: ChatToolServices) -> [ChatToolRegistration] {
        [
            ChatToolRegistration(
                definition: deviceContextDefinition,
                group: group,
                title: { NSLocalizedString("DEVICE_CHECKING", value: "Checking Device", comment: "Tool activity title") },
                summary: { arguments in
                    return nil
                },
                execute: { try await services.deviceTool.deviceContext(arguments: $0) }
            ),
        ]
    }

    private static var deviceContextDefinition: ChatToolDefinition {
        return ChatToolDefinition(
            id: .deviceContext,
            operationKind: .read,
            requiresHighRiskAutoExecution: false,
            generalRuleRequirements: [],
            description: ChatToolFormatting.toolDescription(
                purpose: "Read local device context.",
                useWhen: [
                    "Use when platform, OS, locale, timezone, battery, or power state affects the answer.",
                    "Do not use for unrelated personal data."
                ],
                arguments: [],
                returns: "Platform, OS version, locale, timezone, low-power state, and device/battery metadata when available.",
                afterUse: "Use only relevant fields."
            ),
            parametersSchema: ChatToolFormatting.emptyObjectSchema
        )

    }

}
