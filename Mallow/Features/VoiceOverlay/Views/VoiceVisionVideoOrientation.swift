#if os(iOS) || os(macOS)

import Foundation
import QuartzCore
@preconcurrency import AVFoundation

@MainActor
final class VoiceVisionVideoOrientation {
    var onCaptureRotationChange: ((CGFloat, String) -> Void)?

    private var device: AVCaptureDevice?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observations: [NSKeyValueObservation] = []

    nonisolated init() {}

    func setPreviewLayer(_ previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        guard let device else { return }
        let angle = startObserving(device: device)
        onCaptureRotationChange?(angle, device.uniqueID)
    }

    func setDevice(_ device: AVCaptureDevice) -> CGFloat {
        self.device = device
        // Called before the session commits its new input and starts delivering frames.
        return startObserving(device: device)
    }

    private func startObserving(device: AVCaptureDevice) -> CGFloat {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        coordinator = nil

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        self.coordinator = coordinator
        applyPreviewRotation()

        observations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: .new) { [weak self] coordinator, _ in
                MainActor.assumeIsolated {
                    guard self?.coordinator === coordinator else { return }
                    self?.applyPreviewRotation()
                }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: .new) { [weak self] coordinator, _ in
                MainActor.assumeIsolated {
                    guard let self, self.coordinator === coordinator, let device = self.device else { return }
                    self.onCaptureRotationChange?(coordinator.videoRotationAngleForHorizonLevelCapture, device.uniqueID)
                }
            }
        ]
        return coordinator.videoRotationAngleForHorizonLevelCapture
    }

    func applyPreviewRotation() {
        guard let coordinator, let connection = previewLayer?.connection else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let angle = coordinator.videoRotationAngleForHorizonLevelPreview
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        #if os(iOS)
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = device?.position == .front
        }
        #endif
    }
}

#endif
