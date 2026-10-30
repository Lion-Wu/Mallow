import Foundation

extension ChatToolID {
    static let calendarListEvents = ChatToolID(rawValue: "calendar_list_events")
    static let calendarCreateEvent = ChatToolID(rawValue: "calendar_create_event")
    static let calendarDeleteEvent = ChatToolID(rawValue: "calendar_delete_event")
    static let calendarShowEvents = ChatToolID(rawValue: "calendar_show_events")
}

enum CalendarToolModule {
    static let group = ChatToolGroup(id: "calendar", title: LocalizedStringResource("TOOLS_CALENDAR", defaultValue: "Calendar"), icon: "calendar")

    static func registrations(services: ChatToolServices) -> [ChatToolRegistration] {
        [
            ChatToolRegistration(
                definition: calendarListEventsDefinition,
                group: group,
                title: { NSLocalizedString("TOOLS_CALENDAR_LISTING", value: "Listing Calendar Events", comment: "Tool activity title") },
                summary: { arguments in
                    return ChatToolFormatting.joinedSummary(
                        ChatToolFormatting.calendarTimeRangeSummary(
                            startRaw: ChatToolFormatting.stringValue("start", in: arguments),
                            endRaw: ChatToolFormatting.stringValue("end", in: arguments)
                        ),
                        ChatToolFormatting.namedScopeSummary(
                            label: NSLocalizedString("TOOLS_CALENDAR", value: "Calendar", comment: "Tool activity summary label"),
                            value: ChatToolFormatting.stringValue("calendar_name", in: arguments)
                        ),
                        ChatToolFormatting.keywordsSummary(arguments)
                    )
                },
                execute: { try await services.calendarTool.listEvents(arguments: $0) }
            ),
            ChatToolRegistration(
                definition: calendarCreateEventDefinition,
                group: group,
                title: { NSLocalizedString("TOOLS_CALENDAR_CREATING", value: "Creating Calendar Event", comment: "Tool activity title") },
                summary: { arguments in
                    return ChatToolFormatting.joinedSummary(
                        ChatToolFormatting.quotedTitleSummary(ChatToolFormatting.stringValue("title", in: arguments)),
                        ChatToolFormatting.dateTimeRangeSummary(
                            startRaw: ChatToolFormatting.stringValue("start", in: arguments),
                            endRaw: ChatToolFormatting.stringValue("end", in: arguments)
                        ),
                        ChatToolFormatting.namedScopeSummary(
                            label: NSLocalizedString("TOOLS_CALENDAR", value: "Calendar", comment: "Tool activity summary label"),
                            value: ChatToolFormatting.stringValue("calendar_name", in: arguments)
                        )
                    )
                },
                execute: { try await services.calendarTool.createEvent(arguments: $0) }
            ),
            ChatToolRegistration(
                definition: calendarDeleteEventDefinition,
                group: group,
                title: { NSLocalizedString("TOOLS_CALENDAR_DELETING", value: "Deleting Calendar Event", comment: "Tool activity title") },
                summary: { arguments in
                    return nil
                },
                execute: { try await services.calendarTool.deleteEvent(arguments: $0) }
            ),
            ChatToolRegistration(
                definition: calendarShowEventsDefinition,
                group: group,
                title: { NSLocalizedString("TOOLS_CALENDAR_SHOWING", value: "Showing Calendar Events", comment: "Tool activity title") },
                summary: { arguments in
                    return ChatToolFormatting.joinedSummary(
                        ChatToolFormatting.calendarTimeRangeSummary(
                            startRaw: ChatToolFormatting.stringValue("start", in: arguments),
                            endRaw: ChatToolFormatting.stringValue("end", in: arguments)
                        ),
                        ChatToolFormatting.namedScopeSummary(
                            label: NSLocalizedString("TOOLS_CALENDAR", value: "Calendar", comment: "Tool activity summary label"),
                            value: ChatToolFormatting.stringValue("calendar_name", in: arguments)
                        ),
                        ChatToolFormatting.keywordsSummary(arguments)
                    )
                },
                execute: { try await services.calendarTool.showEvents(arguments: $0) }
            ),
        ]
    }

