import Foundation

extension ChatToolID {
    static let remindersListReminders = ChatToolID(rawValue: "reminders_list_reminders")
    static let remindersCreateReminder = ChatToolID(rawValue: "reminders_create_reminder")
    static let remindersDeleteReminder = ChatToolID(rawValue: "reminders_delete_reminder")
    static let remindersShowReminders = ChatToolID(rawValue: "reminders_show_reminders")
}

enum RemindersToolModule {
    static let group = ChatToolGroup(id: "reminders", title: LocalizedStringResource("TOOLS_REMINDERS", defaultValue: "Reminders"), icon: "checklist")

    static func registrations(services: ChatToolServices) -> [ChatToolRegistration] {
        [
            ChatToolRegistration(
                definition: remindersListRemindersDefinition,
                group: group,
                title: { NSLocalizedString("TOOLS_REMINDERS_LISTING", value: "Listing Reminders", comment: "Tool activity title") },
                summary: { arguments in
                    return ChatToolFormatting.joinedSummary(
                        ChatToolFormatting.reminderStatusSummary(ChatToolFormatting.stringValue("status", in: arguments)),
                        ChatToolFormatting.dueTimeRangeSummary(
                            startRaw: ChatToolFormatting.stringValue("start", in: arguments),
                            endRaw: ChatToolFormatting.stringValue("end", in: arguments)
                        ),
                        ChatToolFormatting.namedScopeSummary(
                            label: NSLocalizedString("TOOLS_REMINDER_LIST", value: "List", comment: "Tool activity summary label"),
                            value: ChatToolFormatting.stringValue("list_name", in: arguments)
                        ),
                        ChatToolFormatting.keywordsSummary(arguments)
                    )
                },
                execute: { try await services.remindersTool.listReminders(arguments: $0) }
            ),
            ChatToolRegistration(
                definition: remindersCreateReminderDefinition,
                group: group,
                title: { NSLocalizedString("TOOLS_REMINDERS_CREATING", value: "Creating Reminder", comment: "Tool activity title") },
                summary: { arguments in
                    return ChatToolFormatting.joinedSummary(
                        ChatToolFormatting.quotedTitleSummary(ChatToolFormatting.stringValue("title", in: arguments)),
                        ChatToolFormatting.dueDateTimeSummary(ChatToolFormatting.stringValue("due", in: arguments)),
                        ChatToolFormatting.namedScopeSummary(
                            label: NSLocalizedString("TOOLS_REMINDER_LIST", value: "List", comment: "Tool activity summary label"),
                            value: ChatToolFormatting.stringValue("list_name", in: arguments)
                        ),
                        ChatToolFormatting.prioritySummary(ChatToolFormatting.numberValue("priority", in: arguments))
                    )
                },
                execute: { try await services.remindersTool.createReminder(arguments: $0) }
            ),
            ChatToolRegistration(
                definition: remindersDeleteReminderDefinition,
                group: group,
                title: { NSLocalizedString("TOOLS_REMINDERS_DELETING", value: "Deleting Reminder", comment: "Tool activity title") },
                summary: { arguments in
                    return nil
                },
                execute: { try await services.remindersTool.deleteReminder(arguments: $0) }
            ),
            ChatToolRegistration(
                definition: remindersShowRemindersDefinition,
                group: group,
                title: { NSLocalizedString("TOOLS_REMINDERS_SHOWING", value: "Showing Reminders", comment: "Tool activity title") },
                summary: { arguments in
                    return ChatToolFormatting.joinedSummary(
                        ChatToolFormatting.reminderStatusSummary(ChatToolFormatting.stringValue("status", in: arguments)),
                        ChatToolFormatting.dueTimeRangeSummary(
                            startRaw: ChatToolFormatting.stringValue("start", in: arguments),
                            endRaw: ChatToolFormatting.stringValue("end", in: arguments)
                        ),
                        ChatToolFormatting.namedScopeSummary(
                            label: NSLocalizedString("TOOLS_REMINDER_LIST", value: "List", comment: "Tool activity summary label"),
                            value: ChatToolFormatting.stringValue("list_name", in: arguments)
                        ),
                        ChatToolFormatting.keywordsSummary(arguments)
                    )
                },
                execute: { try await services.remindersTool.showReminders(arguments: $0) }
            ),
        ]
    }

