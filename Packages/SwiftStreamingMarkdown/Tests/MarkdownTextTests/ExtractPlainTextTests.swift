//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
@testable import SwiftStreamingMarkdown
import XCTest

final class ExtractPlainTextTests: XCTestCase {

  func testExtractPlainTextFromMixedFormatting() async {
    let markdown = "This has **bold**, *italic* text"
    let result = await markdown.markdownToPlainText()
    XCTAssertEqual(result, "This has bold, italic text")
  }

  func testExtractPlainTextFromNestedBlockQuoteWithCitations() async {
    let markdown = """
    > Level 1 with [Microsoft](http://example.com?citationMarker=9F742443)
    > > Level 2 with [9F742443](http://example.com?citationMarker=9F742443&citationTitle=Google&citationA11yValue=Google)
    """
    let result = await markdown.markdownToPlainText()
    XCTAssertTrue(result.contains("Microsoft"), "Nested BlockQuote should handle regular citations")
    XCTAssertTrue(result.contains("Google"), "Nested BlockQuote should handle attachment citations")
    XCTAssertFalse(result.contains("9F742443"), "Should not show UUID in plain text")
  }
}
