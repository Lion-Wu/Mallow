//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

@testable import SwiftStreamingMarkdown
import XCTest

final class TaskListTests: XCTestCase {

  private let parser = MarkdownParserImpl()

  func test_taskList_carriesCheckboxStates() async {
    let text = """
    - [x] completed task
    - [ ] open task
    - regular item
    """
    let document = await parser.parse(text: text)
    let renderables = document.convert(with: .default)

    guard case .unorderedList(_, let items, _) = renderables.first else {
      return XCTFail("Expected the parsed document to start with an unordered list")
    }
    XCTAssertEqual(items.count, 3)
    XCTAssertEqual(items[0].checkbox, .checked)
    XCTAssertEqual(items[1].checkbox, .unchecked)
    XCTAssertNil(items[2].checkbox)
  }
}
