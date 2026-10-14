//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

#if canImport(AppKit)
import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

class ParagraphNSView: NSTextView {
  private static let jsonEncoder = JSONEncoder()
  static let animationDuration: CFTimeInterval = ParagraphAnimationConstants.fadeInDuration

  private(set) var paragraphContents: NSMutableAttributedString = NSMutableAttributedString()
  private(set) var lineSpacing: CGFloat?
  private var activeAnimations: [FadeAnimationData] = []
  private var fadeAnimationDisplayLink: CADisplayLink?
  private var isApplyingFrameSize = false
  private let measuringTextStorage = NSTextStorage()
  private let measuringLayoutManager = NSLayoutManager()
  private let measuringContainer = NSTextContainer(size: .zero)

  var textContextMenu: TextContextMenu?
  var markdownController: MarkdownController?

  var onUrlTap: (URL) -> Void = { NSWorkspace.shared.open($0) }

  convenience init() {
    let textStorage = NSTextStorage()
    let layoutManager = ParagraphFadeLayoutManager()
    textStorage.addLayoutManager(layoutManager)
    let textContainer = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    textContainer.widthTracksTextView = true
    textContainer.heightTracksTextView = false
    layoutManager.addTextContainer(textContainer)
    self.init(frame: .zero, textContainer: textContainer)
  }

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
    super.init(frame: frameRect, textContainer: container)
    setupView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupView()
  }

  isolated deinit {
    tearDownDisplayLink()
    activeAnimations.removeAll()
  }

  // MARK: - Appearance

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    AppAppearance.update(appearance: effectiveAppearance)
  }

  override func resetCursorRects() {
    // Cursor regions only belong to the visible part of a paragraph. AppKit
    // invalidates them again when scrolling changes the clipping geometry.
    let visible = visibleRect.intersection(bounds)
    guard !visible.isEmpty, !visible.isNull else { return }
    super.resetCursorRects()
  }

  override func addCursorRect(_ rect: NSRect, cursor: NSCursor) {
    let visible = rect.intersection(visibleRect).intersection(bounds)
    guard !visible.isEmpty, !visible.isNull else { return }
    super.addCursorRect(visible, cursor: cursor)
  }

  override func setFrameSize(_ newSize: NSSize) {
    let wasApplyingFrameSize = isApplyingFrameSize
    isApplyingFrameSize = true
    defer { isApplyingFrameSize = wasApplyingFrameSize }
    super.setFrameSize(newSize)
  }

  override func scrollToVisible(_ rect: NSRect) -> Bool {
    // NSTextView reveals its selection while resizing. Paragraph layout must
    // not cancel the enclosing transcript's scroll animation or reader anchor.
    // Selection and accessibility requests outside sizing still scroll normally.
    guard !isApplyingFrameSize else { return false }
    return super.scrollToVisible(rect)
  }

  // MARK: - Intrinsic Content Size

  // SwiftUI owns paragraph sizing through sizeThatFits. Deriving an intrinsic
  // size from the frame feeds layout output back into the next layout proposal.
  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  /// The measurement stack owns its proposed width independently of the view
  /// frame, and retains glyph/layout state across appended source snapshots.
  func measureSize(fittingWidth width: CGFloat) -> CGSize {
    guard measuringTextStorage.length > 0, width > 0, width.isFinite else { return .zero }
    if measuringContainer.containerSize.width != width {
      measuringContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }
    measuringLayoutManager.ensureLayout(for: measuringContainer)
    let usedRect = measuringLayoutManager.usedRect(for: measuringContainer)
    return CGSize(width: usedRect.width.rounded(.up), height: usedRect.height.rounded(.up))
  }

  // MARK: - Content Update

  func setParagraphContents(_ newContents: NSMutableAttributedString, lineSpacing: CGFloat? = nil, animatedByWord: Bool) {
    AppAppearance.update(appearance: effectiveAppearance)

    guard paragraphContents != newContents || self.lineSpacing != lineSpacing else {
      return
    }
    self.paragraphContents = newContents
    self.lineSpacing = lineSpacing

    let oldLength = textStorage?.length ?? 0
    let layoutContents = markdownTextLayoutContents(newContents)
    let finalString: NSAttributedString
    if lineSpacing != nil {
      finalString = applyLineSpacing(to: layoutContents, lineSpacing: lineSpacing)
    } else {
      finalString = layoutContents
    }

    let commonLength = textStorage?.replaceContentsPreservingPrefix(with: finalString) ?? 0
    measuringTextStorage.replaceContentsPreservingPrefix(with: finalString)

    configureAccessibility(for: finalString)

    let newContentLength = finalString.length - commonLength

    if animatedByWord {
      // Formatting-only updates must not finish an in-flight fade. Retain the
      // animation timeline for unchanged text and animate only the replaced suffix.
      if commonLength < oldLength {
        updateTextViewWithCurrentAnimations()
        activeAnimations = activeAnimations.compactMap { animation in
          let range = NSIntersectionRange(animation.range, NSRange(location: 0, length: commonLength))
          guard range.length > 0 else { return nil }
          return FadeAnimationData(startTime: animation.startTime, duration: animation.duration, range: range)
        }
      }
      let newContentRange = NSRange(location: commonLength, length: newContentLength)
      let wordRanges = finalString.splitIntoWords(withIn: newContentRange)
      let wordCount = wordRanges.count
      let delayBetweenWords: Double = ParagraphAnimationConstants.delayBetweenWordsRatio / Double(max(wordCount, 1))
      let baseStartTime = CACurrentMediaTime()
      for (index, wordRange) in wordRanges.enumerated() {
        let animationData = FadeAnimationData(
          startTime: baseStartTime + Double(index) * delayBetweenWords,
          duration: Self.animationDuration,
          range: wordRange
        )
        activeAnimations.append(animationData)
      }

      updateTextViewWithCurrentAnimations()

      if !activeAnimations.isEmpty, fadeAnimationDisplayLink == nil {
        setUpDisplayLink()
      }
    } else {
      // Prefix-preserving edits do not redraw unchanged animated words. Settle
      // their drawing state before retiring the animation's display link.
      updateTextViewWithCurrentAnimations()
      activeAnimations.removeAll()
      tearDownDisplayLink()
    }
  }

  // MARK: - Line Spacing

  private func applyLineSpacing(to attributedString: NSAttributedString, lineSpacing: CGFloat?) -> NSMutableAttributedString {
    let result = NSMutableAttributedString(attributedString: attributedString)
    if let lineSpacing {
      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.lineSpacing = lineSpacing
      paragraphStyle.alignment = .left
      result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))
    }
    return result
  }

  // MARK: - View Setup

  private func setupView() {
    let drawingLayoutManager = layoutManager as? ParagraphFadeLayoutManager ?? ParagraphFadeLayoutManager()
    drawingLayoutManager.backgroundLayoutEnabled = false
    // SwiftUI positions this full-height paragraph using exact measured geometry.
    // Skipping offscreen line fragments would give drawing a different Y origin.
    drawingLayoutManager.allowsNonContiguousLayout = false
    measuringLayoutManager.backgroundLayoutEnabled = false
    measuringContainer.lineFragmentPadding = 0
    measuringContainer.maximumNumberOfLines = 0
    measuringContainer.lineBreakMode = .byWordWrapping
    measuringLayoutManager.addTextContainer(measuringContainer)
    measuringTextStorage.addLayoutManager(measuringLayoutManager)
    drawingLayoutManager.animations = { [weak self] in self?.activeAnimations ?? [] }
    if layoutManager !== drawingLayoutManager {
      textContainer?.replaceLayoutManager(drawingLayoutManager)
    }

    LatexViewProvider.register()

    isEditable = false
    isContinuousSpellCheckingEnabled = false
    isGrammarCheckingEnabled = false
    isSelectable = true
    drawsBackground = false
    textContainer?.lineFragmentPadding = 0
    textContainer?.widthTracksTextView = true
    textContainer?.heightTracksTextView = false
    textContainer?.maximumNumberOfLines = 0
    textContainer?.lineBreakMode = .byWordWrapping

    // The representable owns the frame; NSTextView must not resize itself.
    isVerticallyResizable = false
    isHorizontallyResizable = false

    linkTextAttributes = [:]

    setContentHuggingPriority(.defaultHigh, for: .vertical)
    setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
    setContentHuggingPriority(.defaultLow, for: .horizontal)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

  // MARK: - Accessibility

  private func generateAccessibilityContent(from attributedString: NSAttributedString) -> (label: String?, actions: [() -> Void])? {
    var labelComponents: [String] = []
    var hasAttachments = false
    let fullRange = NSRange(location: 0, length: attributedString.length)

    attributedString.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
      if let attachment = attrs[.attachment] as? InlineCitationAttachment,
         let citationData = attachment.citationData {
        labelComponents.append(citationData.accessibilityLabel)
        hasAttachments = true
      } else {
        let text = attributedString.attributedSubstring(from: range).string
        if !text.isEmpty {
          labelComponents.append(text)
        }
      }
    }

    guard hasAttachments else { return nil }
    let label = labelComponents.isEmpty ? nil : labelComponents.joined()
    return (label: label, actions: [])
  }

  private func configureAccessibility(for attributedString: NSAttributedString) {
    if let content = generateAccessibilityContent(from: attributedString) {
      setAccessibilityLabel(content.label)
    } else {
      setAccessibilityLabel(attributedString.string)
    }
  }

  // MARK: - Fade Animation

  @objc private func updateFadeAnimation() {
    let currentTime = CACurrentMediaTime()
    updateTextViewWithCurrentAnimations()

    // Expiration is local to each animation; an ID lookup per element makes
    // cleanup quadratic when a large streamed chunk introduces many words.
    activeAnimations.removeAll { currentTime - $0.startTime >= $0.duration }

    if activeAnimations.isEmpty {
      tearDownDisplayLink()
    }
  }

  private func updateTextViewWithCurrentAnimations() {
    guard let textStorage, let layoutManager,
          let first = activeAnimations.first,
          let last = activeAnimations.last else { return }
    let range = NSIntersectionRange(
      NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location),
      NSRange(location: 0, length: textStorage.length)
    )
    // Measurement uses a separate layout manager. Display invalidation only
    // schedules glyphs already laid out by this drawing stack.
    if let textContainer, window != nil, !visibleRect.isEmpty {
      layoutManager.ensureLayout(
        forBoundingRect: visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y),
        in: textContainer
      )
    }
    layoutManager.invalidateDisplay(forCharacterRange: range)
  }

  private func setUpDisplayLink() {
    let link = displayLink(
      target: self,
      selector: #selector(updateFadeAnimation)
    )
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    link.add(to: .main, forMode: .common)
    fadeAnimationDisplayLink = link
  }

  private func tearDownDisplayLink() {
    fadeAnimationDisplayLink?.invalidate()
    fadeAnimationDisplayLink = nil
  }

  func setTextContextMenu(_ menu: TextContextMenu?) {
    textContextMenu = menu
  }

  func setMarkdownController(_ controller: MarkdownController?) {
    markdownController = controller
  }

  // MARK: - Link Clicks

  // swiftlint:disable:next no_any
  override func clicked(onLink link: Any, at charIndex: Int) {
    if let url = link as? URL {
      onUrlTap(url)
    } else if let string = link as? String, let url = URL.fromMixedEncodingString(string) {
      onUrlTap(url)
    }
  }

  // MARK: - Context Menu

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let textContextMenu, let textStorage else {
      return super.menu(for: event)
    }

    let selectedRange = self.selectedRange()
    let clampedRange = NSIntersectionRange(selectedRange, NSRange(location: 0, length: textStorage.length))
    let selectedText = textStorage.attributedSubstring(from: clampedRange).string

    // Start from the native context menu so system items (Copy, Look Up,
    // Translate, Share, Services, …) are preserved, then inject the configured
    // groups at the top, above the system items.
    let menu = super.menu(for: event) ?? NSMenu()

    var injected: [NSMenuItem] = []
    // The built-in "Select more text" group (when enabled) is prepended by
    // `MarkdownRenderConfig.resolvedTextContextMenu`, so it renders first.
    for group in textContextMenu.menuGroups {
      if group.displayInline {
        for item in group.items {
          injected.append(makeMenuItem(for: item, selectedText: selectedText))
        }
      } else {
        let submenu = NSMenu(title: group.title ?? "")
        for item in group.items {
          submenu.addItem(makeMenuItem(for: item, selectedText: selectedText))
        }
        let submenuItem = NSMenuItem(title: group.title ?? "", action: nil, keyEquivalent: "")
        submenuItem.submenu = submenu
        injected.append(submenuItem)
      }
      injected.append(.separator())
    }

    // Insert the block in order at the top; its trailing separator divides it
    // from the native items (Copy, …) that follow.
    var insertAt = 0
    for item in injected {
      menu.insertItem(item, at: insertAt)
      insertAt += 1
    }

    // Notify controller of menu appearance (excluding the built-in item)
    if let markdownController {
      for group in textContextMenu.menuGroups {
        for item in group.items where item.id != TextSelectionConfig.selectMoreItemID {
          markdownController.onContextMenuAppear(id: item.id, selectedContent: selectedText)
        }
      }
    }

    return menu
  }

  private func makeMenuItem(for item: TextContextMenuItem, selectedText: String) -> NSMenuItem {
    if item.id == TextSelectionConfig.selectMoreItemID {
      let menuItem = NSMenuItem(title: item.title, action: #selector(selectMoreTextTapped), keyEquivalent: "")
      menuItem.target = self
      return menuItem
    }
    let menuItem = NSMenuItem(title: item.title, action: #selector(contextMenuItemTapped(_:)), keyEquivalent: "")
    menuItem.representedObject = ContextMenuAction(id: item.id, selectedText: selectedText)
    menuItem.target = self
    return menuItem
  }

  @objc private func selectMoreTextTapped() {
    markdownController?.requestTextSelection()
  }

  @objc private func contextMenuItemTapped(_ sender: NSMenuItem) {
    guard let action = sender.representedObject as? ContextMenuAction else { return }
    markdownController?.onContextMenuTap(id: action.id, selectedContent: action.selectedText)
  }
}

// MARK: - Context Menu Action Helper

private struct ContextMenuAction {
  let id: String
  let selectedText: String
}

#endif
