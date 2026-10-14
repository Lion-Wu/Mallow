// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License. See LICENSE in the project root for license information.

import SwiftUI
#if canImport(AppKit)
import AppKit
typealias MarkdownLayoutView = NSView
typealias MarkdownLayoutParagraph = ParagraphNSView
#else
import UIKit
typealias MarkdownLayoutView = UIView
typealias MarkdownLayoutParagraph = ParagraphUIView
#endif

final class MarkdownTableLayoutView: MarkdownViewportView {
  private var cells: [[NSMutableAttributedString]] = []
  private var contents: [NSMutableAttributedString] = []
  private var columnMaxWidths: [CGFloat] = []
  private var paragraphs: [Int: MarkdownLayoutParagraph] = [:]
  private var reusableParagraphs: [MarkdownLayoutParagraph] = []
  private var columnWidths: [CGFloat] = []
  private var rowHeights: [CGFloat] = []
  private var rowOrigins: [CGFloat] = []
  private var config: MarkdownRenderConfig?
  private weak var controller: MarkdownController?
  private var openURL: OpenURLAction?
  private let headerLayer = CALayer()
  private let borderLayer = CAShapeLayer()
  private(set) var measuredSize = CGSize.zero

  override init(frame: CGRect) {
    super.init(frame: frame)
    #if canImport(AppKit)
    wantsLayer = true
    layer?.addSublayer(headerLayer)
    layer?.addSublayer(borderLayer)
    #else
    layer.addSublayer(headerLayer)
    layer.addSublayer(borderLayer)
    #endif
    borderLayer.fillColor = nil
    borderLayer.lineWidth = 1
  }
  required init?(coder: NSCoder) { nil }

  #if canImport(AppKit)
  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize { measuredSize }
  #else
  override var intrinsicContentSize: CGSize { measuredSize }
  #endif
  override func viewportDidChange() { placeCells() }

  func setTextAnimationEnabled(_ enabled: Bool) {
    config = config?.withShouldAnimateText(value: enabled)
  }

  func update(cells: [[NSMutableAttributedString]], columnMaxWidths: [CGFloat],
              config: MarkdownRenderConfig, controller: MarkdownController?, openURL: OpenURLAction,
              layout: MarkdownTableLayout? = nil) {
    self.config = config
    self.controller = controller
    self.openURL = openURL
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    headerLayer.backgroundColor = MDColor(config.tableStyle.headerBackgroundColor).cgColor
    borderLayer.strokeColor = MDColor(config.tableStyle.borderColor).cgColor
    CATransaction.commit()
    let changed = self.cells != cells || self.columnMaxWidths != columnMaxWidths
    self.cells = cells
    self.contents = cells.flatMap { $0 }
    self.columnMaxWidths = columnMaxWidths
    for (index, paragraph) in paragraphs where contents.indices.contains(index) {
      configure(paragraph, at: index)
    }
    guard changed else { return }
    let geometry = layout ?? MarkdownTableLayout(cells: cells, columnMaxWidths: columnMaxWidths)
    columnWidths = geometry.columnWidths
    rowHeights = geometry.rowHeights
    rowOrigins = geometry.rowOrigins
    measuredSize = geometry.size
    updateGridLines()
    invalidateIntrinsicContentSize()
    invalidateContentLayout()
  }

  private func configure(_ paragraph: MarkdownLayoutParagraph, at index: Int) {
    guard let config, let openURL else { return }
    paragraph.onUrlTap = openURL.callAsFunction(_:)
    paragraph.setTextContextMenu(config.resolvedTextContextMenu)
    paragraph.setMarkdownController(controller)
    paragraph.setParagraphContents(contents[index], animatedByWord: paragraph.window != nil && config.shouldAnimateText)
    let columns = columnMaxWidths.count
    guard columns > 0 else { return }
    let label = String.itemPositionInTable(rowIndex: index / columns + 1, totalRow: cells.count,
                                          columnIndex: index % columns + 1, totalColumn: columns)
    #if canImport(AppKit)
    paragraph.setAccessibilityHelp(label)
    #else
    paragraph.accessibilityHint = label
    #endif
  }

