//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import Markdown
import SwiftUI

extension Markdown.Table: BlockConvertible {

  func convert(attributeContainer: NSAttributeContainer, config: MarkdownRenderConfig) -> MarkdownRenderable {
    var bodyContainer = attributeContainer
    var headerContainer = attributeContainer
    bodyContainer[.font] = config.tableStyle.textFonts.normal
    bodyContainer[.typography] = config.tableStyle.textFonts
    headerContainer[.font] = config.tableStyle.textFonts.bold ?? config.tableStyle.textFonts.normal
    headerContainer[.typography] = config.tableStyle.textFonts
    let headerCells = self
      .head
      .children
      .compactMap { $0 as? Cell }
      .map { $0.convert(attributeContainer: headerContainer, config: config) }
    let rows = self
      .body
      .children
      .compactMap { $0 as? Row }
      // It may never happen but we filter out rows with wrong # of columns
      .filter { $0.childCount == headerCells.count }
      .map { row in
        let cells = row.children.compactMap { $0 as? Cell }
        return cells.map { $0.convert(attributeContainer: bodyContainer, config: config) }
      }
    let styledHeaders = headerCells.map { markdownTableCellContent($0, isHeader: true, config: config) }
    let styledRows = rows.map { row in row.map { markdownTableCellContent($0, isHeader: false, config: config) } }
    let layout = MarkdownTableLayout(precomputing: [styledHeaders] + styledRows,
                                     columnMaxWidths: Array(repeating: 200, count: styledHeaders.count))
    return .table(id: self.id, headers: styledHeaders, rows: styledRows, layout: layout)
  }
}