    private static var remindersListRemindersDefinition: ChatToolDefinition {
        return ChatToolDefinition(
            id: .remindersListReminders,
            operationKind: .read,
            requiresHighRiskAutoExecution: false,
            generalRuleRequirements: [.dateTime],
            description: ChatToolFormatting.toolDescription(
                purpose: "Read reminders, optionally filtered by due-time range.",
                useWhen: [
                    "Use for answering, summarizing, filtering, or checking reminders.",
                    "Returns reminder records without rendering reminder cards in the chat UI."
                ],
                arguments: [
                    ChatToolFormatting.reminderRangeArgument
                ],
                returns: "Reminders with reminder_id, list, status, due time, priority, notes, timezone, count, and truncation flag.",
                afterUse: "Answer from the returned data."
            ),
            parametersSchema: ChatToolFormatting.object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "status": .object([
                        "type": .string("string"),
                        "description": .string("Reminder status filter. Defaults to incomplete."),
                        "enum": .array([.string("incomplete"), .string("completed"), .string("all")])
                    ]),
                    "start": ChatToolFormatting.temporalDescription(
                        ChatToolFormatting.startTimeDescription(defaultsToToday: false),
                        acceptsNamedWeekRanges: true
                    ),
                    "end": ChatToolFormatting.temporalDescription(
                        ChatToolFormatting.endTimeDescription(),
                        acceptsNamedWeekRanges: true
                    ),
                    "list_name": ChatToolFormatting.stringDescription(ChatToolFormatting.exactNameDescription("reminder list")),
                    "keywords": ChatToolFormatting.keywordsDescription("Optional case-insensitive substring keywords matched against title, notes, or list name. Multiple values are OR matched."),
                    "limit": ChatToolFormatting.integerDescription("Maximum number of reminders to return. Defaults to 20, maximum 50.")
                ])
            ])
        )

    }

    private static var remindersCreateReminderDefinition: ChatToolDefinition {
        return ChatToolDefinition(
            id: .remindersCreateReminder,
            operationKind: .write,
            requiresHighRiskAutoExecution: false,
            generalRuleRequirements: [.dateTime],
            description: ChatToolFormatting.toolDescription(
                purpose: "Create a reminder on the device.",
                useWhen: [
                    "Use only when the user asks to add, create, save, or remind them about a task."
                ],
                arguments: [],
                returns: "Created reminder id, title, list, due time, timezone, and priority. The app also renders a reminder card.",
                afterUse: "Briefly confirm creation."
            ),
            parametersSchema: ChatToolFormatting.object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("title")]),
                "properties": .object([
                    "title": ChatToolFormatting.stringDescription("Reminder title."),
                    "notes": ChatToolFormatting.stringDescription("Optional reminder notes."),
                    "due": ChatToolFormatting.temporalDescription(ChatToolFormatting.dueTimeDescription),
                    "list_name": ChatToolFormatting.stringDescription("Optional exact reminder list name; omit for the default list."),
                    "priority": .object([
                        "type": .string("integer"),
                        "description": .string("Optional priority from 0 to 9."),
                        "minimum": .number(0),
                        "maximum": .number(9)
                    ])
                ])
            ])
        )

    }

    private static var remindersDeleteReminderDefinition: ChatToolDefinition {
        return ChatToolDefinition(
            id: .remindersDeleteReminder,
            operationKind: .write,
            requiresHighRiskAutoExecution: false,
            generalRuleRequirements: [],
            description: ChatToolFormatting.toolDescription(
                purpose: "Delete one reminder from the device.",
                useWhen: [
                    "Use only when the user asks to delete or remove a reminder."
                ],
                arguments: [
                    "reminder_id is required. Use the exact reminder_id returned by a reminder read or create result; never guess or reconstruct it.",
                    "If no exact reminder_id is available, first read the matching reminders. If more than one candidate remains, ask the user which reminder to delete."
                ],
                returns: "Deleted reminder id, title, list, due time, and completion status.",
                afterUse: "Briefly confirm deletion."
            ),
            parametersSchema: ChatToolFormatting.object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("reminder_id")]),
                "properties": .object([
                    "reminder_id": ChatToolFormatting.stringDescription("Exact reminder identifier returned by a reminder tool result.")
                ])
            ])
        )

    }

    private static var remindersShowRemindersDefinition: ChatToolDefinition {
        return ChatToolDefinition(
            id: .remindersShowReminders,
            operationKind: .display,
            requiresHighRiskAutoExecution: false,
            generalRuleRequirements: [.dateTime],
            description: ChatToolFormatting.toolDescription(
                purpose: "Display matching reminders as interactive cards in the chat UI.",
                useWhen: [
                    "Use when the user asks to see, show, display, or browse reminders in the app.",
                    "One call returns matching reminder records and renders their cards."
                ],
                arguments: [
                    ChatToolFormatting.reminderRangeArgument
                ],
                returns: "Matching reminder records including reminder_id. The app also renders interactive reminder cards.",
                afterUse: "Keep the final answer brief; do not repeat displayed reminders unless asked."
            ),
            parametersSchema: ChatToolFormatting.object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "status": .object([
                        "type": .string("string"),
                        "description": .string("Reminder status filter. Defaults to incomplete."),
                        "enum": .array([.string("incomplete"), .string("completed"), .string("all")])
                    ]),
                    "start": ChatToolFormatting.temporalDescription(
                        ChatToolFormatting.startTimeDescription(defaultsToToday: false),
                        acceptsNamedWeekRanges: true
                    ),
                    "end": ChatToolFormatting.temporalDescription(
                        ChatToolFormatting.endTimeDescription(),
                        acceptsNamedWeekRanges: true
                    ),
                    "list_name": ChatToolFormatting.stringDescription(ChatToolFormatting.exactNameDescription("reminder list")),
                    "keywords": ChatToolFormatting.keywordsDescription("Optional case-insensitive substring keywords matched against title, notes, or list name. Multiple values are OR matched."),
                    "limit": ChatToolFormatting.integerDescription("Maximum number of reminders to show. Defaults to 20, maximum 50.")
                ])
            ])
        )

    }

}
