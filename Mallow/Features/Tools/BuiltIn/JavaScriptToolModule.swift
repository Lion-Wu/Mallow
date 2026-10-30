import Foundation

extension ChatToolID {
    static let javaScriptRun = ChatToolID(rawValue: "javascript_run")
}

enum JavaScriptToolModule {
    static let group = ChatToolGroup(id: "javaScriptRuntime", title: LocalizedStringResource("TOOLS_JAVASCRIPT_RUNTIME", defaultValue: "JavaScript Runtime"), icon: "curlybraces")

    static func registrations(services: ChatToolServices) -> [ChatToolRegistration] {
        [
            ChatToolRegistration(
                definition: javaScriptRunDefinition,
                group: group,
                title: { NSLocalizedString("TOOLS_CODE_RUNNING", value: "Running Code", comment: "Tool activity title") },
                summary: { arguments in
                    guard let code = ChatToolFormatting.stringValue("code", in: arguments) else { return nil }
                    return String(
                        format: NSLocalizedString("TOOLS_JAVASCRIPT_CHARACTER_COUNT", value: "JavaScript, %d characters", comment: "Tool activity summary"),
                        code.count
                    )
                },
                execute: { try await services.javaScriptRuntimeTool.run(arguments: $0) }
            ),
        ]
    }

    private static var javaScriptRunDefinition: ChatToolDefinition {
        return ChatToolDefinition(
            id: .javaScriptRun,
            operationKind: .compute,
            requiresHighRiskAutoExecution: true,
            generalRuleRequirements: [],
            description: ChatToolFormatting.toolDescription(
                purpose: "Run synchronous JavaScript in an isolated system web-content process.",
                useWhen: [
                    "Use for calculations, statistics, data transforms, validation, algorithms, or other self-contained computation.",
                    "It cannot read device data or perform device actions. Network, filesystem, native-object, and device APIs are unavailable."
                ],
                arguments: [
                    "Standard JavaScript syntax, loops, user-defined functions, and Math are supported. Helpers: sum(values), product(values), mean(values), median(values), stdev(values) for population standard deviation, percentile(values, percent) with percent from 0 to 100, inclusive range(start, end, step?), and round(value, digits?).",
                    "Use console.log/info/warn/error or print(...) for terminal-style output. A final expression is also reported when it can be represented directly.",
                    "code is limited to 256,000 characters; input is limited to a 4,000,000-byte JSON object."
                ],
                returns: "Terminal output plus a bounded final value when available, its type, and whether either was truncated.",
                afterUse: "Use the result; retry with corrected code only if needed."
            ),
            parametersSchema: ChatToolFormatting.object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("code")]),
                "properties": .object([
                    "code": ChatToolFormatting.stringDescription("Synchronous JavaScript source code. Standard statements, loops, functions, arrays/objects, Math, and the documented calculation helpers are supported. Network, filesystem, device/native APIs, dynamic code generation, and asynchronous completion are unavailable. Timeout: 60 seconds."),
                    "input": .object([
                        "type": .string("object"),
                        "description": .string("Optional JSON object available as input.field."),
                        "additionalProperties": .bool(true)
                    ])
                ])
            ])
        )
    }

}
