#if os(iOS) || os(macOS)

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
@preconcurrency import AVFoundation

#if os(iOS)
struct VoiceVisionCameraPreview: UIViewRepresentable {
    let controller: VoiceVisionCameraController

    func makeUIView(context: Context) -> VoiceVisionPreviewView {
        let view = VoiceVisionPreviewView()
        view.connect(controller: controller)
        return view
    }

    func updateUIView(_ uiView: VoiceVisionPreviewView, context: Context) {
        uiView.controller?.refreshPreviewRotation()
    }
}

final class VoiceVisionPreviewView: UIView {
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private(set) weak var controller: VoiceVisionCameraController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        controller?.refreshPreviewRotation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        controller?.connectPreview(previewLayer)
    }

    func connect(controller: VoiceVisionCameraController) {
        self.controller = controller
        controller.connectPreview(previewLayer)
    }

    private func configure() {
        backgroundColor = .black
        layer.addSublayer(previewLayer)
        previewLayer.videoGravity = .resizeAspectFill
    }
}
#elseif os(macOS)
struct VoiceVisionCameraPreview: NSViewRepresentable {
    let controller: VoiceVisionCameraController

    func makeNSView(context: Context) -> VoiceVisionPreviewView {
        let view = VoiceVisionPreviewView()
        view.connect(controller: controller)
        return view
    }

    func updateNSView(_ nsView: VoiceVisionPreviewView, context: Context) {
        nsView.controller?.refreshPreviewRotation()
    }
}

final class VoiceVisionPreviewView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private(set) weak var controller: VoiceVisionCameraController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        controller?.refreshPreviewRotation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        controller?.connectPreview(previewLayer)
    }

    func connect(controller: VoiceVisionCameraController) {
        self.controller = controller
        controller.connectPreview(previewLayer)
    }

    private func configure() {
        wantsLayer = true
        layer = previewLayer
        previewLayer.videoGravity = .resizeAspectFill
    }
}
#endif

#endif
