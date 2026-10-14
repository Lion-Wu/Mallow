//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import SwiftUI

struct BlockView: View {

  let renderables: [MarkdownRenderable]

  init(renderables: [MarkdownRenderable]) {
    self.renderables = renderables
  }

  var body: some View {
    NativeMarkdownDocument(renderables: renderables)
  }
}

struct SingleBlockView: View, Equatable {

  @Environment(\.markdownConfig) var config: MarkdownRenderConfig

  nonisolated let renderable: MarkdownRenderable

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.renderable == rhs.renderable
  }

  init(renderable: MarkdownRenderable) {
    self.renderable = renderable
  }

  var body: some View {
    Group {
      switch renderable {
      case .heading, .paragraph, .orderedList, .unorderedList, .codeBlock, .table, .blockQuote:
        NativeMarkdownDocument(renderables: [renderable])
      case .latex(_, let latexString):
        ScrollView(.horizontal) {
          HStack(spacing: 0) {
            BlockMathView(
              latex: latexString,
              color: config.paragraphStyle.textColor,
              colorScheme: config.colorScheme
            )
            Spacer()
          }
        }.scrollIndicators(.hidden)
      case .thematicBreak:
        ThematicBreakView()
      case .image(let id, let data):
        BlockImageView(data: data)
          .id(id)
      }
    }
  }
}
