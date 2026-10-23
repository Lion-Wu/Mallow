//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import Markdown
@testable import SwiftStreamingMarkdown
import UniformTypeIdentifiers
import XCTest
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

final class LaTexPreProcessorTests: XCTestCase {

  let preprocessor = LaTexPreProcessorImpl()

  func testInlineDollarMathLeavesLiteralDollarsAndCodeUntouched() {
    let input = #"Price: $5. Code: `$value`. Escaped: \$name. Block: $$x^2$$"#

    let expectation = """
    Price: $5. Code: `$value`. Escaped: \\$name. Block:
    ```blockmath
    x^2
    ```
    """

    XCTAssertEqual(preprocessor.process(input: input), expectation)
  }

  func testLatexInsideCodeSpansAndFencesRemainsLiteral() {
    let input = #"""
    Inline code: `\(not math\)` and `$stillNotMath$`.

    ```swift
    let inline = "$notMath$"
    let block = "$$notMath$$"
    let bracket = "\[notMath\]"
    ```

    Outside: $x + y$.
    """#
    let expectation = #"""
    Inline code: `\(not math\)` and `$stillNotMath$`.

    ```swift
    let inline = "$notMath$"
    let block = "$$notMath$$"
    let bracket = "\[notMath\]"
    ```

    Outside: `\(x + y\)`.
    """#

    XCTAssertEqual(preprocessor.process(input: input), expectation)
  }

  func testEmbeddedDisplayDelimitersBecomeMathBlocks() {
    let input = #"Before $$x^2 + y^2$$ after \[z = 1\] done."#
    let expectation = """
    Before
    ```blockmath
    x^2 + y^2
    ```
    after
    ```blockmath
    z = 1
    ```
    done.
    """

    XCTAssertEqual(preprocessor.process(input: input), expectation)
  }

  func testIncompleteStreamedDelimitersRemainUntouched() {
    let inputs = [
      "Inline $x + y",
      "Block $$x + y",
      #"Bracket \[x + y"#,
      #"Parenthesis \(x + y"#
    ]

    for input in inputs {
      XCTAssertEqual(preprocessor.process(input: input), input)
    }
  }

  func testBlockDollarDisabledStillProcessesOtherRules() {
    let input = """
    $$a = b + c$$
    \\[
    x = y + z
    \\]
    Inline \\(p + q\\) here.
    """
    let expected = """
    $$a = b + c$$
    ```blockmath
    x = y + z
    ```
    Inline `\\(p + q\\)` here.
    """
    let processed = preprocessor.process(
      input: input,
      matchingRules: [.inlineSlashBracket, .blockSlashBracket]
    )
    XCTAssertEqual(processed, expected)
  }

  @MainActor
  func testInlineLatexUsesDedicatedAttachmentContentType() async throws {
    let document = await MarkdownParserImpl().parse(
      text: "$x + y$",
      config: .default
    )
    let attributedString = try XCTUnwrap(document.attributedStrings.first)
    let attachment = try XCTUnwrap(
      attributedString.attribute(
        .attachment,
        at: 0,
        effectiveRange: nil
      ) as? NSTextAttachment
    )

    XCTAssertEqual(
      attachment.fileType,
      UTType.markdownLatex.identifier
    )
  }
}
