//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import Markdown
import SwiftUI
import Equatable

/// A source of incremental Markdown text for `StreamedMarkdownView`.
///
/// Each value yielded by `text` is a *complete snapshot* of the Markdown
/// source so far (a growing prefix), not an incremental delta. The view
/// re-parses each snapshot and updates the rendered output.
public protocol StreamedMarkdownSource {
  @MainActor
  var text: AsyncStream<String> { get }
}

/// A SwiftUI view that incrementally parses and renders streamed Markdown.
///
/// Provide a `StreamedMarkdownSource` whose `text` async sequence yields
/// progressively larger snapshots of the Markdown source; the view re-parses
/// on each emission and refreshes the rendered output.
@Equatable
public struct StreamedMarkdownView: View {

  private let config: MarkdownRenderConfig
  @StateObject private var controller: StreamedMarkdownController

  /// Create a `StreamedMarkdownView`.
  /// - Parameters:
  ///   - source: The streamed Markdown source. Each emission must be the
  ///     complete Markdown source so far, not an incremental delta.
  ///   - config: Render configuration. Defaults to `.default`.
  ///   - listener: Optional listener that receives render and interaction events.
  ///   - onFirstRender: Called once after the first source snapshot has been
  ///     parsed and published for display.
  public init(
    source: StreamedMarkdownSource,
    config: MarkdownRenderConfig = .default,
    listener: MarkdownListener? = nil,
    onFirstRender: @escaping @MainActor () -> Void = {}
  ) {
    self.config = config
    _controller = StateObject(
      wrappedValue: StreamedMarkdownController(
        source: source,
        listener: listener,
        onFirstRender: onFirstRender
      )
    )
  }

  public var body: some View {
    DocumentView(
      renderableDocument: controller.markdownToRender,
      config: config,
      listener: controller.listener
    )
    .task(id: config.conversionKey) {
      await controller.render(config: config)
    }
  }
}

@MainActor
final class StreamedMarkdownController: ObservableObject {

  @Published var markdownToRender: RenderableDocument = .empty
  let listener: MarkdownListener?

  private let source: StreamedMarkdownSource
  private let onFirstRender: @MainActor () -> Void
  private var hasRenderedFirstSnapshot = false

  init(
    source: StreamedMarkdownSource,
    listener: MarkdownListener? = nil,
    onFirstRender: @escaping @MainActor () -> Void = {}
  ) {
    self.source = source
    self.listener = listener
    self.onFirstRender = onFirstRender
  }

  func render(config: MarkdownRenderConfig) async {
    let parser = StreamingMarkdownParser()
    for await text in source.text {
      guard !Task.isCancelled else { return }
      let renderable = await parser.parse(text: text, config: config)
      guard !Task.isCancelled else { return }
      if markdownToRender != renderable {
        markdownToRender = renderable
      }
      if !hasRenderedFirstSnapshot {
        hasRenderedFirstSnapshot = true
        onFirstRender()
      }
    }
  }
}

private struct MarkdownConversionKey: Hashable {
  let colorScheme: ColorScheme
  let blockQuoteStyle: MarkdownRenderConfig.MarkdownTextStyle
  let headingStyle: MarkdownRenderConfig.MarkdownHeadingTextStyle
  let orderedListStyle: MarkdownRenderConfig.MarkdownTextStyle
  let paragraphStyle: MarkdownRenderConfig.MarkdownTextStyle
  let tableStyle: MarkdownRenderConfig.MarkdownTableTextStyle
  let inlineStyle: MarkdownRenderConfig.MarkdownInlineTextStyle
  let citationConfig: MarkdownRenderConfig.CitationConfig
  let searchHighlightQuery: String?
  let imageConfig: ImageConfig
  let codeBlockConfig: CodeBlockConfig
}

private extension MarkdownRenderConfig {
  var conversionKey: MarkdownConversionKey {
    MarkdownConversionKey(
      colorScheme: colorScheme,
      blockQuoteStyle: blockQuoteStyle,
      headingStyle: headingStyle,
      orderedListStyle: orderedListStyle,
      paragraphStyle: paragraphStyle,
      tableStyle: tableStyle,
      inlineStyle: inlineStyle,
      citationConfig: citationConfig,
      searchHighlightQuery: searchHighlightQuery,
      imageConfig: imageConfig,
      codeBlockConfig: codeBlockConfig
    )
  }
}

private actor StreamingMarkdownParser {
  private var previousBlocks: [any Markup] = []
  private var previousRenderables: [MarkdownRenderable] = []

  func parse(text: String, config: MarkdownRenderConfig) async -> RenderableDocument {
    // Parse the complete source so later reference definitions can update earlier
    // links. Reuse conversion only when the resolved block is unchanged.
    let result = await MarkdownParserImpl().parse(
      text: text,
      option: .init(speculativeRewrite: false, imageSupport: config.imageConfig.enabled)
    )
    var blocks: [any Markup] = []
    var renderables: [MarkdownRenderable] = []
    for block in result.document.children {
      guard let convertible = block as? any BlockConvertible else { continue }
      let index = blocks.count
      if previousBlocks.indices.contains(index),
         previousBlocks[index].id == block.id,
         previousBlocks[index].hasSameStructure(as: block) {
        renderables.append(previousRenderables[index])
      } else {
        let converted = convertible.convert(attributeContainer: NSAttributeContainer(), config: config)
        renderables.append(await converted.preparingCodeHighlights(config: config))
      }
      blocks.append(block)
    }
    previousBlocks = blocks
    previousRenderables = renderables
    return RenderableDocument(renderables: renderables)
  }
}
