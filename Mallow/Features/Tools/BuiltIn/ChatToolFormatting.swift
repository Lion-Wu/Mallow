import Foundation

enum ChatToolFormatting {
    static func decodedArguments(_ json: String) -> [String: Any] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    static func stringValue(_ key: String, in arguments: [String: Any]) -> String? {
        guard let value = arguments[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func numberValue(_ key: String, in arguments: [String: Any]) -> Double? {
        if let value = arguments[key] as? Double {
            return value
        }
        if let value = arguments[key] as? Int {
            return Double(value)
        }
        if let value = arguments[key] as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    static func stringArrayValue(_ key: String, in arguments: [String: Any]) -> [String] {
        guard let values = arguments[key] as? [String] else { return [] }
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func joinedSummary(_ parts: String?...) -> String? {
        let values = parts.compactMap { part -> String? in
            guard let value = part?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                return nil
            }
            return value
        }
        guard !values.isEmpty else { return nil }
        var output: [String] = []
        var seen = Set<String>()
        for value in values {
            let key = value.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(value)
        }
        return output.joined(separator: " · ")
    }

    static func quotedTitleSummary(_ title: String?) -> String? {
        guard let title else { return nil }
        return "“\(title)”"
    }

    static func namedScopeSummary(label: String, value: String?) -> String? {
        guard let value else { return nil }
        return String(
            format: NSLocalizedString("COMMON_NAME_VALUE", value: "%@: %@", comment: "Tool activity summary"),
            label,
            value
        )
    }

    static func reminderStatusSummary(_ rawStatus: String?) -> String {
        switch rawStatus?.lowercased() {
        case "completed":
            return NSLocalizedString("TOOLS_REMINDERS_COMPLETED", value: "Completed reminders", comment: "Tool activity summary")
        case "all":
            return NSLocalizedString("TOOLS_REMINDERS_ALL", value: "All reminders", comment: "Tool activity summary")
        case "incomplete", nil:
            return NSLocalizedString("TOOLS_REMINDERS_OPEN", value: "Open reminders", comment: "Tool activity summary")
        default:
            return rawStatus ?? NSLocalizedString("TOOLS_REMINDERS_OPEN", value: "Open reminders", comment: "Tool activity summary")
        }
    }

    static func dueTimeRangeSummary(startRaw: String?, endRaw: String?) -> String? {
        guard startRaw != nil || endRaw != nil else { return nil }
        let range = temporalRangeSummary(startRaw: startRaw, endRaw: endRaw, defaultToToday: false)
        guard let range else { return nil }
        return String(
            format: NSLocalizedString("TOOLS_REMINDER_DUE", value: "Due %@", comment: "Tool activity summary"),
            range
        )
    }

    static func calendarTimeRangeSummary(startRaw: String?, endRaw: String?) -> String? {
        guard let range = temporalRangeSummary(startRaw: startRaw, endRaw: endRaw, defaultToToday: true) else {
            return nil
        }
        return String(
            format: NSLocalizedString("TOOLS_CALENDAR_NAME", value: "Calendar: %@", comment: "Tool activity summary"),
            range
        )
    }

    static func keywordsSummary(_ arguments: [String: Any]) -> String? {
        let keywords = stringArrayValue("keywords", in: arguments)
        guard !keywords.isEmpty else { return nil }
        return String(
            format: NSLocalizedString("TOOLS_SEARCH_KEYWORDS", value: "Keywords: %@", comment: "Tool activity summary"),
            keywords.joined(separator: ", ")
        )
    }

    static func dueDateTimeSummary(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        return String(
            format: NSLocalizedString("TOOLS_REMINDER_DUE", value: "Due %@", comment: "Tool activity summary"),
            dateTimeSummary(rawValue)
        )
    }

    static func prioritySummary(_ value: Double?) -> String? {
        guard let value, value > 0 else { return nil }
        return String(
            format: NSLocalizedString("TOOLS_REMINDER_PRIORITY", value: "Priority %d", comment: "Tool activity summary"),
            Int(value)
        )
    }

    static func temporalRangeSummary(
        startRaw: String?,
        endRaw: String?,
        defaultToToday: Bool
    ) -> String? {
        let calendar = Calendar.autoupdatingCurrent
        let fallbackStart = defaultToToday ? calendar.startOfDay(for: Date()) : nil
        let startDate = startRaw.flatMap(temporalDate) ?? fallbackStart
        let endDate = endRaw.flatMap(temporalDate) ?? startDate

        if let startDate, let endDate {
            let startText = relativeDateText(startDate, calendar: calendar)
            if hasExplicitTime(startRaw) || hasExplicitTime(endRaw) {
                let startTime = timeText(startDate)
                let endTime = timeText(endDate)
                if calendar.isDate(startDate, inSameDayAs: endDate) {
                    return "\(startText) \(startTime) - \(endTime)"
                }
                return "\(dateTimeText(startDate)) - \(dateTimeText(endDate))"
            }
            let endText = relativeDateText(endDate, calendar: calendar)
            if calendar.isDate(startDate, inSameDayAs: endDate) { return startText }
            return "\(startText) - \(endText)"
        }

        if let startRaw, let endRaw, startRaw != endRaw {
            return "\(startRaw) - \(endRaw)"
        }
        return startRaw ?? endRaw
    }

    static func temporalDate(_ rawValue: String) -> Date? {
        try? ChatToolTemporalResolver.date(from: rawValue)
    }

    static func hasExplicitTime(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        let value = rawValue.lowercased()
        return value.contains(":") ||
            value.contains("now") ||
            value.contains("hour") ||
            value.contains("minute") ||
            value.contains("second")
    }

    static func dateTimeRangeSummary(startRaw: String?, endRaw: String?) -> String? {
        guard startRaw != nil || endRaw != nil else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        let startDate = startRaw.flatMap(dateTime)
        let endDate = endRaw.flatMap(dateTime)
        if let startDate, let endDate {
            let startDay = relativeDateText(startDate, calendar: calendar)
            let startTime = timeText(startDate)
            let endTime = timeText(endDate)
            if calendar.isDate(startDate, inSameDayAs: endDate) {
                return "\(startDay) \(startTime) - \(endTime)"
            }
            return "\(dateTimeText(startDate)) - \(dateTimeText(endDate))"
        }
        if let startRaw, let endRaw {
            return "\(startRaw) - \(endRaw)"
        }
        return (startRaw ?? endRaw).map(dateTimeSummary)
    }

    static func dateTimeSummary(_ rawValue: String) -> String {
        guard let date = dateTime(rawValue) else { return rawValue }
        return dateTimeText(date)
    }

    static func dateTime(_ rawValue: String) -> Date? {
        ChatToolTemporalResolver.parseDateTime(rawValue)
    }

    static func relativeDateText(_ date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) {
            return NSLocalizedString("DATE_TODAY", value: "Today", comment: "Tool activity date")
        }
        if calendar.isDateInTomorrow(date) {
            return NSLocalizedString("DATE_TOMORROW", value: "Tomorrow", comment: "Tool activity date")
        }
        if calendar.isDateInYesterday(date) {
            return NSLocalizedString("DATE_YESTERDAY", value: "Yesterday", comment: "Tool activity date")
        }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func dateTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static var emptyObjectSchema: JSONValue {
        object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([:])
        ])
    }

    static func object(_ value: [String: JSONValue]) -> JSONValue {
        .object(value)
    }

    static func stringDescription(_ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description)
        ])
    }

    static func temporalDescription(
        _ description: String,
        acceptsNamedWeekRanges: Bool = false
    ) -> JSONValue {
        var references = [ChatToolTemporalResolver.generalToolRuleReference]
        if acceptsNamedWeekRanges {
            references.append(ChatToolTemporalResolver.namedWeekRangeRuleReference)
        }
        return .object([
            "type": .string("string"),
            "description": .string(([description] + references).joined(separator: " "))
        ])
    }

    static func keywordsDescription(_ description: String) -> JSONValue {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object([
                "type": .string("string")
            ])
        ])
    }

    static func integerDescription(_ description: String) -> JSONValue {
        .object([
            "type": .string("integer"),
            "description": .string(description),
            "minimum": .number(1),
            "maximum": .number(50)
        ])
    }

    static var reminderRangeArgument: String {
        "Omit both start and end to include reminders with or without due dates. Supplying a time range excludes reminders without a due date."
    }

    static func startTimeDescription(defaultsToToday: Bool) -> String {
        let defaultText = defaultsToToday ? " Omit only to default to today." : " Omit for an unbounded lower end."
        let limitText = defaultsToToday ? " Calendar queries return at most the first 31 days and set range_truncated when a longer range was requested." : ""
        return "Query window start, inclusive.\(defaultText)\(limitText)"
    }

    static func endTimeDescription() -> String {
        "Query window end; start is required when end is present. Omit end to use the full day or week represented by a date-only or week-relative start. A date-only end includes that full local day. Precise-time ranges require both start and end."
    }

    static var eventStartDescription: String {
        "Event start. For an all-day event, use its local YYYY-MM-DD start date."
    }

    static var eventEndDescription: String {
        "Event end. For an all-day event, use the exclusive next local YYYY-MM-DD date."
    }

    static var dueTimeDescription: String {
        "Optional reminder due time."
    }

    static func exactNameDescription(_ label: String) -> String {
        "Optional exact \(label) name. Omit unless user specified it; do not guess default/primary."
    }

    static func toolDescription(
        purpose: String,
        useWhen: [String],
        arguments: [String],
        returns: String,
        afterUse: String
    ) -> String {
        var sections = [
            "Purpose: \(purpose)",
            "Use when:\n\(bulletList(useWhen))"
        ]
        if !arguments.isEmpty {
            sections.append("Arguments:\n\(bulletList(arguments))")
        }
        sections.append("Returns: \(returns)")
        sections.append("After use: \(afterUse)")
        return sections.joined(separator: "\n")
    }

    static func bulletList(_ values: [String]) -> String {
        values.map { "- \($0)" }.joined(separator: "\n")
    }

}
