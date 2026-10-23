//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

@testable import SwiftStreamingMarkdown
import XCTest

final class ImageConfigTests: XCTestCase {

  private func remoteConfig(_ domains: [String] = [], enabled: Bool = true) -> ImageConfig {
    ImageConfig(enabled: enabled, allowedImageTypes: [.remote(allowedDomains: domains)])
  }

  func test_disabled_config_allows_nothing() {
    XCTAssertNil(remoteConfig(enabled: false).resolvedSource(for: "https://example.com/a.png"))
  }

  func test_enabled_without_allowed_types_allows_nothing() {
    XCTAssertNil(ImageConfig(enabled: true).resolvedSource(for: "https://example.com/a.png"))
  }

  func test_plain_http_is_never_allowed() {
    XCTAssertNil(remoteConfig().resolvedSource(for: "http://anything.example/a.png"))
  }

  func test_allowed_domain_matches_exact_and_subdomains() {
    let config = remoteConfig(["markdownguide.org"])
    XCTAssertNotNil(config.resolvedSource(for: "https://markdownguide.org/a.png"))
    XCTAssertNotNil(config.resolvedSource(for: "https://www.markdownguide.org/a.png"))
    XCTAssertNil(config.resolvedSource(for: "https://example.com/a.png"))
    XCTAssertNil(config.resolvedSource(for: "https://notmarkdownguide.org/a.png"))
  }

  func test_non_http_schemes_are_not_allowed() {
    XCTAssertNil(remoteConfig().resolvedSource(for: "file:///tmp/a.png"))
    XCTAssertNil(remoteConfig().resolvedSource(for: "ftp://example.com/a.png"))
  }
}
