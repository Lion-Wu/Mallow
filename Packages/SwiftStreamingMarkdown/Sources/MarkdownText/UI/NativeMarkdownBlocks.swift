// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License. See LICENSE in the project root for license information.

import SwiftUI
import HighlightSwift
#if canImport(AppKit)
import AppKit
typealias MarkdownNativeLabel = NSTextField
typealias MarkdownNativeButton = NSButton
typealias MarkdownNativeScroll = NSScrollView
#else
import UIKit
typealias MarkdownNativeLabel = UILabel
typealias MarkdownNativeButton = UIButton
typealias MarkdownNativeScroll = UIScrollView
#endif

class MarkdownNativeBlock: MarkdownLayoutView {
  var onSizeChange: (() -> Void)?
  func measure(width: CGFloat) -> CGSize { .zero }
  func placeContent() {}
  func requestLayout() {
    #if canImport(AppKit)
    needsLayout = true
    #else
    setNeedsLayout()
    #endif
  }
  #if canImport(AppKit)
  override var isFlipped: Bool { true }
  override func layout() { super.layout(); placeContent() }
  #else
  override func layoutSubviews() { super.layoutSubviews(); placeContent() }
  #endif
}

@MainActor
private func nativeLabel() -> MarkdownNativeLabel {
  #if canImport(AppKit)
  let label = NSTextField(labelWithString: "")
  label.lineBreakMode = .byClipping
  #else
  let label = UILabel()
  #endif
  return label
}

@MainActor
private func configure(_ label: MarkdownNativeLabel, text: String, font: MDFont, color: MDColor) {
  #if canImport(AppKit)
  label.stringValue = text
  #else
  label.text = text
  #endif
  label.font = font
  label.textColor = color
}

@MainActor
private func configure(_ button: MarkdownNativeButton, title: String, image: String,
                       color: MDColor, target: AnyObject, action: Selector) {
  #if canImport(AppKit)
  button.title = title
  button.font = Typography.smallTextFonts.normal
  button.isBordered = false
  button.image = Bundle.module.image(forResource: image)
  button.image?.isTemplate = true
  button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
  button.contentTintColor = color
  button.target = target
  button.action = action
  #else
  var configuration = UIButton.Configuration.plain()
  configuration.title = title
  configuration.image = UIImage(named: image, in: .module, compatibleWith: nil)
  configuration.imagePadding = 6
  configuration.contentInsets = .zero
  configuration.baseForegroundColor = color
  configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
    var result = attributes
    result.font = Typography.smallTextFonts.normal
    return result
  }
  button.configuration = configuration
  button.removeTarget(nil, action: nil, for: .touchUpInside)
  button.addTarget(target, action: action, for: .touchUpInside)
  #endif
}

@MainActor
private func background(_ view: MarkdownLayoutView, color: MDColor?, radius: CGFloat = 0) {
  #if canImport(AppKit)
  view.wantsLayer = true
  view.layer?.backgroundColor = color?.cgColor
  view.layer?.cornerRadius = radius
  view.layer?.cornerCurve = .continuous
  view.layer?.masksToBounds = radius > 0
  #else
  view.backgroundColor = color
  view.layer.cornerRadius = radius
  view.layer.cornerCurve = .continuous
  view.clipsToBounds = radius > 0
  #endif
}

final class MarkdownNativeCodeBlock: MarkdownNativeBlock {
  private let languageLabel = nativeLabel()
  private let copyButton = MarkdownNativeButton()
  private let codeView = MarkdownCodeLayoutView()
  private var code = ""
  private var language = ""
  private var copied = false
  private var config: MarkdownRenderConfig?
  private var highlight: NativeCodeHighlight?
  private var feedbackTask: Task<Void, Never>?
  private var headerHeight: CGFloat { ceil(Typography.smallTextFonts.normal.lineHeight) + 24 }

  override init(frame: CGRect) {
    super.init(frame: frame)
    addSubview(languageLabel)
    addSubview(copyButton)
    addSubview(codeView)
  }
  required init?(coder: NSCoder) { nil }
  isolated deinit { feedbackTask?.cancel() }

