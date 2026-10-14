//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

#if canImport(UIKit)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AccessibilityContent {
  let label: String?
  let actions: [UIAccessibilityCustomAction]
}

private struct CachedParagraphUIViewSize {
  let size: CGSize
  let targetWidth: CGFloat
}

#if os(iOS)
private final class ParagraphTextContainer: NSTextContainer {
  override var size: CGSize {
    get { super.size }
    set {
      // A non-scrolling UITextView also writes its fitted height independently of
      // heightTracksTextView. This paragraph is constrained only by width; zero
      // denotes unlimited height and keeps view growth from invalidating layout.
      let layoutSize = CGSize(width: newValue.width, height: 0)
      guard super.size != layoutSize else { return }
      super.size = layoutSize
    }
  }
}
#endif

class ParagraphUIView: UITextView {
  private static let jsonEncoder = JSONEncoder()
  static let animationDuration: CFTimeInterval = ParagraphAnimationConstants.fadeInDuration

  private(set) var paragraphContents: NSMutableAttributedString = NSMutableAttributedString()
  private(set) var lineSpacing: CGFloat?
  private var activeAnimations: [FadeAnimationData] = []
  private var fadeAnimationDisplayLink: CADisplayLink?
  private var cachedSize: CachedParagraphUIViewSize?
  private var layoutWidth: CGFloat = 0
  #if os(iOS)
  private let measuringTextStorage = NSTextStorage()
  private let measuringLayoutManager = NSLayoutManager()
  private let measuringContainer = NSTextContainer(size: .zero)
  #endif

  var textContextMenu: TextContextMenu?
  var markdownController: MarkdownController?

  var onUrlTap: (URL) -> Void = { UIApplication.shared.open($0) }

