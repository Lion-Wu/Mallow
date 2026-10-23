//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Markdown
@testable import SwiftStreamingMarkdown
import XCTest

final class PartialMarkdownRewriterTests: XCTestCase {

  let partialEmphasisScanner = PartialEmphasisScanner()

  func test_partial_rewrite_code_block_should_not_rewrite() {
    let text = """
    This is a paragraph

    ```java
    String a = "abc"
    String b = "**"
    ```
    """
    let document = Document(parsing: text)
    let targetNode = partialEmphasisScanner.scan(document: document)
    XCTAssertNil(targetNode)
  }
}
