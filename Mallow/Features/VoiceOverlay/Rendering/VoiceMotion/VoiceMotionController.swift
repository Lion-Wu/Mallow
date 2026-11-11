import Foundation

public final class VoiceMotionController: @unchecked Sendable {
    private struct SpringTuning {
        let frequencyHz: Float
        let damping: Float
    }

    private static let tuning: [VoiceMotionState: SpringTuning] = [
        .connecting: SpringTuning(frequencyHz: 1.55, damping: 0.94),
        .listening: SpringTuning(frequencyHz: 1.92, damping: 0.90),
        .thinking: SpringTuning(frequencyHz: 1.42, damping: 0.88),
        .speaking: SpringTuning(frequencyHz: 1.78, damping: 0.90),
        .error: SpringTuning(frequencyHz: 1.66, damping: 0.93),
    ]

    private static let errorApertureEnterTuning = SpringTuning(
        frequencyHz: 1.20,
        damping: 1.02
    )
    private static let errorApertureExitTuning = SpringTuning(
        frequencyHz: 1.70,
        damping: 1.00
    )

    private let lock = NSLock()
    private var currentState: VoiceMotionState
    private var stateTime: Float = 0
    private var elapsedTime: TimeInterval = 0
    private var connectingStartTime: TimeInterval = 0
    private var connectingEndTime: TimeInterval = 0
    private var weights = [Float](repeating: 0, count: VoiceMotionState.allCases.count)
    private var velocity = [Float](repeating: 0, count: VoiceMotionState.allCases.count)
    private var target = [Float](repeating: 0, count: VoiceMotionState.allCases.count)
    private var targetAudio = VoiceAudioLevels.silent
    private var currentAudio = VoiceAudioLevels.silent
    private var audioResponse = SIMD4<Float>(repeating: 0)
    private var audioResponseVelocity = SIMD4<Float>(repeating: 0)
    private var audioSource: (any VoiceMotionAudioSource)?
    private var currentAppearance: VoiceMotionAppearance
    private var reducedMotion = false
    private var speakingLayoutAnchorPhase: Float
    private var speakingLayoutCode: Float
    private var errorApertureProgress: Float
    private var errorApertureVelocity: Float = 0

    public init(
        initialState: VoiceMotionState = .connecting,
        appearance: VoiceMotionAppearance = .porcelain
    ) {
        currentState = initialState
        currentAppearance = appearance
        let initialSpeakingPhase = VoiceMotionLayout.sharedOrbitPhase(
            time: 0
        )
        speakingLayoutAnchorPhase = initialSpeakingPhase
        speakingLayoutCode = VoiceMotionLayout.speakingLayoutCode(
            anchorPhase: initialSpeakingPhase
        )
        errorApertureProgress = initialState == .error ? 1 : 0
        weights[initialState.rawValue] = 1
        target[initialState.rawValue] = 1
    }

    public var state: VoiceMotionState {
        lock.voiceMotionWithLock { currentState }
    }

    public var appearance: VoiceMotionAppearance {
        get { lock.voiceMotionWithLock { currentAppearance } }
        set { lock.voiceMotionWithLock { currentAppearance = newValue } }
    }

    public var isReducedMotionEnabled: Bool {
        get { lock.voiceMotionWithLock { reducedMotion } }
        set {
            lock.voiceMotionWithLock {
                reducedMotion = newValue
                if newValue {
                    connectingStartTime = elapsedTime
                    connectingEndTime = elapsedTime
                    settleStateTransition()
                }
            }
        }
    }

    public func setState(_ state: VoiceMotionState, immediate: Bool = false) {
        lock.voiceMotionWithLock {
            guard state != currentState || immediate else { return }
            let previousState = currentState
            let speakingWeight = weights[VoiceMotionState.speaking.rawValue]
            let thinkingWeight = weights[VoiceMotionState.thinking.rawValue]
            let currentPhase = VoiceMotionLayout.sharedOrbitPhase(
                time: Float(elapsedTime)
            )
            if state == .speaking && (immediate || speakingWeight < 0.0005) {
                updateSpeakingLayout(currentPhase)
            } else if state == .thinking,
                      previousState == .speaking,
                      speakingWeight > 0.9995,
                      thinkingWeight < 0.0005 {
                updateSpeakingLayout(currentPhase)
            }

            currentState = state
            stateTime = 0
            if state == .connecting {
                connectingStartTime = elapsedTime
                connectingEndTime = elapsedTime
            }
            for index in target.indices { target[index] = 0 }
            target[state.rawValue] = 1
            if immediate || reducedMotion { settleStateTransition() }
        }
    }

