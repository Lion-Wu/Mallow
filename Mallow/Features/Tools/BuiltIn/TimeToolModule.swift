import Foundation

extension ChatToolID {
    static let systemGetTime = ChatToolID(rawValue: "system_get_time")
}

enum TimeToolModule {
    static let group = ChatToolGroup(id: "time", title: LocalizedStringResource("TOOLS_TIME", defaultValue: "Time"), icon: "clock")

    static func registrations(services: ChatToolServices) -> [ChatToolRegistration] {
        [
            ChatToolRegistration(
                definition: systemGetTimeDefinition,
                group: group,
                title: { NSLocalizedString("TOOLS_TIME_READING", value: "Reading Current Time", comment: "Tool activity title") },
                summary: { arguments in
                    return nil
                },
                execute: { try await services.systemActionTool.currentTime(arguments: $0) }
            ),
        ]
    }

    private static var systemGetTimeDefinition: ChatToolDefinition {
        return ChatToolDefinition(
            id: .systemGetTime,
            operationKind: .read,
            requiresHighRiskAutoExecution: false,
            generalRuleRequirements: [],
            description: ChatToolFormatting.toolDescription(
                purpose: "Read current device-local and UTC time.",
                useWhen: [
                    "Use when the user asks for the current date, time, timezone, or a calculation requires an exact current timestamp.",
                    "Refresh in later turns before relying on current-time assumptions."
                ],
                arguments: [],
                returns: "Local/UTC ISO time, local date and clock fields, locale, timezone, and UTC offset.",
                afterUse: "Use for the next calculation or answer."
            ),
            parametersSchema: ChatToolFormatting.emptyObjectSchema
        )

    }

}