  #if os(iOS)
  convenience init() {
    let storage = NSTextStorage()
    let drawingLayoutManager = ParagraphFadeLayoutManager()
    // Match the exact full-paragraph geometry used by the outer scroll view.
    drawingLayoutManager.allowsNonContiguousLayout = false
    storage.addLayoutManager(drawingLayoutManager)
    let container = ParagraphTextContainer(size: .zero)
    drawingLayoutManager.addTextContainer(container)
    self.init(frame: .zero, textContainer: container)
    drawingLayoutManager.animations = { [weak self] in self?.activeAnimations ?? [] }
  }
  #endif

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    delegate = self
    setupView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    delegate = self
    setupView()
  }

  isolated deinit {
    tearDownDisplayLink()
    activeAnimations.removeAll()
  }

  override func willMove(toWindow newWindow: UIWindow?) {
    super.willMove(toWindow: newWindow)
    // Fix for crash: "UIPreviewTarget requires that the container view is in a window". When the view is removed from the window (e.g. scrolled out in LazyVStack), we should clear the selection to prevent any pending menu or drag interactions from trying to reference the detached view.
    if newWindow == nil {
      selectedTextRange = nil
    }
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result {
      selectedTextRange = nil
    }
    return result
  }

  #if !os(visionOS)
  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle {
      AppAppearance.update(style: traitCollection.userInterfaceStyle)
    }
  }
  #endif

  override var intrinsicContentSize: CGSize {
    if let cachedSize {
      return cachedSize.size
    }
    var targetWidth = bounds.width
    if targetWidth <= 0 || targetWidth.isInfinite {
      // When bounds.width is not valid, we have to give a best guess, otherwise Chat becomes blank in some cases sometimes. It may be related to LazyVStack.
      #if os(visionOS)
      targetWidth = max(
        max(window?.bounds.width ?? 0, superview?.bounds.width ?? 0),
        1
      )
      #else
      targetWidth = UIScreen.main.bounds.width
      #endif
    }
    let targetSize = CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
    let contentSize = sizeThatFits(targetSize)
    let roundedUpSize = CGSize(width: contentSize.width.rounded(.up), height: contentSize.height.rounded(.up))
    cachedSize = CachedParagraphUIViewSize(size: roundedUpSize, targetWidth: targetWidth)
    return roundedUpSize
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if bounds.width != layoutWidth {
      layoutWidth = bounds.width
      invalidateCachedSize()
      invalidateIntrinsicContentSize()
    }
  }

  #if os(iOS)
  func measureSize(fittingWidth width: CGFloat) -> CGSize {
    guard measuringTextStorage.length > 0, width > 0, width.isFinite else { return .zero }
    if measuringContainer.size.width != width {
      measuringContainer.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }
    measuringLayoutManager.ensureLayout(for: measuringContainer)
    let rect = measuringLayoutManager.usedRect(for: measuringContainer)
    return CGSize(width: width, height: rect.height.rounded(.up))
  }
  #endif

  func setParagraphContents(_ newContents: NSMutableAttributedString, lineSpacing: CGFloat? = nil, animatedByWord: Bool) {
    // Keep the cached interface style up to date for citation preview rendering.
    // This runs on the main thread so it's safe to read traitCollection here.
    AppAppearance.update(style: traitCollection.userInterfaceStyle)

    guard paragraphContents != newContents || self.lineSpacing != lineSpacing else {
      return
    }
    self.paragraphContents = newContents
    self.lineSpacing = lineSpacing

    let oldAttributedString: NSAttributedString = attributedText
    let oldLength = oldAttributedString.length
    let layoutContents = markdownTextLayoutContents(newContents)
    let finalString: NSAttributedString
    if lineSpacing != nil {
      finalString = applyLineSpacing(to: layoutContents, lineSpacing: lineSpacing)
    } else {
      finalString = layoutContents
    }

    guard finalString != oldAttributedString else {
      return
    }

    invalidateCachedSize()
    if let textLayoutManager, let contentManager = textLayoutManager.textContentManager {
      textLayoutManager.removeRenderingAttribute(.foregroundColor, for: contentManager.documentRange)
    }
    #if os(iOS)
    let commonLength = textStorage.replaceContentsPreservingPrefix(with: finalString)
    measuringTextStorage.replaceContentsPreservingPrefix(with: finalString)
    #else
    let commonLength = oldAttributedString.string.commonPrefix(with: finalString.string, options: .literal).utf16.count
    attributedText = finalString
    #endif

    configureAccessibility(for: finalString)

    invalidateIntrinsicContentSize()

    let newContentLength = finalString.length - commonLength

    if animatedByWord {
      // Attribute changes preserve the timeline of unchanged characters.
      if commonLength < oldLength {
        updateTextViewWithCurrentAnimations()
        activeAnimations = activeAnimations.compactMap { animation in
          let range = NSIntersectionRange(animation.range, NSRange(location: 0, length: commonLength))
          guard range.length > 0 else { return nil }
          return FadeAnimationData(startTime: animation.startTime, duration: animation.duration, range: range)
        }
      }
      let newContentRange = NSRange(location: commonLength, length: newContentLength)
      let wordRanges = attributedText.splitIntoWords(withIn: newContentRange)
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
      #if os(iOS)
      // Prefix-preserving edits leave earlier drawing tiles intact. Invalidate
      // the fading range when its opacity stops being owned by the animation.
      updateTextViewWithCurrentAnimations()
      #endif
      activeAnimations.removeAll()
      tearDownDisplayLink()
    }
  }

  private func applyLineSpacing(to attributedString: NSAttributedString, lineSpacing: CGFloat?) -> NSMutableAttributedString {
    let result = NSMutableAttributedString(attributedString: attributedString)
    if let lineSpacing {
      result.setLineSpacing(lineSpacing)
    }
    return result
  }

  private func setupView() {
    #if os(iOS)
    measuringContainer.lineFragmentPadding = 0
    measuringContainer.lineBreakMode = .byWordWrapping
    measuringLayoutManager.addTextContainer(measuringContainer)
    measuringTextStorage.addLayoutManager(measuringLayoutManager)
    #endif
    LatexViewProvider.register()

    isEditable = false
    spellCheckingType = .no
    autocorrectionType = .no
    isSelectable = true
    isScrollEnabled = false
    textAlignment = .left
    backgroundColor = .clear
    #if os(visionOS)
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
      (view: ParagraphUIView, _) in
      AppAppearance.update(style: view.traitCollection.userInterfaceStyle)
    }
    if #available(visionOS 2.4, *) {
      writingToolsBehavior = .none
    }
    #else
    if #available(iOS 18.0, *) {
      writingToolsBehavior = .none
    }
    #endif

    setContentHuggingPriority(.defaultHigh, for: .vertical)
    setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
    setContentHuggingPriority(.defaultLow, for: .horizontal)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    textContainerInset = .zero
    textContainer.lineFragmentPadding = 0
    textContainer.widthTracksTextView = true
    #if os(iOS)
    // The paragraph grows to its measured height; that height is not a layout constraint.
    textContainer.heightTracksTextView = false
    #else
    textContainer.heightTracksTextView = true
    #endif
    textContainer.maximumNumberOfLines = 0
    textContainer.lineBreakMode = .byWordWrapping

    // When this is empty, UITextView will not override the styles set by attributes
    self.linkTextAttributes = [:]

    // Disable drag interaction to prevent crashes related to dragging from a view that might disappear
    textDragInteraction?.isEnabled = false
  }

  /// Creates a custom accessibility action that forwards activation to `onUrlTap`.
  private func makeAccessibilityAction(name: String, url: URL) -> UIAccessibilityCustomAction {
    return UIAccessibilityCustomAction(name: name) { [weak self] _ in
      guard let self else { return false }
      self.onUrlTap(url)
      return true
    }
  }

  /// Generate accessibility label and actions in a single pass (optimized)
  private func generateAccessibilityContent(from attributedString: NSAttributedString) -> AccessibilityContent? {
    var labelComponents: [String] = []
    var actions: [UIAccessibilityCustomAction] = []
    let fullRange = NSRange(location: 0, length: attributedString.length)

    attributedString.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
      // Handle citation attachments
      if let attachment = attrs[.attachment] as? InlineCitationAttachment,
         let citationData = attachment.citationData {
        // Add to accessibility label
        labelComponents.append(citationData.accessibilityLabel)

        // Create accessibility action for citations
        let actionName = String.openCitation(citationLabel: citationData.accessibilityLabel)
        let action = makeAccessibilityAction(name: actionName, url: citationData.url)
        actions.append(action)
      } else {
        // Add the regular text for this range
        let substring = attributedString.attributedSubstring(from: range)
        let text = substring.string
        if !text.isEmpty {
          labelComponents.append(text)
        }
      }
    }

    let accessibilityLabel = labelComponents.isEmpty ? nil : labelComponents.joined()

    // Return nil if no attachments were found
    guard !actions.isEmpty else { return nil }

    return AccessibilityContent(label: accessibilityLabel, actions: actions)
  }

  /// Configure accessibility properties for the text view
  private func configureAccessibility(for attributedString: NSAttributedString) {
    // Generate the full accessibility content directly
    if let accessibilityContent = generateAccessibilityContent(from: attributedString) {
      // We have citations, use the generated content
      accessibilityLabel = accessibilityContent.label
      accessibilityCustomActions = accessibilityContent.actions
    } else {
      // No citations found, just use the plain text
      accessibilityLabel = attributedString.string
      accessibilityCustomActions = nil
    }
  }

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
    #if os(iOS)
    guard let first = activeAnimations.first, let last = activeAnimations.last else { return }
    let range = NSIntersectionRange(
      NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location),
      NSRange(location: 0, length: textStorage.length)
    )
    layoutManager.invalidateDisplay(forCharacterRange: range)
    #else
    guard let textLayoutManager,
          let contentManager = textLayoutManager.textContentManager else { return }
    let currentTime = CACurrentMediaTime()

    for animation in activeAnimations {
      guard animation.range.location + animation.range.length <= textStorage.length else {
        continue
      }
      guard let start = contentManager.location(contentManager.documentRange.location, offsetBy: animation.range.location),
            let end = contentManager.location(start, offsetBy: animation.range.length),
            let textRange = NSTextRange(location: start, end: end) else { continue }
      let elapsed = currentTime - animation.startTime
      if elapsed >= animation.duration {
        textLayoutManager.removeRenderingAttribute(.foregroundColor, for: textRange)
        continue
      }
      let animatedAlpha: CGFloat

      if elapsed < 0 {
        animatedAlpha = 0.0
      } else {
        let progress = min(max(elapsed / animation.duration, 0.0), 1.0)
        let easedProgress = paragraphEaseOut(progress)
        animatedAlpha = easedProgress
      }

      // Apply alpha to this animation's range, preserving each span's
      // existing foreground color. Spans with no foreground color get a
      // sensible default so they still fade in instead of disappearing.
      let defaultColor = UIColor(Color.Theme.Foreground.Primary.Primary750)
      textStorage.enumerateAttribute(.foregroundColor, in: animation.range, options: []) { value, range, _ in
        let baseColor = (value as? UIColor) ?? defaultColor
        guard let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return }
        // Rendering attributes preserve the document while fading its glyphs.
        textLayoutManager.addRenderingAttribute(
          .foregroundColor,
          value: baseColor.withAlphaComponent(baseColor.cgColor.alpha * animatedAlpha),
          for: textRange
        )
      }
    }
    #endif
  }

  private func setUpDisplayLink() {
    fadeAnimationDisplayLink = CADisplayLink(target: self, selector: #selector(updateFadeAnimation))
    fadeAnimationDisplayLink?.preferredFramesPerSecond = 60
    fadeAnimationDisplayLink?.add(to: .main, forMode: .common)
  }

  private func tearDownDisplayLink() {
    fadeAnimationDisplayLink?.invalidate()
    fadeAnimationDisplayLink = nil
  }

  private func invalidateCachedSize() {
    cachedSize = nil
  }

  func setTextContextMenu(_ menu: TextContextMenu?) {
    textContextMenu = menu
  }

  func setMarkdownController(_ controller: MarkdownController?) {
    markdownController = controller
  }
}

