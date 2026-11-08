//
//  RealtimeVoiceControlCircle.swift
//  Mallow
//
//  Created by Codex on 2026/6/13.
//

import SwiftUI

struct VoiceMotionControlPlacement {
    let bounds: Anchor<CGRect>
}

struct VoiceMotionControlPlacementPreferenceKey: PreferenceKey {
    static let defaultValue: VoiceMotionControlPlacement? = nil

    static func reduce(
        value: inout VoiceMotionControlPlacement?,
        nextValue: () -> VoiceMotionControlPlacement?
    ) {
        value = nextValue() ?? value
    }
}

struct RealtimeVoiceControlCircle: View {
    nonisolated static let standardFrameSize: CGFloat = 280

    @ObservedObject var viewModel: MallowOverlayViewModel
    let motionController: VoiceMotionController
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var isCirclePressed = false
    @State private var didTriggerCircleLongPress = false
    @State private var shouldSuppressCircleTapOnEnd = false
    @State private var circleGestureCancelled = false
    @State private var circlePressOrigin: CGPoint?
    @State private var pressedCircleBaseSize: CGFloat?
    @State private var longPressTriggerTask: Task<Void, Never>?

    private let circleLongPressDuration = 0.38
    private let circleLongPressMaximumDistance: CGFloat = 42

    private var overlayErrorText: String? {
        if case let .error(message) = viewModel.state {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private var accessibilityValue: String {
        switch viewModel.state {
        case .connecting:
            String(localized: "NETWORK_CONNECTING", defaultValue: "Connecting")
        case .listening:
            String(localized: "VOICE_STATUS_LISTENING", defaultValue: "Listening")
        case .speaking:
            String(localized: "VOICE_STATUS_SPEAKING", defaultValue: "Speaking")
        case .loading:
            String(localized: "THINKING_STATUS", defaultValue: "Thinking", comment: "Thinking in-progress status")
        case .error:
            String(localized: "COMMON_ERROR_TITLE", defaultValue: "Error")
        }
    }

    private var accessibilityHint: String {
        if viewModel.serviceStatuses.contains(where: { $0.kind == .failed || $0.kind == .longWait }) {
            return String(localized: "COMMON_ACTION_RETRY", defaultValue: "Retry")
        }
        if overlayErrorText != nil {
            return String(localized: "VOICE_ACCESSIBILITY_RECONNECT_HINT", defaultValue: "Double-tap to reconnect.")
        }
        if viewModel.state == .connecting {
            return String(localized: "VOICE_CONNECTION_IN_PROGRESS", defaultValue: "Wait for the voice session to finish connecting.")
        }
        if viewModel.state == .loading {
            return String(localized: "CHAT_GENERATION_IN_PROGRESS", defaultValue: "Wait for the model to finish generating a response.")
        }
        return String(localized: "VOICE_ACCESSIBILITY_CONTROL_HINT", defaultValue: "Double-tap to control realtime voice. Use the Hold to talk action for push-to-talk.")
    }

    private var currentInteractionDiameter: CGFloat {
        pressedCircleBaseSize ?? interactionDiameter(for: viewModel.state)
    }

    private var circlePressScale: CGFloat {
        accessibilityReduceMotion ? 1 : (isCirclePressed ? 1.06 : 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.clear)
                .frame(width: currentInteractionDiameter, height: currentInteractionDiameter)
                .contentShape(Circle())
                .highPriorityGesture(circlePressGesture)
        }
        .frame(width: Self.standardFrameSize, height: Self.standardFrameSize)
        .background {
            // Keep one fixed-resolution Metal surface. SwiftUI's compositor moves
            // and scales it with the layout, without refeeding geometry.
            VoiceMotionSurface(controller: motionController)
                .frame(width: Self.standardFrameSize * 1.5, height: Self.standardFrameSize * 1.5)
                .scaleEffect(circlePressScale)
                .animation(
                    accessibilityReduceMotion ? nil : .smooth(duration: 0.24),
                    value: circlePressScale
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("VOICE_ACCESSIBILITY_CONTROL")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            triggerTapAction()
        }
        .accessibilityAction(named: Text("VOICE_ACTION_HOLD_TO_TALK")) {
            viewModel.performHoldToTalkAccessibilityAction()
        }
        .onDisappear {
            teardown()
        }
        .onChange(of: viewModel.state) { oldState, newState in
            handleStateChange(from: oldState, to: newState)
        }
        #if os(iOS) || os(macOS)
        .onChange(of: viewModel.isVisionCapturePresented) { _, _ in
            endCirclePressVisualState()
        }
        #endif
    }

    private var circlePressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                handleCircleDragChanged(value)
            }
            .onEnded { _ in
                handleCircleDragEnded()
            }
    }