  private func firstRow(endingAfter y: CGFloat) -> Int {
    var low = 0, high = rowHeights.count
    while low < high {
      let middle = (low + high) / 2
      if rowOrigins[middle] + rowHeights[middle] <= y { low = middle + 1 } else { high = middle }
    }
    return low
  }

  private func placeCells() {
    guard !columnWidths.isEmpty else { return }
    let viewport = visibleContentRect
    let first = firstRow(endingAfter: viewport.minY)
    var frames: [Int: CGRect] = [:]
    if !viewport.isEmpty, !viewport.isNull {
      for row in first..<rowHeights.count {
        let y = rowOrigins[row]
        if y >= viewport.maxY { break }
        var x: CGFloat = 0
        for (col, width) in columnWidths.enumerated() {
          let index = row * columnWidths.count + col
          let frame = CGRect(x: x + 12, y: y + 12, width: max(1, width - 32), height: rowHeights[row] - 24)
          if contents.indices.contains(index), frame.intersects(viewport) { frames[index] = frame }
          x += width
        }
      }
    }
    for index in Array(paragraphs.keys) where frames[index] == nil {
      guard let paragraph = paragraphs[index] else { continue }
      #if canImport(AppKit)
      if window?.firstResponder === paragraph { continue }
      #else
      if paragraph.isFirstResponder { continue }
      #endif
      paragraphs.removeValue(forKey: index)
      paragraph.removeFromSuperview()
      reusableParagraphs.append(paragraph)
    }
    for (index, frame) in frames {
      let paragraph: MarkdownLayoutParagraph
      if let existing = paragraphs[index] {
        paragraph = existing
      } else {
        paragraph = reusableParagraphs.popLast() ?? MarkdownLayoutParagraph()
        #if canImport(AppKit)
        paragraph.textContainerInset = .zero
        #endif
        configure(paragraph, at: index)
        paragraphs[index] = paragraph
      }
      if paragraph.frame != frame { paragraph.frame = frame }
      if paragraph.superview !== self { addSubview(paragraph) }
    }
    let accessibleCells = paragraphs.keys.sorted().compactMap { paragraphs[$0] }
    #if canImport(AppKit)
    setAccessibilityChildren(accessibleCells)
    #else
    accessibilityElements = accessibleCells
    #endif
  }

  private func updateGridLines() {
    let path = CGMutablePath()
    var x: CGFloat = 0
    for width in columnWidths.dropLast() {
      x += width
      path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: measuredSize.height))
    }
    for y in rowOrigins.dropFirst() {
      path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: measuredSize.width, y: y))
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    headerLayer.frame = CGRect(x: 0, y: 0, width: measuredSize.width, height: rowHeights.first ?? 0)
    borderLayer.frame = CGRect(origin: .zero, size: measuredSize)
    borderLayer.path = path
    CATransaction.commit()
  }
}

/// A scroll owner uses this to invalidate native viewports after its geometry
/// changes, without publishing a new SwiftUI value to every Markdown renderer.
@MainActor
public final class MarkdownViewportCoordinator {
  private let views = NSHashTable<MarkdownViewportView>.weakObjects()

  public init() {}

  public func invalidateViewport() {
    for view in views.allObjects { view.invalidateViewportLayout() }
  }

  fileprivate func register(_ view: MarkdownViewportView) { views.add(view) }
  fileprivate func unregister(_ view: MarkdownViewportView) { views.remove(view) }
}

private struct MarkdownViewportCoordinatorKey: EnvironmentKey {
  static let defaultValue: MarkdownViewportCoordinator? = nil
}

public extension EnvironmentValues {
  var markdownViewportCoordinator: MarkdownViewportCoordinator? {
    get { self[MarkdownViewportCoordinatorKey.self] }
    set { self[MarkdownViewportCoordinatorKey.self] = newValue }
  }
}

