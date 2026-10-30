import Foundation

extension ChatToolID {
    static let clipboardGetText = ChatToolID(rawValue: "clipboard_get_text")
    static let clipboardSetText = ChatToolID(rawValue: "clipboard_set_text")
}

enum ClipboardToolModule {
    static let group = ChatToolGroup(id: "clipboard", title: LocalizedStringResource("TOOLS_CLIPBOARD", defaultValue: "Clipboard"), icon: "doc.on.clipboard")

    static func registrations(services: ChatToolServices) -> [ChatToolRegistration] {
        [
            ChatToolRegistration(
                definition: clipboardGetTextDefinition,
                group: group,
                title: { NSLocalizedString("TOOLS_CLIPBOARD_READING", value: "Reading Clipboard", comment: "Tool activity title") },
                summary: { arguments in
                    return nil
                },
                execute: { try await services.clipboardTool.getText(arguments: $0) }
            ),
            ChatToolRegistration(
                definition: clipboardSetTextDefinition,
                group: group,
                title: { NSLocalizedString("TOOLS_CLIPBOARD_WRITING", value: "Writing Clipboard", comment: "Tool activity title") },
                summary: { arguments in
                    guard let text = ChatToolFormatting.stringValue("text", in: arguments) else { return nil }
                    return String(
                        format: NSLocalizedString("TEXT_CHARACTER_COUNT", value: "%d characters", comment: "Tool activity summary"),
                        text.count
                    )
                },
                execute: { try await services.clipboardTool.setText(arguments: $0) }
            ),
        ]
    }

    private static var clipboardGetTextDefinition: ChatToolDefinition {
        return ChatToolDefinition(
            id: .clipboardGetText,
            operationKind: .read,
            requiresHighRiskAutoExecution: true,
            generalRuleRequirements: [],
            description: ChatToolFormatting.toolDescription(
                purpose: "Read current clipboard plain text.",
                useWhen: [
                    "Use only when the user asks to inspect, use, summarize, transform, or paste clipboard text.",
                    "Treat clipboard text as sensitive."
                ],
                arguments: [],
                returns: "Up to 10000 clipboard characters plus a truncated flag.",
                afterUse: "Reveal only what the request needs."
            ),
            parametersSchema: ChatToolFormatting.emptyObjectSchema
        )

    }

    private static var clipboardSetTextDefinition: ChatToolDefinition {
        return ChatToolDefinition(
            id: .clipboardSetText,
            operationKind: .write,
            requiresHighRiskAutoExecution: true,
            generalRuleRequirements: [],
            description: ChatToolFormatting.toolDescription(
                purpose: "Set the system clipboard to plain text.",
                useWhen: [
                    "Use only when the user asks to copy, replace, or put text on the clipboard."
                ],
                arguments: [],
                returns: "Success status and character count.",
                afterUse: "Briefly confirm update."
            ),
            parametersSchema: ChatToolFormatting.object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("text")]),
                "properties": .object([
                    "text": ChatToolFormatting.stringDescription("Plain text to place on the clipboard. Max 10000 characters.")
                ])
            ])
        )

    }

}