    private func teardown() {
        cancelPendingLongPressTrigger()
        resetInteractionState()
    }

    private func interactionDiameter(
        for state: MallowOverlayViewModel.OverlayState
    ) -> CGFloat {
        switch state {
        case .listening:
            Self.standardFrameSize
        case .connecting, .speaking, .loading, .error:
            224
        }
    }

    private func handleCircleDragChanged(_ value: DragGesture.Value) {
        if circlePressOrigin == nil {
            beginCirclePress(at: value.startLocation)
        }
        guard let origin = circlePressOrigin else { return }

        let distance = hypot(value.location.x - origin.x, value.location.y - origin.y)
        guard distance > circleLongPressMaximumDistance else { return }
        guard !circleGestureCancelled else { return }

        circleGestureCancelled = true
        shouldSuppressCircleTapOnEnd = true
        cancelPendingLongPressTrigger()

        if didTriggerCircleLongPress {
            viewModel.handleCircleLongPressEnded()
            didTriggerCircleLongPress = false
        }

        endCirclePressVisualState()
    }

    private func handleCircleDragEnded() {
        cancelPendingLongPressTrigger()

        let didTriggerLongPress = didTriggerCircleLongPress
        let shouldSendTap = !circleGestureCancelled && !shouldSuppressCircleTapOnEnd

        if didTriggerLongPress {
            viewModel.handleCircleLongPressEnded()
        } else if shouldSendTap {
            triggerTapAction()
        }

        endCirclePressVisualState()

        didTriggerCircleLongPress = false
        shouldSuppressCircleTapOnEnd = false
        circleGestureCancelled = false
        circlePressOrigin = nil
    }

    private func beginCirclePress(at start: CGPoint) {
        circlePressOrigin = start
        pressedCircleBaseSize = currentInteractionDiameter
        circleGestureCancelled = false
        didTriggerCircleLongPress = false
        shouldSuppressCircleTapOnEnd = false
        isCirclePressed = true
        schedulePendingLongPressTrigger()
    }

    private func endCirclePressVisualState() {
        guard isCirclePressed || pressedCircleBaseSize != nil else { return }
        isCirclePressed = false
        pressedCircleBaseSize = nil
    }

    private func schedulePendingLongPressTrigger() {
        cancelPendingLongPressTrigger()
        longPressTriggerTask = Task { @MainActor in
            let delay = UInt64(circleLongPressDuration * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard isCirclePressed else { return }
            guard !circleGestureCancelled else { return }
            guard !didTriggerCircleLongPress else { return }
            shouldSuppressCircleTapOnEnd = true
            didTriggerCircleLongPress = triggerLongPressAction(viewModel: viewModel)
        }
    }

    private func cancelPendingLongPressTrigger() {
        longPressTriggerTask?.cancel()
        longPressTriggerTask = nil
    }

    private func triggerTapAction() {
        switch viewModel.state {
        case .listening, .speaking:
            AppHaptics.trigger(.lightTap)
        case .error:
            AppHaptics.trigger(.selection)
        case .connecting, .loading:
            break
        }
        viewModel.handleCircleTap()
    }

    private func triggerLongPressAction(
        viewModel: MallowOverlayViewModel?
    ) -> Bool {
        guard let viewModel, viewModel.state == .listening else { return false }
        AppHaptics.trigger(.selection)
        viewModel.handleCircleLongPressBegan()
        return true
    }

    private func handleStateChange(
        from oldState: MallowOverlayViewModel.OverlayState,
        to newState: MallowOverlayViewModel.OverlayState
    ) {
        let wasError: Bool = {
            if case .error = oldState { return true }
            return false
        }()
        let isError: Bool = {
            if case .error = newState { return true }
            return false
        }()

        if !wasError && isError {
            AppHaptics.trigger(.error)
        } else if wasError {
            switch newState {
            case .listening, .speaking:
                AppHaptics.trigger(.success)
            case .connecting, .loading, .error:
                break
            }
        }
    }

    private func resetInteractionState() {
        cancelPendingLongPressTrigger()
        isCirclePressed = false
        didTriggerCircleLongPress = false
        shouldSuppressCircleTapOnEnd = false
        circleGestureCancelled = false
        circlePressOrigin = nil
        pressedCircleBaseSize = nil
    }
}
