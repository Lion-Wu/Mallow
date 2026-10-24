//
//  PastedImagePayloadNormalizer.swift
//  Mallow
//
//  Created by Codex on 2026/6/13.
//

import CoreGraphics
import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum PastedImagePayloadNormalizer {
    // Clipboard adapters only identify the payload. Encoding belongs to the
    // asynchronous attachment importer shared by all ordinary image inputs.
    static func normalize(data: Data, mimeTypeHint: String?) -> (data: Data, mimeType: String?) {
        (data, canonicalMIMEType(mimeTypeHint) ?? sniffedMIMEType(from: data))
    }

    static func sniffedMIMEType(from data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return "image/tiff"
        }

        if data.count >= 12 {
            let marker = String(decoding: data[4..<12], as: UTF8.self).lowercased()
            if marker.contains("heic") || marker.contains("heif") {
                return "image/heic"
            }
            if marker.contains("webp") {
                return "image/webp"
            }
        }

        return nil
    }

    private static func canonicalMIMEType(_ mimeType: String?) -> String? {
        guard let mimeType else { return nil }
        let normalized = mimeType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "image/jpg":
            return "image/jpeg"
        case .some(let value) where !value.isEmpty:
            return value
        default:
            return nil
        }
    }

}