// MARK: - UITextViewDelegate
extension ParagraphUIView: UITextViewDelegate {
  #if os(visionOS)
  func textView(
    _ textView: UITextView,
    primaryActionFor textItem: UITextItem,
    defaultAction: UIAction
  ) -> UIAction? {
    switch textItem.content {
    case .link(let url):
      return UIAction { [weak self] _ in
        self?.onUrlTap(url)
      }
    case .textAttachment(let attachment):
      guard let citationAttachment = attachment as? InlineCitationAttachment,
            let citationData = citationAttachment.citationData else {
        return nil
      }
      return UIAction { [weak self] _ in
        self?.onUrlTap(citationData.url)
      }
    case .tag:
      return defaultAction
    @unknown default:
      return defaultAction
    }
  }
  #else
  func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
    self.onUrlTap(URL)
    return false
  }

  func textView(_ textView: UITextView, shouldInteractWith textAttachment: NSTextAttachment, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
    // Check if this is our custom citation attachment with pre-decoded data
    if let citationAttachment = textAttachment as? InlineCitationAttachment,
       let citationData = citationAttachment.citationData {
      self.onUrlTap(citationData.url)
      return false
    }

    return false
  }
  #endif

  func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
    guard let textContextMenu else { return nil }
    return textContextMenu.buildUIMenu(
      textView: textView,
      selectedRange: range,
      suggestedActions: suggestedActions,
      markdownController: markdownController
    )
  }

  func textView(_ textView: UITextView, willPresentEditMenuWith animator: any UIEditMenuInteractionAnimating) {
    guard let textContextMenu, let markdownController else { return }
    let clampedRange = NSIntersectionRange(textView.selectedRange, NSRange(location: 0, length: textView.attributedText.length))
    let selectedText = textView.attributedText.attributedSubstring(from: clampedRange).string
    for group in textContextMenu.menuGroups {
      for item in group.items where item.id != TextSelectionConfig.selectMoreItemID {
        markdownController.onContextMenuAppear(id: item.id, selectedContent: selectedText)
      }
    }
  }
}

fileprivate extension NSMutableAttributedString {
  func setLineSpacing(_ lineSpacing: CGFloat) {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = lineSpacing
    paragraphStyle.alignment = .left
    addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: length))
  }
}
#endif