/// Observes the native clipping ancestors, keeping visible controls independent
/// of the full document's exact measured extent.
class MarkdownViewportView: MarkdownLayoutView {
  var observesViewport: Bool { true }
  func viewportDidChange() {}
  private var lastNotifiedViewport: CGRect?
  private var lastLayoutSize: CGSize?
  private var contentNeedsLayout = true
  weak var viewportCoordinator: MarkdownViewportCoordinator? {
    didSet {
      guard oldValue !== viewportCoordinator else { return }
      oldValue?.unregister(self)
      if observesViewport { viewportCoordinator?.register(self) }
    }
  }

  func invalidateContentLayout() {
    contentNeedsLayout = true
    invalidateViewportLayout()
  }

  func invalidateViewportLayout() {
    // Do not dirty native ancestors for an unchanged offscreen document.
    // Reconciliation still runs during layout if its own geometry changes.
    guard contentNeedsLayout || lastLayoutSize != bounds.size
      || lastNotifiedViewport != visibleContentRect else { return }
    #if canImport(AppKit)
    needsLayout = true
    #else
    setNeedsLayout()
    #endif
  }

  private func reconcileViewport() {
    let viewport = visibleContentRect
    guard contentNeedsLayout || lastLayoutSize != bounds.size || lastNotifiedViewport != viewport else { return }
    contentNeedsLayout = false
    lastLayoutSize = bounds.size
    lastNotifiedViewport = viewport
    viewportDidChange()
  }

  private func inheritViewportCoordinator() {
    guard viewportCoordinator == nil else { return }
    var ancestor = superview
    while let view = ancestor {
      if let coordinator = (view as? MarkdownViewportView)?.viewportCoordinator {
        viewportCoordinator = coordinator
        return
      }
      ancestor = view.superview
    }
  }
  #if canImport(AppKit)
  private var viewportObservers: [NSObjectProtocol] = []
  #else
  private var viewportObservations: [NSKeyValueObservation] = []
  #endif

  isolated deinit {
    viewportCoordinator?.unregister(self)
    #if canImport(AppKit)
    for observer in viewportObservers { NotificationCenter.default.removeObserver(observer) }
    #endif
  }

  #if canImport(AppKit)
  override func layout() { super.layout(); reconcileViewport() }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    inheritViewportCoordinator()
    lastNotifiedViewport = nil
    for observer in viewportObservers { NotificationCenter.default.removeObserver(observer) }
    viewportObservers.removeAll()
    guard window != nil, observesViewport else { return }
    var ancestor = superview
    while let view = ancestor {
      if let clip = view as? NSClipView {
        viewportObservers.append(NotificationCenter.default.addObserver(
          forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.invalidateViewportLayout() }
        })
      }
      ancestor = view.superview
    }
    needsLayout = true
  }
  #else
  override func layoutSubviews() { super.layoutSubviews(); reconcileViewport() }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    inheritViewportCoordinator()
    lastNotifiedViewport = nil
    viewportObservations.removeAll()
    guard window != nil, observesViewport else { return }
    var ancestor = superview
    while let view = ancestor {
      if let scroll = view as? UIScrollView {
        viewportObservations.append(scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in
          MainActor.assumeIsolated { self?.invalidateViewportLayout() }
        })
      }
      ancestor = view.superview
    }
    setNeedsLayout()
  }
  #endif

  var visibleContentRect: CGRect {
    guard window != nil else { return .zero }
    #if canImport(AppKit)
    // AppKit's non-clipping default allows visibleRect outside this view.
    // Only the intersection can contain blocks belonging to this document.
    let viewport = visibleRect.intersection(bounds)
    #else
    var viewport = bounds
    var ancestor = superview
    while let view = ancestor {
      if view.clipsToBounds { viewport = viewport.intersection(convert(view.bounds, from: view)) }
      ancestor = view.superview
    }
    #endif
    guard !viewport.isEmpty, !viewport.isNull else { return .zero }
    return viewport.insetBy(dx: 0, dy: -viewport.height)
  }
}
