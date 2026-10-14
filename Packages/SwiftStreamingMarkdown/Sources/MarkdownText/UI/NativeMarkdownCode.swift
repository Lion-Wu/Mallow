// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License. See LICENSE in the project root for license information.

import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

final class MarkdownCodeLayoutView: MarkdownLayoutView {
  private let paragraph = MarkdownLayoutParagraph()
  #if canImport(AppKit)
  private let scrollView = NSScrollView()
  #else
  private let scrollView = UIScrollView()
  #endif
  private(set) var textSize = CGSize.zero
  private var sourceContents = NSAttributedString(string: "")

  override init(frame: CGRect) {
    super.init(frame: frame)
    #if canImport(AppKit)
    paragraph.textContainerInset = .zero
    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = true
    scrollView.hasVerticalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.documentView = paragraph
    #else
    scrollView.showsVerticalScrollIndicator = false
    scrollView.alwaysBounceVertical = false
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.addSubview(paragraph)
    #endif
    addSubview(scrollView)
  }

  required init?(coder: NSCoder) { nil }

  #if canImport(AppKit)
  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: textSize.height) }
  override func layout() { super.layout(); placeText() }
  #else
  override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: textSize.height) }
  override func layoutSubviews() { super.layoutSubviews(); placeText() }
  #endif

  func update(_ contents: NSMutableAttributedString, config: MarkdownRenderConfig,
              controller: MarkdownController?, openURL: OpenURLAction) {
    paragraph.onUrlTap = openURL.callAsFunction(_:)
    paragraph.setTextContextMenu(config.resolvedTextContextMenu)
    paragraph.setMarkdownController(controller)
    let foreground = MDColor(config.paragraphStyle.textColor)
    contents.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: contents.length)) { value, range, _ in
      if value == nil { contents.addAttribute(.foregroundColor, value: foreground, range: range) }
    }
    guard sourceContents != contents else { return }
    if !contents.string.utf16.starts(with: sourceContents.string.utf16) {
      clearSyntaxColors()
    }
    sourceContents = NSAttributedString(attributedString: contents)
    paragraph.setParagraphContents(contents, animatedByWord: false)
    let rect = contents.boundingRect(
      with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    let width = max(1, rect.width.rounded(.up))
    #if os(visionOS)
    let height = paragraph.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    #else
    let height = paragraph.measureSize(fittingWidth: width).height
    #endif
    textSize = CGSize(width: width, height: height)
    invalidateIntrinsicContentSize()
    #if canImport(AppKit)
    needsLayout = true
    #else
    setNeedsLayout()
    #endif
  }

  /// Syntax colors do not change source glyphs, whitespace, or measured geometry.
  func applySyntaxColors(_ highlighted: NativeCodeHighlight) {
    guard sourceContents.string.utf16.starts(with: highlighted.source.utf16) else { return }
    #if canImport(AppKit) || os(iOS)
    guard let manager = paragraph.layoutManager as? ParagraphFadeLayoutManager else { return }
    let spans = highlighted.spans.map { ParagraphFadeLayoutManager.SyntaxColorSpan(range: $0.range, color: $0.color) }
    manager.selectedCharacterRange = { [weak paragraph] in
      #if canImport(AppKit)
      paragraph?.selectedRange() ?? NSRange(location: NSNotFound, length: 0)
      #else
      paragraph?.selectedRange ?? NSRange(location: NSNotFound, length: 0)
      #endif
    }
    manager.setSyntaxColors(spans)
    #else
    guard let manager = paragraph.textLayoutManager,
          let content = manager.textContentManager else { return }
    manager.removeRenderingAttribute(.foregroundColor, for: content.documentRange)
    for span in highlighted.spans {
      guard let start = content.location(content.documentRange.location, offsetBy: span.range.location),
            let end = content.location(start, offsetBy: span.range.length),
            let textRange = NSTextRange(location: start, end: end) else { continue }
      manager.addRenderingAttribute(.foregroundColor, value: span.color, for: textRange)
    }
    #endif
  }

  private func clearSyntaxColors() {
    #if canImport(AppKit) || os(iOS)
    (paragraph.layoutManager as? ParagraphFadeLayoutManager)?.setSyntaxColors([])
    #else
    if let manager = paragraph.textLayoutManager, let content = manager.textContentManager {
      manager.removeRenderingAttribute(.foregroundColor, for: content.documentRange)
    }
    #endif
  }

  private func placeText() {
    scrollView.frame = bounds
    let size = CGSize(width: max(bounds.width, textSize.width), height: textSize.height)
    paragraph.frame = CGRect(origin: .zero, size: size)
    #if canImport(UIKit)
    scrollView.contentSize = size
    #endif
  }
}

@MainActor
func markdownCodeContents(_ content: AttributedString) -> NSMutableAttributedString {
    let attributed = NSMutableAttributedString(attributedString: NSAttributedString(content))
    let range = NSRange(location: 0, length: attributed.length)
    let fonts = Typography.codeTextFonts
    attributed.addAttribute(.font, value: fonts.normal, range: range)
    if let spacing = fonts.preferredLetterSpacing {
      attributed.addAttribute(.kern, value: spacing, range: range)
    }
    let style = NSMutableParagraphStyle()
    style.lineSpacing = max(0, (fonts.preferredLineHeight ?? fonts.normal.lineHeight) - fonts.normal.lineHeight)
    attributed.addAttribute(.paragraphStyle, value: style, range: range)
    return attributed
}
