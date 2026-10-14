// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License. See LICENSE in the project root for license information.

import SwiftUI
#if canImport(AppKit)
import AppKit
typealias MarkdownHostingController = NSHostingController<AnyView>
typealias MarkdownPlatformController = NSViewController
#else
import UIKit
typealias MarkdownHostingController = UIHostingController<AnyView>
typealias MarkdownPlatformController = UIViewController
#endif

/// Owns block geometry independently of SwiftUI's parent layout graph. Completed
/// blocks retain their native views and measured sizes while a stream grows.
@MainActor
struct NativeMarkdownDocument {
  @Environment(\.markdownConfig) var config
  @Environment(\.markdownController) var controller
  @Environment(\.openURL) var openURL
  @Environment(\.markdownViewportCoordinator) var viewportCoordinator
  let renderables: [MarkdownRenderable]

  func update(_ owner: MarkdownDocumentController) {
    owner.document.viewportCoordinator = viewportCoordinator
    owner.document.update(renderables, config: config, controller: controller, openURL: openURL)
  }
}

#if canImport(AppKit)
extension NativeMarkdownDocument: NSViewControllerRepresentable {
  func makeNSViewController(context: Context) -> MarkdownDocumentController { MarkdownDocumentController() }
  func updateNSViewController(_ owner: MarkdownDocumentController, context: Context) { update(owner) }
  func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: MarkdownDocumentController, context: Context) -> CGSize? {
    guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
    return CGSize(width: width, height: nsViewController.document.measure(width: width))
  }
}
#else
extension NativeMarkdownDocument: UIViewControllerRepresentable {
  func makeUIViewController(context: Context) -> MarkdownDocumentController { MarkdownDocumentController() }
  func updateUIViewController(_ owner: MarkdownDocumentController, context: Context) { update(owner) }
  func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: MarkdownDocumentController, context: Context) -> CGSize? {
    guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
    return CGSize(width: width, height: uiViewController.document.measure(width: width))
  }
}
#endif

final class MarkdownDocumentController: MarkdownPlatformController {
  let document = MarkdownDocumentLayoutView()
  init() {
    super.init(nibName: nil, bundle: nil)
    document.owner = self
  }
  required init?(coder: NSCoder) { nil }
  override func loadView() { view = document }
}

final class MarkdownDocumentLayoutView: MarkdownViewportView {
  final class Item {
    var renderable: MarkdownRenderable
    var view: MarkdownLayoutView?
    var host: MarkdownHostingController?
    var size: CGSize?
    var accessibilityLabel: String?
    init(_ renderable: MarkdownRenderable, view: MarkdownLayoutView? = nil, host: MarkdownHostingController? = nil) {
      self.renderable = renderable
      self.view = view
      self.host = host
    }
  }

  weak var owner: MarkdownDocumentController?
  var onSizeChange: (() -> Void)?
  private var items: [Item] = []
  private var measurementItems: [Int: Item] = [:]
  private weak var markdownController: MarkdownController?
  private var openURL: OpenURLAction?
  private var config: MarkdownRenderConfig?
  private var measuredWidth: CGFloat = 0
  private var measuredHeight: CGFloat = 0
  private var isMeasuring = false


  isolated deinit {
    for item in items {
      #if canImport(UIKit)
      item.host?.willMove(toParent: nil)
      #endif
      item.view?.removeFromSuperview()
      item.host?.removeFromParent()
    }
  }