  func update(language: String, code: String, config: MarkdownRenderConfig,
              controller: MarkdownController?, openURL: OpenURLAction, highlight: NativeCodeHighlight?) {
    let requestChanged = self.code != code || self.language != language || self.config != config || self.highlight != highlight
    self.code = code
    self.language = language
    self.config = config
    self.highlight = highlight
    let color = MDColor(config.codeBlockConfig.foregroundColor ?? Color.Static.Stone.Stone350)
    configure(languageLabel, text: language, font: Typography.smallTextFonts.normal, color: color)
    configure(copyButton, title: copied ? .codeCopiedLabel : .codeCopyLabel, image: "copyIcon14",
              color: color, target: self, action: #selector(copyCode))
    background(self, color: config.codeBlockConfig.backgroundColor.map(MDColor.init), radius: 20)
    guard requestChanged else { return }
    let plain = AttributedString(code).applyingSearchHighlight(query: config.searchHighlightQuery)
    codeView.update(markdownCodeContents(plain), config: config, controller: controller, openURL: openURL)
    if let highlight { codeView.applySyntaxColors(highlight) }
    requestLayout()
  }

  override func measure(width: CGFloat) -> CGSize {
    CGSize(width: width, height: headerHeight + codeView.textSize.height + 32)
  }

  override func placeContent() {
    let buttonWidth = ceil((copied ? String.codeCopiedLabel : String.codeCopyLabel).size(
      withAttributes: [.font: Typography.smallTextFonts.normal]).width) + 24
    let labelFrame = CGRect(x: 16, y: 12, width: max(0, bounds.width - buttonWidth - 48), height: headerHeight - 24)
    #if canImport(AppKit)
    languageLabel.frame = languageLabel.frame(forAlignmentRect: labelFrame)
    #else
    languageLabel.frame = labelFrame
    #endif
    copyButton.frame = CGRect(x: bounds.width - buttonWidth - 16, y: 12, width: buttonWidth, height: headerHeight - 24)
    codeView.frame = CGRect(x: 16, y: headerHeight + 16, width: max(0, bounds.width - 32), height: codeView.textSize.height)
  }

  @objc private func copyCode() {
    #if canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(code, forType: .string)
    #else
    UIPasteboard.general.string = code
    #endif
    copied = true
    updateCopyFeedback()
    feedbackTask?.cancel()
    feedbackTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, let self else { return }
      copied = false
      updateCopyFeedback()
    }
  }

  private func updateCopyFeedback() {
    guard let config else { return }
    configure(copyButton, title: copied ? .codeCopiedLabel : .codeCopyLabel, image: "copyIcon14",
              color: MDColor(config.codeBlockConfig.foregroundColor ?? Color.Static.Stone.Stone350),
              target: self, action: #selector(copyCode))
    requestLayout()
  }
}

final class MarkdownNativeTableBlock: MarkdownNativeBlock {
  private let scrollView = MarkdownNativeScroll()
  private let grid = MarkdownTableLayoutView()

  func setTextAnimationEnabled(_ enabled: Bool) {
    grid.setTextAnimationEnabled(enabled)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    #if canImport(AppKit)
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.documentView = grid
    #else
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.addSubview(grid)
    #endif
    addSubview(scrollView)
  }
  required init?(coder: NSCoder) { nil }

  func update(headers: [NSMutableAttributedString], rows: [[NSMutableAttributedString]],
              config: MarkdownRenderConfig, controller: MarkdownController?, openURL: OpenURLAction,
              layout: MarkdownTableLayout? = nil) {
    let cells = ([headers] + rows).enumerated().map { row, contents in
      contents.map { source in
        markdownTableCellContent(source, isHeader: row == 0, config: config)
      }
    }
    grid.update(cells: cells, columnMaxWidths: Array(repeating: 200, count: headers.count),
                config: config, controller: controller, openURL: openURL, layout: layout)
    background(grid, color: nil, radius: 12)
    #if canImport(AppKit)
    grid.layer?.borderWidth = 1
    grid.layer?.borderColor = MDColor(config.tableStyle.borderColor).cgColor
    #else
    grid.layer.borderWidth = 1
    grid.layer.borderColor = MDColor(config.tableStyle.borderColor).cgColor
    #endif
    requestLayout()
  }

  override func measure(width: CGFloat) -> CGSize {
    CGSize(width: width, height: grid.measuredSize.height)
  }
  override func placeContent() {
    scrollView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: grid.measuredSize.height)
    grid.frame = CGRect(origin: .zero, size: grid.measuredSize)
    // Placement can change the visible columns without changing the grid size.
    grid.invalidateViewportLayout()
    #if canImport(UIKit)
    scrollView.contentSize = grid.measuredSize
    #endif
  }
}
