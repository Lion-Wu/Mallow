//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation

enum ParagraphAnimationConstants {
  static let fadeInDuration: CFTimeInterval = 0.5
  static let delayBetweenWordsRatio: Double = 0.1
}

struct FadeAnimationData {
  let startTime: CFTimeInterval
  let duration: CFTimeInterval
  let range: NSRange
}

/// Cubic Bezier ease-out curve shared between iOS and macOS paragraph views.
func paragraphEaseOut(_ t: CGFloat) -> CGFloat {
  let c2: CGFloat = 0.1
  let c4: CGFloat = 1.0

  let t2 = t * t
  let t3 = t2 * t
  let mt = 1 - t
  let mt2 = mt * mt

  return 3 * mt2 * t * c2 + 3 * mt * t2 * c4 + t3
}

#if canImport(AppKit) || os(iOS)
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import QuartzCore

/// Fade changes drawing opacity, not glyph colors or text layout. Keeping the
/// original colors avoids thousands of distinct color resources in a display
/// list when one streaming paragraph contains a large number of words.
final class ParagraphFadeLayoutManager: NSLayoutManager {
  var animations: () -> [FadeAnimationData] = { [] }

  struct SyntaxColorSpan {
    let range: NSRange
    let color: MDColor
  }
  var selectedCharacterRange: () -> NSRange = { NSRange(location: NSNotFound, length: 0) }
  private var syntaxColorSpans: [SyntaxColorSpan] = []
  private var drawingSyntaxColor: MDColor?

  func setSyntaxColors(_ spans: [SyntaxColorSpan]) {
    syntaxColorSpans = spans
    invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0))
  }

  override func showCGGlyphs(_ glyphs: UnsafePointer<CGGlyph>, positions: UnsafePointer<CGPoint>,
                            count glyphCount: Int, font: MDFont, textMatrix: CGAffineTransform,
                            attributes: [NSAttributedString.Key: Any], in context: CGContext) {
    context.saveGState()
    if let drawingSyntaxColor { context.setFillColor(drawingSyntaxColor.cgColor) }
    super.showCGGlyphs(glyphs, positions: positions, count: glyphCount, font: font,
                       textMatrix: textMatrix, attributes: attributes, in: context)
    context.restoreGState()
  }

  private func drawSyntaxGlyphs(_ visibleGlyphs: NSRange, at origin: CGPoint) {
    let visibleCharacters = characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
    let selected = selectedCharacterRange()
    let selectedGlyphs: NSRange
    if selected.location != NSNotFound, selected.length > 0,
       NSMaxRange(selected) <= (textStorage?.length ?? 0) {
      selectedGlyphs = glyphRange(forCharacterRange: selected, actualCharacterRange: nil)
    } else {
      selectedGlyphs = NSRange(location: 0, length: 0)
    }
    defer { drawingSyntaxColor = nil }

    func paint(_ range: NSRange, color: MDColor?) {
      guard range.length > 0 else { return }
      drawingSyntaxColor = color
      super.drawGlyphs(forGlyphRange: range, at: origin)
    }
    func draw(_ range: NSRange, color: MDColor?) {
      let selection = NSIntersectionRange(range, selectedGlyphs)
      guard selection.length > 0 else { paint(range, color: color); return }
      paint(NSRange(location: range.location, length: selection.location - range.location), color: color)
      // Selection foreground remains owned by the native text view.
      paint(selection, color: nil)
      paint(NSRange(location: NSMaxRange(selection), length: NSMaxRange(range) - NSMaxRange(selection)), color: color)
    }

    var lower = 0, upper = syntaxColorSpans.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if NSMaxRange(syntaxColorSpans[middle].range) <= visibleCharacters.location { lower = middle + 1 }
      else { upper = middle }
    }
    var cursor = visibleGlyphs.location
    let end = NSMaxRange(visibleGlyphs)
    for index in lower..<syntaxColorSpans.count {
      let span = syntaxColorSpans[index]
      if span.range.location >= NSMaxRange(visibleCharacters) { break }
      let glyphs = glyphRange(forCharacterRange: span.range, actualCharacterRange: nil)
      let start = max(cursor, glyphs.location), stop = min(end, NSMaxRange(glyphs))
      guard start < stop else { continue }
      draw(NSRange(location: cursor, length: start - cursor), color: nil)
      draw(NSRange(location: start, length: stop - start), color: span.color)
      cursor = stop
    }
    draw(NSRange(location: cursor, length: end - cursor), color: nil)
  }

  override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
    if !syntaxColorSpans.isEmpty {
      drawSyntaxGlyphs(glyphsToShow, at: origin)
      return
    }
    let active = animations()
    #if canImport(AppKit)
    let drawingContext = NSGraphicsContext.current?.cgContext
    #else
    let drawingContext = UIGraphicsGetCurrentContext()
    #endif
    guard !active.isEmpty, let context = drawingContext else {
      super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
      return
    }

    let now = CACurrentMediaTime()
    let characterCount = textStorage?.length ?? 0
    let visibleCharacters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    // Animation ranges follow document order. Start at the first intersecting
    // range instead of walking every earlier word for each native drawing tile.
    var lower = 0
    var upper = active.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if NSMaxRange(active[middle].range) <= visibleCharacters.location {
        lower = middle + 1
      } else {
        upper = middle
      }
    }

    var cursor = glyphsToShow.location
    let end = NSMaxRange(glyphsToShow)
    var pendingRange = NSRange(location: cursor, length: 0)
    var pendingOpacity = 255

    func flush() {
      guard pendingRange.length > 0, pendingOpacity > 0 else { return }
      context.saveGState()
      context.setAlpha(CGFloat(pendingOpacity) / 255)
      super.drawGlyphs(forGlyphRange: pendingRange, at: origin)
      context.restoreGState()
    }

    func append(_ range: NSRange, opacity: Int) {
      guard range.length > 0 else { return }
      if opacity == pendingOpacity, NSMaxRange(pendingRange) == range.location {
        pendingRange.length += range.length
      } else {
        flush()
        pendingRange = range
        pendingOpacity = opacity
      }
    }

    for index in lower..<active.count {
      let animation = active[index]
      if animation.range.location >= NSMaxRange(visibleCharacters) { break }
      guard NSMaxRange(animation.range) <= characterCount,
            now - animation.startTime < animation.duration else { continue }
      let glyphs = glyphRange(forCharacterRange: animation.range, actualCharacterRange: nil)
      let start = max(cursor, glyphs.location)
      let stop = min(end, NSMaxRange(glyphs))
      guard start < stop else { continue }
      append(NSRange(location: cursor, length: start - cursor), opacity: 255)
      let progress = min(max((now - animation.startTime) / animation.duration, 0), 1)
      // Batch adjacent spans at 8-bit opacity precision. The fade curve and
      // timing are unchanged; sub-byte alpha differences do not need separate
      // native text drawing calls with repeated font and attribute setup.
      let opacity = Int((paragraphEaseOut(CGFloat(progress)) * 255).rounded())
      append(NSRange(location: start, length: stop - start), opacity: opacity)
      cursor = stop
      if cursor == end { break }
    }
    append(NSRange(location: cursor, length: end - cursor), opacity: 255)
    flush()
  }
}
#endif
