//
//  PreferenceKeys.swift
//  Mallow
//
//  Created by Lion Wu on 2025/9/21.
//

import SwiftUI

struct ChatScrollMeasurements: Equatable {
    var contentHeight: CGFloat?
    var initialRenderGeneration: UInt64?
    var viewportHeight: CGFloat?
    var bottomAnchorMaxY: CGFloat?
    var historyAnchor: ChatHistoryAnchor?
    var searchTarget: ChatSearchTargetGeometry?
}

struct ChatScrollMeasurementsKey: PreferenceKey {
    static var defaultValue: ChatScrollMeasurements { ChatScrollMeasurements() }

    static func reduce(value: inout ChatScrollMeasurements, nextValue: () -> ChatScrollMeasurements) {
        let next = nextValue()
        if let height = next.contentHeight { value.contentHeight = height }
        if let generation = next.initialRenderGeneration { value.initialRenderGeneration = generation }
        if let height = next.viewportHeight { value.viewportHeight = height }
        if let anchor = next.bottomAnchorMaxY { value.bottomAnchorMaxY = anchor }
        if let anchor = next.historyAnchor { value.historyAnchor = anchor }
        if let target = next.searchTarget { value.searchTarget = target }
    }
}

struct EditingBannerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct FloatingNoticeStackHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
