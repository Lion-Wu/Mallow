import Foundation

extension ChatToolID {
    static let systemOpenURL = ChatToolID(rawValue: "system_open_url")
}

enum URLToolModule {
    static let group = ChatToolGroup(id: "urlActions", title: LocalizedStringResource("TOOLS_URL_ACTIONS", defaultValue: "URL Actions"), icon: "arrow.up.forward.app")

    static func registrations(services: ChatToolServices) -> [ChatToolRegistration] {
        [
            ChatToolRegistration(
                definition: systemOpenURLDefinition,
                group: group,
                title: { NSLocalizedString("TOOLS_URL_OPENING", value: "Opening Link", comment: "Tool activity title") },
                summary: { arguments in
                    guard let rawURL = ChatToolFormatting.stringValue("url", in: arguments) else { return nil }
                    if let url = URL(string: rawURL), let host = url.host, !host.isEmpty {
                        return host
                    }
                    return rawURL
                },
                execute: { try await services.systemActionTool.openURL(arguments: $0) }
            ),
        ]
    }

    private static var systemOpenURLDefinition: ChatToolDefinition {
        return ChatToolDefinition(
            id: .systemOpenURL,
            operationKind: .action,
            requiresHighRiskAutoExecution: true,
            generalRuleRequirements: [],
            description: ChatToolFormatting.toolDescription(
                purpose: "Open a URL using the system handler.",
                useWhen: [
                    "Use only when the user asks to open, navigate, email, or map."
                ],
                arguments: [],
                returns: "Whether the system accepted the open request.",
                afterUse: "Briefly confirm destination or failure."
            ),
            parametersSchema: ChatToolFormatting.object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("url")]),
                "properties": .object([
                    "url": ChatToolFormatting.stringDescription("URL to open. Allowed schemes: http, https, mailto, maps.")
                ])
            ])
        )

    }

}
