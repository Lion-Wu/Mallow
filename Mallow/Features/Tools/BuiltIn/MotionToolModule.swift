import Foundation

extension ChatToolID {
    static let motionDevice = ChatToolID(rawValue: "motion_get_device_motion")
}

enum MotionToolModule {
    static let group = ChatToolGroup(id: "motion", title: LocalizedStringResource("TOOLS_MOTION", defaultValue: "Motion"), icon: "gyroscope")

    static func registrations(services: ChatToolServices) -> [ChatToolRegistration] {
        [
            ChatToolRegistration(
                definition: motionDeviceDefinition,
                group: group,
                title: { NSLocalizedString("TOOLS_MOTION_READING", value: "Reading Motion", comment: "Tool activity title") },
                summary: { arguments in
                    if let duration = ChatToolFormatting.numberValue("duration_seconds", in: arguments) {
                        return String(
                            format: NSLocalizedString("TOOLS_MOTION_SNAPSHOT_DURATION", value: "%.1fs snapshot", comment: "Tool activity summary"),
                            duration
                        )
                    }
                    return nil
                },
                execute: { try await services.motionTool.deviceMotion(arguments: $0) }
            ),
        ]
    }

    private static var motionDeviceDefinition: ChatToolDefinition {
        return ChatToolDefinition(
            id: .motionDevice,
            operationKind: .read,
            requiresHighRiskAutoExecution: false,
            generalRuleRequirements: [],
            description: ChatToolFormatting.toolDescription(
                purpose: "Read a short device-motion snapshot.",
                useWhen: [
                    "Use for device orientation, rotation, gravity direction, or a short motion-state snapshot.",
                    "Keep samples brief."
                ],
                arguments: [],
                returns: "Attitude, rotation rate, gravity, and sample duration.",
                afterUse: "Treat it as a short sample, not a recording."
            ),
            parametersSchema: ChatToolFormatting.object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "duration_seconds": .object([
                        "type": .string("number"),
                        "description": .string("Snapshot duration in seconds. Default 1.0, max 3.0."),
                        "minimum": .number(0.2),
                        "maximum": .number(3.0)
                    ])
                ])
            ])
        )

    }

}
