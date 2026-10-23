//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

@testable import SwiftStreamingMarkdown
import Markdown
import XCTest

@MainActor
final class ImageBlockRenderingTests: XCTestCase {

  private func url(_ string: String) -> URL {
    guard let url = URL(string: string) else {
      fatalError("Invalid test URL: \(string)")
    }
    return url
  }

  private func renderables(
    for text: String,
    imageSupport: Bool
  ) async -> [MarkdownRenderable] {
    await renderables(for: text, imageConfig: ImageConfig(enabled: imageSupport))
  }

  private func renderables(
    for text: String,
    imageConfig: ImageConfig
  ) async -> [MarkdownRenderable] {
    let parser = MarkdownParserImpl()
    let config = MarkdownRenderConfig(imageConfig: imageConfig)
    let document = await parser.parse(
      text: text,
      option: .init(speculativeRewrite: false, imageSupport: imageConfig.enabled)
    ).document
    return await RenderableDocument(document: document, config: config).renderables
  }

  func test_standalone_image_renders_as_paragraph_when_disabled() async {
    let renderables = await renderables(
      for: "![alt](https://example.com/a.png)",
      imageSupport: false
    )

    XCTAssertEqual(renderables.count, 1)
    guard case .paragraph = renderables[0] else {
      return XCTFail("Expected a paragraph when image support is disabled")
    }
  }

  func test_image_data_precomputes_domain_eligibility_from_config() async {
    let config = ImageConfig(
      enabled: true,
      allowedImageTypes: [.remote(allowedDomains: ["allowed.example"])]
    )

    let allowed = await renderables(
      for: "![alt](https://allowed.example/a.png)",
      imageConfig: config
    )
    guard case .image(_, let allowedData) = allowed.first else {
      return XCTFail("Expected an image block for the allowed domain")
    }
    XCTAssertEqual(allowedData.source, .remote(url("https://allowed.example/a.png")))

    let blocked = await renderables(
      for: "![alt](https://blocked.example/a.png)",
      imageConfig: config
    )
    guard case .image(_, let blockedData) = blocked.first else {
      return XCTFail("Expected an image block for the blocked domain")
    }
    XCTAssertNil(blockedData.source)
  }

  func test_image_mixed_with_text_is_split_into_blocks_when_enabled() async {
    let renderables = await renderables(
      for: "before ![alt](https://example.com/a.png) after",
      imageSupport: true
    )

    XCTAssertEqual(renderables.count, 3)
    guard case .paragraph = renderables[0] else {
      return XCTFail("Expected leading text paragraph")
    }
    guard case .image = renderables[1] else {
      return XCTFail("Expected the middle block to be an image")
    }
    guard case .paragraph = renderables[2] else {
      return XCTFail("Expected trailing text paragraph")
    }
  }
}