    private static var calendarListEventsDefinition: ChatToolDefinition {
        return ChatToolDefinition(
            id: .calendarListEvents,
            operationKind: .read,
            requiresHighRiskAutoExecution: false,
            generalRuleRequirements: [.dateTime],
            description: ChatToolFormatting.toolDescription(
                purpose: "Read calendar events for a local time range.",
                useWhen: [
                    "Use for answering, summarizing, comparing, or filtering events.",
                    "Returns event records without rendering event cards in the chat UI."
                ],
                arguments: [],
                returns: "Events with event_id, local/UTC times, timezone, calendar, location, notes, count, and truncation flags.",
                afterUse: "Answer from the returned data."
            ),
            parametersSchema: ChatToolFormatting.object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "start": ChatToolFormatting.temporalDescription(
                        ChatToolFormatting.startTimeDescription(defaultsToToday: true),
                        acceptsNamedWeekRanges: true
                    ),
                    "end": ChatToolFormatting.temporalDescription(
                        ChatToolFormatting.endTimeDescription(),
                        acceptsNamedWeekRanges: true
                    ),
                    "calendar_name": ChatToolFormatting.stringDescription(ChatToolFormatting.exactNameDescription("calendar")),
                    "keywords": ChatToolFormatting.keywordsDescription("Optional case-insensitive substring keywords matched against title, location, notes, or calendar name. Multiple values are OR matched."),
                    "limit": ChatToolFormatting.integerDescription("Maximum number of events to return. Defaults to 20, maximum 50.")
                ])
            ])
        )

    }

    private static var calendarCreateEventDefinition: ChatToolDefinition {
        return ChatToolDefinition(
            id: .calendarCreateEvent,
            operationKind: .write,
            requiresHighRiskAutoExecution: false,
            generalRuleRequirements: [.dateTime],
            description: ChatToolFormatting.toolDescription(
                purpose: "Create a calendar event on the device.",
                useWhen: [
                    "Use only when the user asks to add, create, schedule, or save an event."
                ],
                arguments: [],
                returns: "Created event id, title, calendar, local/UTC times, timezone, and all-day status. The app also renders an event card.",
                afterUse: "Briefly confirm creation."
            ),
            parametersSchema: ChatToolFormatting.object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("title"), .string("start"), .string("end")]),
                "properties": .object([
                    "title": ChatToolFormatting.stringDescription("Event title."),
                    "start": ChatToolFormatting.temporalDescription(ChatToolFormatting.eventStartDescription),
                    "end": ChatToolFormatting.temporalDescription(ChatToolFormatting.eventEndDescription),
                    "calendar_name": ChatToolFormatting.stringDescription("Optional exact calendar name; omit for the default calendar."),
                    "location": ChatToolFormatting.stringDescription("Optional event location."),
                    "notes": ChatToolFormatting.stringDescription("Optional event notes."),
                    "is_all_day": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether this is an all-day event. Defaults to false.")
                    ])
                ])
            ])
        )

    }

    private static var calendarDeleteEventDefinition: ChatToolDefinition {
        return ChatToolDefinition(
            id: .calendarDeleteEvent,
            operationKind: .write,
            requiresHighRiskAutoExecution: false,
            generalRuleRequirements: [],
            description: ChatToolFormatting.toolDescription(
                purpose: "Delete one calendar event from the device.",
                useWhen: [
                    "Use only when the user asks to delete or remove a calendar event."
                ],
                arguments: [
                    "event_id is required. Use the exact event_id returned by a calendar read or create result; never guess or reconstruct it.",
                    "If no exact event_id is available, first read the matching events. If more than one candidate remains, ask the user which event to delete.",
                    "Set delete_future_events to true only when the user explicitly asks to remove this occurrence and following occurrences of a recurring event. It defaults to false."
                ],
                returns: "Deleted event id, title, calendar, start/end times, and whether future recurring events were deleted.",
                afterUse: "Briefly confirm deletion."
            ),
            parametersSchema: ChatToolFormatting.object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("event_id")]),
                "properties": .object([
                    "event_id": ChatToolFormatting.stringDescription("Exact event identifier returned by a calendar tool result."),
                    "delete_future_events": .object([
                        "type": .string("boolean"),
                        "description": .string("For a recurring event, also delete following occurrences. Defaults to false.")
                    ])
                ])
            ])
        )

    }

    private static var calendarShowEventsDefinition: ChatToolDefinition {
        return ChatToolDefinition(
            id: .calendarShowEvents,
            operationKind: .display,
            requiresHighRiskAutoExecution: false,
            generalRuleRequirements: [.dateTime],
            description: ChatToolFormatting.toolDescription(
                purpose: "Display matching calendar events as interactive cards in the chat UI.",
                useWhen: [
                    "Use when the user asks to see, show, display, or browse calendar events in the app.",
                    "One call returns matching event records and renders their cards."
                ],
                arguments: [],
                returns: "Matching event records including event_id. The app also renders interactive event cards.",
                afterUse: "Keep the final answer brief; do not repeat displayed events unless asked."
            ),
            parametersSchema: ChatToolFormatting.object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "start": ChatToolFormatting.temporalDescription(
                        ChatToolFormatting.startTimeDescription(defaultsToToday: true),
                        acceptsNamedWeekRanges: true
                    ),
                    "end": ChatToolFormatting.temporalDescription(
                        ChatToolFormatting.endTimeDescription(),
                        acceptsNamedWeekRanges: true
                    ),
                    "calendar_name": ChatToolFormatting.stringDescription(ChatToolFormatting.exactNameDescription("calendar")),
                    "keywords": ChatToolFormatting.keywordsDescription("Optional case-insensitive substring keywords matched against title, location, notes, or calendar name. Multiple values are OR matched."),
                    "limit": ChatToolFormatting.integerDescription("Maximum number of events to show. Defaults to 20, maximum 50.")
                ])
            ])
        )

    }

}
