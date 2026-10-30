import Foundation

enum ChatToolSchemaValidator {
    static func validate(
        _ value: JSONValue,
        against schema: JSONValue,
        path: String = "arguments"
    ) throws {
        if schema == .bool(true) { return }
        if schema == .bool(false) { throw invalid(path, requirement: "an allowed value") }
        guard case let .object(rules) = schema else { throw invalid(path, requirement: "a valid schema") }
        if let constant = rules["const"], value != constant { throw invalid(path, requirement: "the declared constant") }
        for keyword in ["allOf", "anyOf", "oneOf"] {
            if case let .array(options)? = rules[keyword] {
                let matches = options.filter { (try? validate(value, against: $0, path: path)) != nil }.count
                let valid = keyword == "allOf" ? matches == options.count : keyword == "oneOf" ? matches == 1 : matches > 0
                guard valid else { throw invalid(path, requirement: keyword) }
            }
        }
        if let excluded = rules["not"], (try? validate(value, against: excluded, path: path)) != nil {
            throw invalid(path, requirement: "a non-excluded value")
        }
        if case let .array(types)? = rules["type"] {
            guard types.contains(where: { type in
                if case let .string(name) = type { return matchesType(value, expectedType: name) }
                return false
            }) else { throw invalid(path, requirement: "one of the declared types") }
        }

        if case let .array(allowedValues)? = rules["enum"],
           !allowedValues.contains(value) {
            throw invalid(path, requirement: "one of the declared values")
        }
        if case let .string(expectedType)? = rules["type"],
           !matchesType(value, expectedType: expectedType) {
            throw invalid(path, requirement: expectedTypeRequirement(expectedType))
        }

        switch value {
        case let .object(fields):
            try validateObject(fields, rules: rules, path: path)
        case let .array(values):
            try validateCount(values.count, minimum: rules["minItems"], maximum: rules["maxItems"], path: path)
            if rules["uniqueItems"] == .bool(true) {
                for index in values.indices where values[..<index].contains(values[index]) {
                    throw invalid(path, requirement: "unique items")
                }
            }
            if let itemSchema = rules["items"] {
                for (index, item) in values.enumerated() {
                    try validate(item, against: itemSchema, path: "\(path)[\(index)]")
                }
            }
        case let .number(number):
            if case let .number(minimum)? = rules["minimum"], number < minimum {
                throw invalid(path, requirement: "a number greater than or equal to \(minimum)")
            }
            if case let .number(maximum)? = rules["maximum"], number > maximum {
                throw invalid(path, requirement: "a number less than or equal to \(maximum)")
            }
            if case let .number(minimum)? = rules["exclusiveMinimum"], number <= minimum { throw invalid(path, requirement: "a number above the exclusive minimum") }
            if case let .number(maximum)? = rules["exclusiveMaximum"], number >= maximum { throw invalid(path, requirement: "a number below the exclusive maximum") }
        case let .string(text):
            try validateCount(text.unicodeScalars.count, minimum: rules["minLength"], maximum: rules["maxLength"], path: path)
            if case let .string(pattern)? = rules["pattern"] {
                let expression = try NSRegularExpression(pattern: pattern)
                guard expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else {
                    throw invalid(path, requirement: "a string matching the declared pattern")
                }
            }
        case .bool, .null:
            break
        }
    }

    private static func validateObject(
        _ fields: [String: JSONValue],
        rules: [String: JSONValue],
        path: String
    ) throws {
        try validateCount(fields.count, minimum: rules["minProperties"], maximum: rules["maxProperties"], path: path)
        let properties: [String: JSONValue]
        if case let .object(value)? = rules["properties"] {
            properties = value
        } else {
            properties = [:]
        }

        if rules["additionalProperties"] == .bool(false),
           let unknownKey = fields.keys.sorted().first(where: { properties[$0] == nil }) {
            throw invalid("\(path).\(unknownKey)", requirement: "a declared argument")
        }
        if case let .array(requiredValues)? = rules["required"] {
            for requiredValue in requiredValues {
                guard case let .string(requiredKey) = requiredValue else { continue }
                guard fields[requiredKey] != nil else {
                    throw ChatToolError.invalidArguments("\(path).\(requiredKey) is required.")
                }
            }
        }
        for (key, fieldValue) in fields {
            if let fieldSchema = properties[key] {
                try validate(fieldValue, against: fieldSchema, path: "\(path).\(key)")
            } else if case .object? = rules["additionalProperties"], let extraSchema = rules["additionalProperties"] {
                try validate(fieldValue, against: extraSchema, path: "\(path).\(key)")
            }
        }
    }

    private static func validateCount(_ count: Int, minimum: JSONValue?, maximum: JSONValue?, path: String) throws {
        if case let .number(minimum)? = minimum, Double(count) < minimum { throw invalid(path, requirement: "the declared minimum length") }
        if case let .number(maximum)? = maximum, Double(count) > maximum { throw invalid(path, requirement: "the declared maximum length") }
    }

    private static func matchesType(_ value: JSONValue, expectedType: String) -> Bool {
        switch (expectedType, value) {
        case ("string", .string), ("number", .number), ("boolean", .bool),
             ("object", .object), ("array", .array), ("null", .null):
            return true
        case let ("integer", .number(number)):
            return number.isFinite && number.rounded(.towardZero) == number
        default:
            return false
        }
    }

    private static func expectedTypeRequirement(_ type: String) -> String {
        switch type {
        case "string": return "a string"
        case "number": return "a number"
        case "integer": return "an integer"
        case "boolean": return "a boolean"
        case "object": return "an object"
        case "array": return "an array"
        case "null": return "null"
        default: return "a \(type) value"
        }
    }

    private static func invalid(_ path: String, requirement: String) -> ChatToolError {
        .invalidArguments("\(path) must be \(requirement).")
    }
}
