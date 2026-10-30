import Foundation

extension ChatToolID {
    static let locationCurrent = ChatToolID(rawValue: "location_get_current_location")
}

enum LocationToolModule {
    static let group = ChatToolGroup(id: "location", title: LocalizedStringResource("TOOLS_LOCATION", defaultValue: "Location"), icon: "location")

    static func registrations(services: ChatToolServices) -> [ChatToolRegistration] {
        [
            ChatToolRegistration(
                definition: locationCurrentDefinition,
                group: group,
                title: { NSLocalizedString("TOOLS_LOCATION_READING", value: "Getting Location", comment: "Tool activity title") },
                summary: { arguments in
                    return nil
                },
                execute: { try await services.locationTool.currentLocation(arguments: $0) }
            ),
        ]
    }

    private static var locationCurrentDefinition: ChatToolDefinition {
        return ChatToolDefinition(
            id: .locationCurrent,
            operationKind: .read,
            requiresHighRiskAutoExecution: true,
            generalRuleRequirements: [],
            description: ChatToolFormatting.toolDescription(
                purpose: "Read the device's current foreground location.",
                useWhen: [
                    "Use when current coordinates, city/address, or location context is needed. This tool does not search for nearby businesses or places.",
                    "May require location permission."
                ],
                arguments: [],
                returns: "Latitude, longitude, accuracy, timestamp/timezone, and a system-resolved place with formatted address, country, province/state, city, district/county, street, postal code, and nearby place names when available.",
                afterUse: "Use only the needed precision."
            ),
            parametersSchema: ChatToolFormatting.emptyObjectSchema
        )

    }

}
