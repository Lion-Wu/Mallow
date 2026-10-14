// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License. See LICENSE in the project root for license information.

import SwiftUI
#if canImport(AppKit)
import AppKit
typealias MarkdownNativeImage = NSImageView
#else
import UIKit
typealias MarkdownNativeImage = UIImageView
#endif

final class MarkdownNativeListBlock: MarkdownNativeBlock {
  @MainActor
  final class Row {
    let first = MarkdownDocumentLayoutView()
    let remaining = MarkdownDocumentLayoutView()
    let marker = MarkdownListMarker()
    var hasRemaining = false
    var firstLineHeight: CGFloat = 0
    var firstSize = CGSize.zero
    var remainingSize = CGSize.zero
  }
  private var rows: [Row] = []
  private var ordered = false
  private var nestedLevel = 0
  private var updating = false

  func setTextAnimationEnabled(_ enabled: Bool) {
    for row in rows {
      row.first.setTextAnimationEnabled(enabled)
      row.remaining.setTextAnimationEnabled(enabled)
    }
  }

  func update(items: [MarkdownListItem], ordered: Bool, nestedLevel: Int,
              owner: MarkdownDocumentController?, config: MarkdownRenderConfig,
              controller: MarkdownController?, openURL: OpenURLAction) {
    updating = true
    defer { updating = false }
    self.ordered = ordered
    self.nestedLevel = nestedLevel
    while rows.count > items.count {
      let row = rows.removeLast()
      row.first.removeFromSuperview()
      row.remaining.removeFromSuperview()
      row.marker.removeFromSuperview()
    }
    while rows.count < items.count {
      let row = Row()
      addSubview(row.first)
      addSubview(row.remaining)
      addSubview(row.marker)
      let changed: () -> Void = { [weak self] in
        guard let self, !updating else { return }
        onSizeChange?()
        requestLayout()
      }
      row.first.onSizeChange = changed
      row.remaining.onSizeChange = changed
      rows.append(row)
    }
    for (index, item) in items.enumerated() {
      let row = rows[index]
      row.first.owner = owner
      row.remaining.owner = owner
      row.first.update(Array(item.children.prefix(1)), config: config, controller: controller, openURL: openURL)
      row.remaining.update(Array(item.children.dropFirst()), config: config, controller: controller, openURL: openURL)
      row.hasRemaining = item.children.count > 1
      row.marker.update(index: index, ordered: ordered, nestedLevel: nestedLevel, checkbox: item.checkbox, config: config)
      if case .paragraph(_, let content) = item.children.first {
        let font = content.length > 0 ? content.attribute(.font, at: 0, effectiveRange: nil) as? MDFont : nil
        let citation = content.length > 0 ? content.attribute(.attachment, at: 0, effectiveRange: nil) as? InlineCitationAttachment : nil
        row.firstLineHeight = (citation?.font ?? font ?? Typography.base.mdFont).lineHeight
        var label = markdownListAccessibilityLabel(for: content.string, at: index, length: items.count)
        if let checkbox = item.checkbox {
          label += ", " + (checkbox == .checked ? String.taskListItemChecked : String.taskListItemUnchecked)
        }
        row.first.setFirstParagraphAccessibilityLabel(label)
      } else {
        row.firstLineHeight = config.orderedListStyle.textFonts.normal.lineHeight
      }
    }
    requestLayout()
  }

  override func measure(width: CGFloat) -> CGSize {
    var height: CGFloat = 0
    let indent = ordered ? 0 : CGFloat(nestedLevel) * 8
    for row in rows {
      let firstWidth = max(1, width - indent - row.marker.markerSize.width - (ordered ? 22 : 2) - 8)
      row.firstSize = CGSize(width: firstWidth, height: row.first.measure(width: firstWidth))
      height += max(row.firstSize.height, row.marker.markerSize.height)
      if row.hasRemaining {
        row.remainingSize = CGSize(width: max(1, width - indent), height: row.remaining.measure(width: max(1, width - indent)))
        height += 8 + row.remainingSize.height
      }
      height += 8
    }
    return CGSize(width: width, height: max(0, height - (rows.isEmpty ? 0 : 8)))
  }

  override func placeContent() {
    _ = measure(width: bounds.width)
    let indent = ordered ? 0 : CGFloat(nestedLevel) * 8
    var y: CGFloat = 0
    for row in rows {
      let markerSize = row.marker.markerSize
      row.marker.frame = CGRect(x: indent, y: y + max(0, (row.firstLineHeight - markerSize.height) / 2), width: markerSize.width, height: markerSize.height)
      row.first.frame = CGRect(origin: CGPoint(x: indent + markerSize.width + (ordered ? 11 : 1), y: y), size: row.firstSize)
      y += max(row.firstSize.height, markerSize.height)
      if row.hasRemaining {
        y += 8
        row.remaining.frame = CGRect(origin: CGPoint(x: indent, y: y), size: row.remainingSize)
        y += row.remainingSize.height
      }
      y += 8
    }
  }
}

