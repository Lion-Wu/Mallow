//
//  ChatImageAttachmentStrip.swift
//  Mallow
//
//  Created by Codex on 2026/6/13.
//

import ImageIO
import SwiftUI

#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ChatImageAttachmentStrip: View {
    let attachments: [ChatImageAttachment]
    let removable: Bool
    let maxItemSize: CGFloat
    let onPreview: (ChatImageAttachment) -> Void
    let onRemove: ((ChatImageAttachment) -> Void)?
    let horizontalAlignment: HorizontalAlignment

    init(
        attachments: [ChatImageAttachment],
        removable: Bool,
        maxItemSize: CGFloat,
        onPreview: @escaping (ChatImageAttachment) -> Void,
        onRemove: ((ChatImageAttachment) -> Void)?,
        horizontalAlignment: HorizontalAlignment = .leading
    ) {
        self.attachments = attachments
        self.removable = removable
        self.maxItemSize = maxItemSize
        self.onPreview = onPreview
        self.onRemove = onRemove
        self.horizontalAlignment = horizontalAlignment
    }

    private var stripAlignment: Alignment {
        horizontalAlignment == .trailing ? .trailing : .leading
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        ChatImageAttachmentItem(
                            attachment: attachment,
                            removable: removable,
                            maxItemSize: maxItemSize,
                            onPreview: onPreview,
                            onRemove: onRemove
                        )
                    }
                }
                .frame(minWidth: proxy.size.width, alignment: stripAlignment)
                .padding(.vertical, 2)
            }
        }
        .frame(height: maxItemSize + 4)
    }
}

private struct ChatImageAttachmentItem: View {
    let attachment: ChatImageAttachment
    let removable: Bool
    let maxItemSize: CGFloat
    let onPreview: (ChatImageAttachment) -> Void
    let onRemove: ((ChatImageAttachment) -> Void)?

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: CGImage?

    private var removeTapSize: CGFloat {
        #if os(iOS) || os(tvOS)
        return 32
        #else
        return 28
        #endif
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                onPreview(attachment)
            } label: {
                Group {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: displayScale)
                            .resizable()
                            .scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.secondary.opacity(0.15))
                            .overlay(
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            )
                    }
                }
                .frame(width: maxItemSize, height: maxItemSize)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
                )
            }
            .buttonStyle(.plain)

            if removable, let onRemove {
                Button {
                    onRemove(attachment)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.65))
                        .frame(width: removeTapSize, height: removeTapSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("CHAT_ACTION_REMOVE_IMAGE"))
            }
        }
        .task(id: "\(attachment.digest)-\(maxItemSize)-\(displayScale)") {
            let pixels = max(1, Int((maxItemSize * displayScale).rounded(.up)))
            let worker = Task.detached(priority: .utility) {
                try ChatImageThumbnailCache.shared.image(for: attachment, maxPixelSize: pixels)
            }
            do {
                let image = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                thumbnail = image
            } catch is CancellationError {
            } catch { thumbnail = nil }
        }
    }
}

private final class ChatImageThumbnailCache: @unchecked Sendable {
    static let shared = ChatImageThumbnailCache()
    private let cache = NSCache<NSString, CGImage>()

    private init() {
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 256
    }

    func image(for attachment: ChatImageAttachment, maxPixelSize: Int) throws -> CGImage? {
        try Task.checkCancellation()
        let key = "\(attachment.digest)-\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let data = try attachment.loadData()
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        try Task.checkCancellation()
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}