  #if canImport(AppKit)
  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight) }

  #else
  override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight) }

  #endif

  func update(_ blocks: [MarkdownRenderable], config: MarkdownRenderConfig,
              controller: MarkdownController?, openURL: OpenURLAction) {
    // Animation policy affects future text updates, not existing block geometry.
    let configChanged = self.config?.withShouldAnimateText(value: config.shouldAnimateText) != config
    if self.config?.shouldAnimateText != config.shouldAnimateText {
      setTextAnimationEnabled(config.shouldAnimateText)
    }
    self.config = config
    self.markdownController = controller
    self.openURL = openURL
    if configChanged { measurementItems.removeAll() }
    var old = Dictionary(uniqueKeysWithValues: items.map { ($0.renderable.id, $0) })
    var changed = items.map { $0.renderable.id } != blocks.map(\.id)
    items = blocks.map { block in
      var existing = old.removeValue(forKey: block.id)
      // A streaming block can change kind, e.g. paragraph into a table.
      if let item = existing, item.renderable.nativeKind != block.nativeKind {
        remove(item)
        existing = nil
      }
      let item = existing ?? Item(block)
      if existing == nil || item.renderable != block || configChanged {
        changed = true
        item.renderable = block
        item.size = nil
        if item.view == nil, !block.hasReusableMeasurement { makeView(for: item) }
        if item.view != nil { configure(item) }
      }
      return item
    }
    for item in old.values { remove(item) }
    if changed { invalidateMeasuredHeight() }
  }

  func setTextAnimationEnabled(_ enabled: Bool) {
    config = config?.withShouldAnimateText(value: enabled)
    for item in items {
      if let list = item.view as? MarkdownNativeListBlock {
        list.setTextAnimationEnabled(enabled)
      } else if let table = item.view as? MarkdownNativeTableBlock {
        table.setTextAnimationEnabled(enabled)
      }
    }
  }

  private func makeView(for item: Item) {
    let block = item.renderable
    if block.nativeParagraph {
      item.view = MarkdownLayoutParagraph()
    } else if block.isCodeBlock {
      item.view = MarkdownNativeCodeBlock()
    } else if case .table = block {
      item.view = MarkdownNativeTableBlock()
    } else if block.nativeKind == 4 {
      item.view = MarkdownNativeListBlock()
    } else if case .blockQuote = block {
      item.view = MarkdownNativeQuoteBlock()
    } else {
      let host = MarkdownHostingController(rootView: AnyView(EmptyView()))
      host.sizingOptions = []
      owner?.addChild(host)
      addSubview(host.view)
      #if canImport(UIKit)
      host.view.backgroundColor = .clear
      host.didMove(toParent: owner)
      #endif
      item.view = host.view
      item.host = host
    }
  }

  private func configure(_ item: Item, measurementOnly: Bool = false) {
    guard let config, let openURL else { return }
    let block = item.renderable
    let controller = markdownController
    if let text = item.view as? MarkdownLayoutParagraph {
      let animateAppearance = !measurementOnly && config.shouldAnimateText && text.paragraphContents.length == 0
      text.onUrlTap = openURL.callAsFunction(_:)
      switch block {
      case .paragraph(_, let content):
        #if canImport(UIKit)
        text.accessibilityTraits.remove(.header)
        #else
        text.setAccessibilityRole(.textArea)
        #endif
        text.setParagraphContents(content, lineSpacing: 5, animatedByWord: text.window != nil && config.shouldAnimateText)
      case .heading(_, _, let content):
        text.setParagraphContents(content, animatedByWord: text.window != nil && config.shouldAnimateText)
        #if canImport(UIKit)
        text.accessibilityTraits.insert(.header)
        #else
        if #available(macOS 26.0, *) {
          text.setAccessibilityRole(.headingRole)
        } else {
          text.setAccessibilityRole(.staticText)
        }
        #endif
      default: break
      }
      if animateAppearance {
        #if canImport(AppKit)
        text.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
          context.duration = ParagraphNSView.animationDuration
          text.animator().alphaValue = 1
        }
        #else
        text.alpha = 0
        UIView.animate(withDuration: ParagraphUIView.animationDuration) { text.alpha = 1 }
        #endif
      }
      text.setTextContextMenu(config.resolvedTextContextMenu)
      text.setMarkdownController(controller)
      if let label = item.accessibilityLabel {
        #if canImport(AppKit)
        text.setAccessibilityLabel(label)
        #else
        text.accessibilityLabel = label
        #endif
      }
    } else if let code = item.view as? MarkdownNativeCodeBlock,
              case .codeBlock(_, let language, let source, let highlight) = block {
      code.update(language: language ?? "", code: source, config: config, controller: controller, openURL: openURL, highlight: measurementOnly ? nil : highlight)
    } else if let table = item.view as? MarkdownNativeTableBlock,
              case .table(_, let headers, let rows, let layout) = block {
      table.update(headers: headers, rows: rows, config: config, controller: controller, openURL: openURL, layout: layout)
    } else if let list = item.view as? MarkdownNativeListBlock {
      switch block {
      case .orderedList(_, let items):
        list.update(items: items, ordered: true, nestedLevel: 0, owner: owner, config: config, controller: controller, openURL: openURL)
      case .unorderedList(_, let items, let level):
        list.update(items: items, ordered: false, nestedLevel: level, owner: owner, config: config, controller: controller, openURL: openURL)
      default: break
      }
    } else if let quote = item.view as? MarkdownNativeQuoteBlock,
              case .blockQuote(_, let item) = block {
      quote.update(item.quoteType, config: config, controller: controller, openURL: openURL)
    } else if let host = item.host {
      host.rootView = AnyView(SingleBlockView(renderable: block)
        .environment(\.markdownConfig, config)
        .environment(\.markdownController, controller)
        .environment(\.openURL, openURL)
        .environment(\.colorScheme, config.colorScheme)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self, weak item] size in
          guard let self, let item, !self.isMeasuring, let measured = item.size,
                abs(size.height - measured.height) > 0.5 else { return }
          item.size = nil
          self.invalidateMeasuredHeight()
        })
    }

    if !measurementOnly, let native = item.view as? MarkdownNativeBlock {
      native.onSizeChange = { [weak self, weak item] in
        guard let self, let item else { return }
        item.size = nil
        self.invalidateMeasuredHeight()
      }
    }
  }

  private func measurementItem(for item: Item) -> Item {
    if item.view != nil { return item }
    let key = item.renderable.nativeKind
    if let measurement = measurementItems[key] {
      measurement.renderable = item.renderable
      configure(measurement, measurementOnly: true)
      return measurement
    }
    let measurement = Item(item.renderable)
    makeView(for: measurement)
    configure(measurement, measurementOnly: true)
    measurementItems[key] = measurement
    return measurement
  }

  func setFirstParagraphAccessibilityLabel(_ label: String) {
    guard let item = items.first else { return }
    item.accessibilityLabel = label
    guard let text = item.view as? MarkdownLayoutParagraph else { return }
    #if canImport(AppKit)
    text.setAccessibilityLabel(label)
    #else
    text.accessibilityLabel = label
    #endif
  }

  private func remove(_ item: Item) {
    #if canImport(UIKit)
    item.host?.willMove(toParent: nil)
    #endif
    item.view?.removeFromSuperview()
    item.host?.removeFromParent()
  }

  private func invalidateMeasuredHeight() {
    if measuredWidth > 0 { measuredHeight = measure(width: measuredWidth) }
    invalidateIntrinsicContentSize()
    onSizeChange?()
    invalidateContentLayout()
  }

  func measure(width: CGFloat) -> CGFloat {
    guard width > 0, width.isFinite, let config else { return 0 }
    isMeasuring = true
    defer { isMeasuring = false }
    if width != measuredWidth {
      for item in items { item.size = nil }
      measuredWidth = width
    }
    var height: CGFloat = 0
    for item in items {
      if item.size == nil {
        let measured = measurementItem(for: item)
        if let text = measured.view as? MarkdownLayoutParagraph {
          // Preserve the trailing Spacer in the original paragraph and heading rows.
          let textWidth = max(1, width - 8)
          #if os(visionOS)
          let textSize = text.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
          #else
          let textSize = text.measureSize(fittingWidth: textWidth)
          #endif
          item.size = CGSize(width: textWidth, height: textSize.height)
        } else if let native = measured.view as? MarkdownNativeBlock {
          item.size = native.measure(width: width)
        } else if let host = measured.host {
          item.size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        }
      }
      height += (item.size?.height ?? 0) + config.blockSpacing
    }
    measuredHeight = max(0, height - (items.isEmpty ? 0 : config.blockSpacing))
    return measuredHeight
  }

  override var observesViewport: Bool { owner?.document === self }
  override func viewportDidChange() { placeBlocks() }

  private var mountingViewport: CGRect {
    guard owner?.document === self else { return bounds }
    guard window != nil else { return .zero }
    return visibleContentRect
  }

  private func placeBlocks() {
    guard let config, bounds.width > 0 else { return }
    _ = measure(width: bounds.width)
    let viewport = mountingViewport
    var y: CGFloat = 0
    for item in items {
      let height = item.size?.height ?? 0
      let width = item.renderable.nativeParagraph ? min(bounds.width, item.size?.width ?? bounds.width) : bounds.width
      let frame = CGRect(x: 0, y: y, width: width, height: height)
      // Exact measured geometry remains in the document even when its native
      // controls are outside the viewport. Mounting does not change scroll extent.
      if item.host != nil || viewport.intersects(frame) || ownsFirstResponder(item.view) {
        if item.view == nil {
          makeView(for: item)
          configure(item)
        }
        if let view = item.view {
          if view.frame != frame { view.frame = frame }
          if view.superview !== self { addSubview(view) }
        }
      } else if item.view?.superview === self {
        item.view?.removeFromSuperview()
      }
      y += height + config.blockSpacing
    }
  }

  private func ownsFirstResponder(_ view: MarkdownLayoutView?) -> Bool {
    guard let view else { return false }
    #if canImport(AppKit)
    guard let responder = window?.firstResponder as? NSView else { return false }
    return responder === view || responder.isDescendant(of: view)
    #else
    return view.isFirstResponder || view.subviews.contains { ownsFirstResponder($0) }
    #endif
  }
}

private extension MarkdownRenderable {
  var hasReusableMeasurement: Bool {
    switch self {
    case .paragraph, .heading, .codeBlock, .table, .blockQuote: true
    default: false
    }
  }

  var nativeKind: Int {
    switch self {
    case .paragraph: 0
    case .heading: 1
    case .codeBlock: 2
    case .table: 3
    case .orderedList, .unorderedList: 4
    case .blockQuote: 5
    default: 6
    }
  }
  var nativeParagraph: Bool {
    switch self {
    case .paragraph, .heading: true
    default: false
    }
  }
}
