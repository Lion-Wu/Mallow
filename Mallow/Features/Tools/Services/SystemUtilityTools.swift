//
//  SystemUtilityTools.swift
//  Mallow
//
//  Created by Codex on 2026.06.24.
//

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

protocol ClipboardToolServing: Sendable {
    func getText(arguments: ChatToolArgumentReader) async throws -> ChatToolExecutionPayload
    func setText(arguments: ChatToolArgumentReader) async throws -> ChatToolExecutionPayload
}

protocol SystemActionToolServing: Sendable {
    func openURL(arguments: ChatToolArgumentReader) async throws -> ChatToolExecutionPayload
    func currentTime(arguments: ChatToolArgumentReader) async throws -> ChatToolExecutionPayload
}

struct SystemClipboardTool: ClipboardToolServing {
    func getText(arguments: ChatToolArgumentReader) async throws -> ChatToolExecutionPayload {
        #if canImport(UIKit)
        let text = await MainActor.run { UIPasteboard.general.string ?? "" }
        #elseif canImport(AppKit)
        let text = await MainActor.run { NSPasteboard.general.string(forType: .string) ?? "" }
        #else
        throw ChatToolError.unsupported(NSLocalizedString("TOOLS_CLIPBOARD_UNSUPPORTED", value: "Clipboard is not available on this platform.", comment: "Tool-use error"))
        #endif
        let limited = String(text.prefix(10_000))
        return ChatToolExecutionPayload(
            payload: [
                "text": .string(limited),
                "truncated": .bool(text.count > limited.count)
            ],
            summary: limited.isEmpty
                ? NSLocalizedString("TOOLS_CLIPBOARD_NO_TEXT", value: "Clipboard did not contain text.", comment: "Tool summary")
                : NSLocalizedString("TOOLS_CLIPBOARD_READ", value: "Clipboard text was read.", comment: "Tool summary")
        )
    }

    func setText(arguments: ChatToolArgumentReader) async throws -> ChatToolExecutionPayload {
        let text = try arguments.requiredRawString("text")
        guard text.count <= 10_000 else {
            throw ChatToolError.invalidArguments(NSLocalizedString("TOOLS_CLIPBOARD_TEXT_TOO_LONG", value: "text must contain at most 10000 characters.", comment: "Tool-use error"))
        }
        try Task.checkCancellation()
        #if canImport(UIKit)
        try await MainActor.run {
            try Task.checkCancellation()
            UIPasteboard.general.string = text
        }
        #elseif canImport(AppKit)
        try await MainActor.run {
            try Task.checkCancellation()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        #else
        throw ChatToolError.unsupported(NSLocalizedString("TOOLS_CLIPBOARD_UNSUPPORTED", value: "Clipboard is not available on this platform.", comment: "Tool-use error"))
        #endif
        return ChatToolExecutionPayload(
            payload: ["character_count": .number(Double(text.count))],
            summary: NSLocalizedString("TOOLS_CLIPBOARD_UPDATED", value: "Clipboard text was updated.", comment: "Tool summary")
        )
    }
}

struct DefaultSystemActionTool: SystemActionToolServing {
    func openURL(arguments: ChatToolArgumentReader) async throws -> ChatToolExecutionPayload {
        let rawURL = try arguments.requiredString("url")
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "maps"].contains(scheme) else {
            throw ChatToolError.invalidArguments(NSLocalizedString("TOOLS_URL_SCHEME_NOT_ALLOWED", value: "URL scheme is not allowed.", comment: "Tool-use error"))
        }
        try Task.checkCancellation()

        #if canImport(UIKit)
        let opened = try await Self.openUIKitURL(url)
        #elseif canImport(AppKit)
        let opened = try await MainActor.run {
            try Task.checkCancellation()
            return NSWorkspace.shared.open(url)
        }
        #else
        throw ChatToolError.unsupported(NSLocalizedString("TOOLS_URL_UNSUPPORTED", value: "Opening URLs is not available on this platform.", comment: "Tool-use error"))
        #endif

        guard opened else {
            throw ChatToolError.failed(NSLocalizedString("TOOLS_URL_OPEN_FAILED", value: "The system could not open the URL.", comment: "Tool-use error"))
        }
        return ChatToolExecutionPayload(
            payload: ["url": .string(url.absoluteString)],
            summary: NSLocalizedString("TOOLS_URL_OPENED", value: "URL was opened.", comment: "Tool summary")
        )
    }

    #if canImport(UIKit)
    @MainActor
    private static func openUIKitURL(_ url: URL) async throws -> Bool {
        try Task.checkCancellation()
        return await UIApplication.shared.open(url, options: [:])
    }
    #endif

    func currentTime(arguments: ChatToolArgumentReader) async throws -> ChatToolExecutionPayload {
        let now = Date()
        var calendar = Calendar.autoupdatingCurrent
        let timeZone = TimeZone.autoupdatingCurrent
        calendar.timeZone = timeZone
        var payload: [String: JSONValue] = [
            "iso_time": .string(ChatToolTimeFormatter.localISO8601String(from: now, timeZone: timeZone)),
            "local_iso_time": .string(ChatToolTimeFormatter.localISO8601String(from: now, timeZone: timeZone)),
            "utc_iso_time": .string(ChatToolTimeFormatter.utcISO8601String(from: now)),
            "local_date": .string(ChatToolTimeFormatter.localDateString(from: now, calendar: calendar)),
            "local_time": .string(ChatToolTimeFormatter.localClockString(from: now, calendar: calendar)),
            "locale": .string(Locale.autoupdatingCurrent.identifier),
            "year": .number(Double(calendar.component(.year, from: now))),
            "month": .number(Double(calendar.component(.month, from: now))),
            "day": .number(Double(calendar.component(.day, from: now))),
            "hour": .number(Double(calendar.component(.hour, from: now))),
            "minute": .number(Double(calendar.component(.minute, from: now))),
            "second": .number(Double(calendar.component(.second, from: now)))
        ]
        payload.merge(ChatToolTimeFormatter.timeZonePayloadFields(for: now, timeZone: timeZone)) { current, _ in current }
        return ChatToolExecutionPayload(
            payload: payload,
            summary: NSLocalizedString("TOOLS_TIME_READ", value: "Current time was read.", comment: "Tool summary")
        )
    }
}
