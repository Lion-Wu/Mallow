// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License. See LICENSE in the project root for license information.

import Foundation
import WebKit
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

struct HighlightScope: Hashable, Sendable {
  /// Each entry is one span's class list, ordered from outermost to innermost.
  let classes: [String]
}

/// Parses the highlighter's escaped text and span-only markup, without laying
/// out the code in an HTML document or creating any display views.
final class HighlightMarkup: NSObject, XMLParserDelegate {
  struct Run {
    var range: NSRange
    let scope: HighlightScope
  }
  private(set) var text = ""
  private(set) var runs: [Run] = []
  private var length = 0
  private var classes: [String] = []
  private var invalid = false

  static func parse(_ markup: String) throws -> HighlightMarkup {
    // XML normalizes literal carriage returns. Character references preserve
    // the exact source positions used by TextKit, including CRLF source text.
    let escaped = markup.replacingOccurrences(of: "\r", with: "&#13;")
    let parser = XMLParser(data: Data(("<root>" + escaped + "</root>").utf8))
    let document = HighlightMarkup()
    parser.delegate = document
    parser.shouldResolveExternalEntities = false
    let success = parser.parse()
    try Task.checkCancellation()
    guard success, !document.invalid else { throw NativeHighlightError.invalidMarkup }
    return document
  }

  func parser(_ parser: XMLParser, didStartElement elementName: String,
              namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
    if elementName == "root" { return }
    guard elementName == "span", let value = attributes["class"] else {
      invalid = true
      parser.abortParsing()
      return
    }
    classes.append(value)
  }

  func parser(_ parser: XMLParser, didEndElement elementName: String,
              namespaceURI: String?, qualifiedName qName: String?) {
    if elementName == "span" { classes.removeLast() }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if Task.isCancelled { parser.abortParsing(); return }
    guard !string.isEmpty else { return }
    let scope = HighlightScope(classes: classes)
    let count = string.utf16.count
    if let last = runs.last, last.scope == scope {
      runs[runs.count - 1].range.length += count
    } else {
      runs.append(Run(range: NSRange(location: length, length: count), scope: scope))
    }
    text.append(string)
    length += count
  }

  /// CSS is a theme input, independent of code length. Resolve each distinct
  /// token ancestry once using the platform's CSS importer, then reuse its
  /// native color for every matching source range. This preserves descendant
  /// selectors and inherited colors without importing the full code document.
  @MainActor
  static func resolveColors(for scopes: [HighlightScope], css: String) async throws -> [HighlightScope: MDColor] {
    var html = "<style>" + css + "</style><pre><code class=\"hljs\">"
    for scope in scopes {
      for classes in scope.classes {
        let escaped = classes.replacingOccurrences(of: "&", with: "&amp;")
          .replacingOccurrences(of: "\"", with: "&quot;")
        html += "<span class=\"" + escaped + "\">"
      }
      html += "x"
      for _ in scope.classes { html += "</span>" }
      html += "\n"
    }
    html += "</code></pre>"
    return try await withCheckedThrowingContinuation { continuation in
      NSAttributedString.loadFromHTML(string: html, options: [:]) { sample, _, error in
        if let error { continuation.resume(throwing: error); return }
        guard let sample else {
          continuation.resume(throwing: NativeHighlightError.invalidPalette)
          return
        }
        do {
          continuation.resume(returning: try colors(in: sample, for: scopes))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private static func colors(in sample: NSAttributedString, for scopes: [HighlightScope]) throws -> [HighlightScope: MDColor] {
    let text = sample.string as NSString
    var offset = 0
    var result: [HighlightScope: MDColor] = [:]
    for scope in scopes {
      let marker = text.range(of: "x", options: .literal,
                              range: NSRange(location: offset, length: text.length - offset))
      guard marker.location != NSNotFound else { throw NativeHighlightError.invalidPalette }
      let attribute = sample.attribute(.foregroundColor, at: marker.location, effectiveRange: nil)
      if let attribute {
        guard let color = attribute as? MDColor else { throw NativeHighlightError.invalidPalette }
        result[scope] = color
      } else {
        // NSAttributedString defines an absent foreground as black. UIKit's
        // HTML importer omits this attribute for the theme's default black.
        result[scope] = .black
      }
      offset = NSMaxRange(marker)
    }
    return result
  }
}
