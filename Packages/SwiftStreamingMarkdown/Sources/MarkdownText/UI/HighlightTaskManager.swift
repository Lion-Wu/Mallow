//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import HighlightSwift
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Owns syntax parsing and theme resolution away from the UI thread.
/// Only small theme samples enter the HTML importer; code is mapped directly
/// from the highlighter's spans to native attributed ranges.
actor HighlightTaskManager {
  static let shared = HighlightTaskManager()

  private let highlighter = Highlight()
  private var palettes: [String: [HighlightScope: MDColor]] = [:]
  private var paletteTasks: [String: Task<Void, Error>] = [:]

  func highlightRanges(code: String, language: String, colors: HighlightColors) async throws -> NativeCodeHighlight {
    try Task.checkCancellation()
    let alias = language.trimmingCharacters(in: .whitespacesAndNewlines)
    let mode: HighlightMode = alias.isEmpty ? .automatic : .languageAliasIgnoreIllegal(alias)
    let markup = try await highlighter.markup(code, mode: mode)
    try Task.checkCancellation()
    let parsed = try HighlightMarkup.parse(markup)
    guard parsed.text == code else { throw NativeHighlightError.changedSource }
    let palette = try await palette(for: Set(parsed.runs.map(\.scope)), css: colors.css)
    try Task.checkCancellation()
    let spans = try parsed.runs.map { run -> NativeCodeHighlight.Span in
      guard let color = palette[run.scope] else { throw NativeHighlightError.invalidPalette }
      return .init(range: run.range, color: color)
    }
    return NativeCodeHighlight(source: code, spans: spans)
  }

  private func palette(for scopes: Set<HighlightScope>, css: String) async throws -> [HighlightScope: MDColor] {
    while true {
      try Task.checkCancellation()
      let colors = palettes[css] ?? [:]
      let missing = scopes.subtracting(colors.keys)
      guard !missing.isEmpty else { return colors }
      // Concurrent code blocks share one theme operation. New scope ancestries
      // are resolved only after the existing operation has populated its colors.
      let task: Task<Void, Error>
      if let pending = paletteTasks[css] {
        task = pending
      } else {
        let ordered = missing.sorted { $0.classes.lexicographicallyPrecedes($1.classes) }
        task = Task {
          defer { paletteTasks[css] = nil }
          let resolved = try await HighlightMarkup.resolveColors(for: ordered, css: css)
          palettes[css, default: [:]].merge(resolved) { _, new in new }
        }
        paletteTasks[css] = task
      }
      try await task.value
    }
  }


}

enum NativeHighlightError: Error {
  case changedSource
  case invalidMarkup
  case invalidPalette
}

struct NativeCodeHighlight: Equatable, Sendable {
  struct Span: Equatable, Sendable {
    let range: NSRange
    let color: MDColor
  }
  let source: String
  let spans: [Span]
}
