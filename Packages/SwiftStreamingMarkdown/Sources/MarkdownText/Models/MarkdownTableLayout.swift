// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License. See LICENSE in the project root for license information.

import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Exact table geometry. Plain text can be measured during parsing; attachment
/// measurement belongs to the main actor because TextKit can load provider views.
struct MarkdownTableLayout: Equatable, Sendable {
  let columnWidths: [CGFloat]
  let rowHeights: [CGFloat]
  let rowOrigins: [CGFloat]
  let size: CGSize

  init?(precomputing cells: [[NSAttributedString]], columnMaxWidths: [CGFloat]) {
    guard !cells.joined().contains(where: {
      $0.containsAttachments(in: NSRange(location: 0, length: $0.length))
    }) else { return nil }
    self.init(measuring: cells, columnMaxWidths: columnMaxWidths)
  }

  @MainActor
  init(cells: [[NSAttributedString]], columnMaxWidths: [CGFloat]) {
    LatexViewProvider.register()
    self.init(measuring: cells.map { $0.map { markdownTextLayoutContents($0) } }, columnMaxWidths: columnMaxWidths)
  }

  private init(measuring cells: [[NSAttributedString]], columnMaxWidths: [CGFloat]) {
    let columns = columnMaxWidths.count
    guard columns > 0 else {
      columnWidths = []; rowHeights = []; rowOrigins = []; size = .zero
      return
    }
    let contents = cells.flatMap { $0 }
    var widths = Array(repeating: CGFloat.zero, count: columns)
    for (index, content) in contents.enumerated() {
      let column = index % columns
      let natural = content.boundingRect(
        with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).width.rounded(.up)
      var attachmentWidth: CGFloat = 0
      content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, _ in
        guard let attachment = value as? NSTextAttachment else { return }
        attachmentWidth = max(attachmentWidth, attachment.bounds.width)
      }
      // A formula is an indivisible inline object. The text wrapping limit
      // cannot make its column narrower than the formula plus cell padding.
      // Match each original cell's 12-point padding and trailing Spacer.
      let width = max(min(columnMaxWidths[column], natural + 32), attachmentWidth + 32)
      widths[column] = max(widths[column], width)
    }
    let storage = NSTextStorage()
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: .zero)
    #if canImport(AppKit)
    manager.backgroundLayoutEnabled = false
    #endif
    manager.allowsNonContiguousLayout = false
    container.lineFragmentPadding = 0
    container.lineBreakMode = .byWordWrapping
    manager.addTextContainer(container)
    storage.addLayoutManager(manager)
    var heights = Array(repeating: CGFloat.zero, count: cells.count)
    for (index, content) in contents.enumerated() {
      storage.setAttributedString(content)
      let containerSize = CGSize(width: max(1, widths[index % columns] - 32), height: .greatestFiniteMagnitude)
      #if canImport(AppKit)
      container.containerSize = containerSize
      #else
      container.size = containerSize
      #endif
      manager.ensureLayout(for: container)
      let height = manager.usedRect(for: container).height.rounded(.up)
      heights[index / columns] = max(heights[index / columns], height + 24)
    }
    var y: CGFloat = 0
    rowOrigins = heights.map { height in
      defer { y += height }
      return y
    }
    columnWidths = widths
    rowHeights = heights
    size = CGSize(width: widths.reduce(0, +), height: y)
  }
}

func markdownTableCellContent(_ source: NSAttributedString, isHeader: Bool, config: MarkdownRenderConfig) -> NSMutableAttributedString {
  let result = NSMutableAttributedString(attributedString: source)
  let range = NSRange(location: 0, length: result.length)
  let color = MDColor(isHeader ? config.tableStyle.headerTextColor : config.tableStyle.regularTextColor)
  result.enumerateAttribute(.foregroundColor, in: range) { value, range, _ in
    if value == nil { result.addAttribute(.foregroundColor, value: color, range: range) }
  }
  var citations: [NSRange] = []
  var hasOtherContent = false
  result.enumerateAttributes(in: range) { attributes, range, _ in
    if let citation = attributes[.attachment] as? InlineCitationAttachment, citation.citationData != nil {
      citations.append(range)
    } else if range.length > 0 {
      hasOtherContent = true
    }
  }
  if hasOtherContent {
    for citation in citations { result.addAttribute(.baselineOffset, value: Typography.base.mdFont.descender, range: citation) }
  }
  return result
}