    public func setAudioLevels(_ levels: VoiceAudioLevels) {
        lock.voiceMotionWithLock { targetAudio = levels }
    }

    func setAudioSource(_ source: (any VoiceMotionAudioSource)?) {
        lock.voiceMotionWithLock { audioSource = source }
    }

    public func setAccentSRGB(red: Float, green: Float, blue: Float, alpha: Float = 1) {
        lock.voiceMotionWithLock {
            currentAppearance = .sRGB(
                red: red,
                green: green,
                blue: blue,
                alpha: alpha,
                motionScale: currentAppearance.motionScale,
                glowStrength: currentAppearance.glowStrength
            )
        }
    }

    internal func advance(deltaTime: TimeInterval) -> VoiceMotionSnapshot {
        lock.voiceMotionWithLock {
            let frameDelta = min(
                Float(0.1),
                max(0, Float(deltaTime.isFinite ? deltaTime : 0))
            )
            guard frameDelta > 0 else { return makeSnapshot() }
            stateTime += frameDelta
            elapsedTime += TimeInterval(frameDelta) * TimeInterval(effectiveMotionScale)
            if currentState == .connecting {
                connectingEndTime = elapsedTime
            }

            // Subdivide integration without dropping time at lower refresh rates.
            let stepCount = max(1, Int(ceil(frameDelta * 120)))
            let springDelta = frameDelta / Float(stepCount)
            for _ in 0..<stepCount {
                advanceStateSprings(deltaTime: springDelta)
            }

            if let audioSource {
                targetAudio = audioSource.audioLevels(
                    deltaTime: TimeInterval(frameDelta)
                )
            }

            currentAudio = VoiceAudioLevels(
                rms: envelope(
                    current: currentAudio.rms,
                    target: targetAudio.rms,
                    dt: frameDelta,
                    attack: 0.030,
                    release: 0.160
                ),
                low: envelope(
                    current: currentAudio.low,
                    target: targetAudio.low,
                    dt: frameDelta,
                    attack: 0.040,
                    release: 0.210
                ),
                mid: envelope(
                    current: currentAudio.mid,
                    target: targetAudio.mid,
                    dt: frameDelta,
                    attack: 0.030,
                    release: 0.180
                ),
                high: envelope(
                    current: currentAudio.high,
                    target: targetAudio.high,
                    dt: frameDelta,
                    attack: 0.025,
                    release: 0.140
                )
            )
            advanceAudioResponse(deltaTime: frameDelta)
            return makeSnapshot()
        }
    }

    private var effectiveMotionScale: Float {
        reducedMotion ? 0 : currentAppearance.motionScale
    }

    private func makeSnapshot() -> VoiceMotionSnapshot {
        var appearance = currentAppearance
        if reducedMotion { appearance.motionScale = 0 }
        return VoiceMotionSnapshot(
            state: currentState,
            time: Float(elapsedTime),
            stateTime: stateTime,
            connectingInterval: SIMD2(Float(connectingStartTime), Float(connectingEndTime)),
            stateWeights: SIMD4(weights[0], weights[1], weights[2], weights[3]),
            errorWeight: weights[4],
            errorApertureProgress: errorApertureProgress,
            speakingLayoutAnchorPhase: speakingLayoutAnchorPhase,
            speakingLayoutCode: speakingLayoutCode,
            audio: reducedMotion ? .silent : currentAudio,
            audioResponse: reducedMotion ? SIMD4(repeating: 0) : audioResponse,
            appearance: appearance
        )
    }