final class MarkdownListMarker: MarkdownNativeBlock {
  private var text: MarkdownLayoutParagraph?
  private let image = MarkdownNativeImage()
  private(set) var markerSize = CGSize.zero
  private var ordered = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    addSubview(image)
  }
  required init?(coder: NSCoder) { nil }

  func update(index: Int, ordered: Bool, nestedLevel: Int, checkbox: MarkdownListItem.Checkbox?, config: MarkdownRenderConfig) {
    self.ordered = ordered
    text?.isHidden = !ordered
    image.isHidden = ordered
    if ordered {
      let text: MarkdownLayoutParagraph
      if let existing = self.text {
        text = existing
      } else {
        text = MarkdownLayoutParagraph()
        text.isSelectable = false
        #if canImport(AppKit)
        text.textContainerInset = .zero
        #endif
        self.text = text
        addSubview(text)
      }
      let font = config.orderedListStyle.textFonts.bold ?? config.orderedListStyle.textFonts.normal
      let content = NSMutableAttributedString(string: "\(index + 1).", attributes: [.font: font, .foregroundColor: MDColor(config.orderedListStyle.textColor)])
      text.setParagraphContents(content, animatedByWord: false)
      markerSize = content.size()
      markerSize.width = ceil(markerSize.width)
      markerSize.height = ceil(markerSize.height)
    } else {
      markerSize = CGSize(width: 22, height: checkbox == nil ? 4 : 12)
      let color = MDColor(Color.Theme.Foreground.Primary.Primary450)
      let name: String
      if let checkbox {
        name = checkbox == .checked ? "checkmark.square.fill" : "square"
      } else {
        name = nestedLevel % 2 == 0 ? "circle.fill" : "circle"
      }
      #if canImport(AppKit)
      image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
      image.contentTintColor = color
      image.imageScaling = .scaleProportionallyUpOrDown
      #else
      image.image = UIImage(systemName: name)
      image.tintColor = color
      image.contentMode = .scaleAspectFit
      #endif
    }
    requestLayout()
  }
  override func placeContent() {
    text?.frame = bounds
    let imageSize = markerSize.height
    image.frame = CGRect(x: (bounds.width - imageSize) / 2, y: 0, width: imageSize, height: imageSize)
  }
}

final class MarkdownNativeQuoteBlock: MarkdownNativeBlock {
  private let text = MarkdownLayoutParagraph()
  private let divider = CAShapeLayer()
  private var children: [MarkdownNativeQuoteBlock] = []
  private var nested = false
  private var sizes: [CGSize] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    #if canImport(AppKit)
    wantsLayer = true
    layer?.addSublayer(divider)
    text.textContainerInset = .zero
    #else
    layer.addSublayer(divider)
    #endif
    addSubview(text)
  }
  required init?(coder: NSCoder) { nil }

  func update(_ item: BlockQuoteType, config: MarkdownRenderConfig, controller: MarkdownController?, openURL: OpenURLAction) {
    nested = item.isNested
    text.isHidden = nested
    divider.isHidden = !nested
    divider.fillColor = MDColor(Color.Theme.Stroke.Muted.Muted300).cgColor
    switch item {
    case .text(let source):
      for child in children { child.removeFromSuperview() }
      children.removeAll()
      let fonts = config.blockQuoteStyle.textFonts
      let content = NSMutableAttributedString(string: source, attributes: [.font: fonts.normal, .foregroundColor: MDColor(config.blockQuoteStyle.textColor)])
      if let spacing = fonts.preferredLetterSpacing { content.addAttribute(.kern, value: spacing, range: NSRange(location: 0, length: content.length)) }
      text.setParagraphContents(content, lineSpacing: max(0, (fonts.preferredLineHeight ?? fonts.normal.lineHeight) - fonts.normal.lineHeight), animatedByWord: false)
      text.onUrlTap = openURL.callAsFunction(_:)
      text.setTextContextMenu(config.resolvedTextContextMenu)
      text.setMarkdownController(controller)
    case .nested(let items):
      while children.count > items.count { children.removeLast().removeFromSuperview() }
      while children.count < items.count {
        let child = MarkdownNativeQuoteBlock()
        children.append(child)
        addSubview(child)
      }
      for (child, item) in zip(children, items) { child.update(item, config: config, controller: controller, openURL: openURL) }
    }
    requestLayout()
  }
  override func measure(width: CGFloat) -> CGSize {
    if nested {
      sizes = children.map { $0.measure(width: max(1, width - 11)) }
      return CGSize(width: width, height: 8 + sizes.reduce(0) { $0 + $1.height } + CGFloat(max(0, sizes.count - 1)) * 12)
    }
    #if os(visionOS)
    let size = text.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    #else
    let size = text.measureSize(fittingWidth: width)
    #endif
    return CGSize(width: width, height: size.height + 16)
  }
  override func placeContent() {
    _ = measure(width: bounds.width)
    if nested {
      var y: CGFloat = 4
      for (child, size) in zip(children, sizes) {
        child.frame = CGRect(origin: CGPoint(x: 11, y: y), size: size)
        y += size.height + 12
      }
    } else {
      text.frame = CGRect(x: 0, y: 8, width: bounds.width, height: max(0, bounds.height - 16))
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let frame = CGRect(x: 0, y: 0, width: 3, height: bounds.height)
    if divider.frame != frame {
      divider.frame = frame
      divider.path = RoundedRectangle(cornerRadius: 8, style: .continuous).path(in: divider.bounds).cgPath
    }
    CATransaction.commit()
  }
}

private func markdownListAccessibilityLabel(for item: String, at index: Int, length: Int) -> String {
  "\(String.markdownList(length: String(length))), item \(index + 1): \(item)"
}