    private func advanceStateSprings(deltaTime springDelta: Float) {
        for state in VoiceMotionState.allCases {
            guard let tuning = Self.tuning[state] else { continue }
            let index = state.rawValue
            let omega = Float.pi * 2 * tuning.frequencyHz
            let x = weights[index]
            let v = velocity[index]
            let goal = target[index]
            let f = 1 + 2 * springDelta * tuning.damping * omega
            let hoo = springDelta * omega * omega
            let hhoo = springDelta * hoo
            let inverse = 1 / (f + hhoo)
            weights[index] = max(
                0,
                (
                    f * x
                        + springDelta * v
                        + hhoo * goal
                ) * inverse
            )
            velocity[index] = (v + hoo * (goal - x)) * inverse
        }

        let apertureGoal: Float = currentState == .error ? 1 : 0
        let apertureTuning = apertureGoal > 0.5
            ? Self.errorApertureEnterTuning
            : Self.errorApertureExitTuning
        let apertureOmega = Float.pi * 2 * apertureTuning.frequencyHz
        let apertureX = errorApertureProgress
        let apertureV = errorApertureVelocity
        let apertureF = 1
            + 2 * springDelta * apertureTuning.damping * apertureOmega
        let apertureHoo = springDelta * apertureOmega * apertureOmega
        let apertureHhoo = springDelta * apertureHoo
        let apertureInverse = 1 / (apertureF + apertureHhoo)
        errorApertureProgress = min(1, max(0, (
            apertureF * apertureX
                + springDelta * apertureV
                + apertureHhoo * apertureGoal
        ) * apertureInverse))
        errorApertureVelocity = (
            apertureV + apertureHoo * (apertureGoal - apertureX)
        ) * apertureInverse

        var sum: Float = 0
        for weight in weights { sum += weight }
        if sum > 0.0000001 {
            for index in weights.indices { weights[index] /= sum }
        } else {
            for index in weights.indices { weights[index] = 0 }
            weights[currentState.rawValue] = 1
            for index in velocity.indices { velocity[index] = 0 }
        }
    }

    private func settleStateTransition() {
        weights = target
        for index in velocity.indices { velocity[index] = 0 }
        errorApertureProgress = currentState == .error ? 1 : 0
        errorApertureVelocity = 0
    }

    private func advanceAudioResponse(deltaTime dt: Float) {
        let goals = targetAudio.vector
        let frequencies = SIMD4<Float>(3.8, 3.2, 4.4, 5.2)
        let damping = SIMD4<Float>(0.70, 0.66, 0.72, 0.78)
        for index in 0..<4 {
            let omega = 2 * Float.pi * frequencies[index]
            let decay = damping[index] * omega
            let frequency = omega * sqrt(1 - damping[index] * damping[index])
            let displacement = audioResponse[index] - goals[index]
            let velocity = audioResponseVelocity[index]
            let sine = sin(frequency * dt)
            let cosine = cos(frequency * dt)
            let attenuation = exp(-decay * dt)

            // Exact damped response to this frame's target, parallel to the
            // envelope above. Keeping velocity lets syllables release elastically.
            audioResponse[index] = goals[index] + attenuation * (
                displacement * cosine
                    + (velocity + decay * displacement) / frequency * sine
            )
            audioResponseVelocity[index] = attenuation * (
                velocity * cosine
                    - (decay * velocity + omega * omega * displacement)
                        / frequency * sine
            )
        }
    }

    private func envelope(
        current: Float,
        target: Float,
        dt: Float,
        attack: Float,
        release: Float
    ) -> Float {
        let timeConstant = target > current ? attack : release
        let blend = 1 - exp(-dt / max(timeConstant, 0.0001))
        return current + (target - current) * blend
    }

    private func updateSpeakingLayout(_ phase: Float) {
        speakingLayoutAnchorPhase = VoiceMotionLayout.wrapOrbitPhase(phase)
        let weight = min(1, max(0, weights[VoiceMotionState.thinking.rawValue]))
        let presence = weight * weight * weight * (weight * (weight * 6 - 15) + 10)
        speakingLayoutCode = VoiceMotionLayout.speakingLayoutCode(
            anchorPhase: speakingLayoutAnchorPhase,
            time: Float(elapsedTime),
            motionScale: effectiveMotionScale,
            presence: presence
        )
    }

}

private extension NSLock {
    @discardableResult
    func voiceMotionWithLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
