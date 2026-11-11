import Foundation

internal struct VoiceMotionViewportLayout: Sendable, Equatable {
    static let centered = VoiceMotionViewportLayout(
        normalizedCenter: SIMD2(repeating: 0.5),
        normalizedControlDiameter: 2.0 / 3.0
    )

    let normalizedCenter: SIMD2<Float>
    let normalizedControlDiameter: Float

    init(
        normalizedCenter: SIMD2<Float>,
        normalizedControlDiameter: Float
    ) {
        self.normalizedCenter = SIMD2(
            normalizedCenter.x.isFinite ? normalizedCenter.x : 0.5,
            normalizedCenter.y.isFinite ? normalizedCenter.y : 0.5
        )
        self.normalizedControlDiameter = max(
            0,
            normalizedControlDiameter.isFinite
                ? normalizedControlDiameter
                : 0
        )
    }

    var shaderParameters: SIMD4<Float> {
        SIMD4(
            normalizedCenter.x,
            normalizedCenter.y,
            normalizedControlDiameter,
            VoiceMotionLayout.presentationScale
        )
    }
}

internal enum VoiceMotionLayout {
    static let phaseSeed: Float = 0.61803398875
    static let presentationScale: Float = 2.4
    static let morphCellCount = 5

    static func viewportLayout(
        controlFrame: CGRect,
        viewportSize: CGSize,
        visualScale: CGFloat
    ) -> VoiceMotionViewportLayout {
        let width = max(1, viewportSize.width)
        let height = max(1, viewportSize.height)
        let minimumDimension = min(width, height)
        let controlDiameter = max(
            0,
            min(controlFrame.width, controlFrame.height) * visualScale
        )
        return VoiceMotionViewportLayout(
            normalizedCenter: SIMD2(
                Float(controlFrame.midX / width),
                Float(controlFrame.midY / height)
            ),
            normalizedControlDiameter: Float(
                controlDiameter / minimumDimension
            )
        )
    }

    private struct AssignmentPoint {
        let index: Int
        let point: SIMD2<Float>
    }

    static func wrapOrbitPhase(_ phase: Float) -> Float {
        guard phase.isFinite else { return 0 }
        let tau = Float.pi * 2
        let wrapped = phase.truncatingRemainder(dividingBy: tau)
        return wrapped < 0 ? wrapped + tau : wrapped
    }

    static func sharedOrbitPhase(
        time: Float,
        seed: Float = phaseSeed
    ) -> Float {
        let safeTime = time.isFinite ? max(0, time) : 0
        // Time is integrated by the controller, including motion preferences.
        let clockwisePhase = safeTime * 0.68
            + 0.16 * sin(safeTime * 0.63 + 0.2)
            + 0.07 * sin(safeTime * 1.17 + 1.1)
        return wrapOrbitPhase(
            seed * Float.pi * 2 - clockwisePhase
        )
    }

    static func thinkingAssignmentPoint(
        cellIndex: Int,
        phase: Float,
        time: Float = 0,
        motionScale: Float = 0,
        presence: Float = 1
    ) -> SIMD2<Float> {
        let index = ((cellIndex % morphCellCount) + morphCellCount) % morphCellCount
        let slot = Float.pi * 2 * Float(index) / Float(morphCellCount)
        let activity = min(1.4, max(0, motionScale)) * min(1, max(0, presence))
        // Keep the assignment on the same evolving orbit as thinkingCell in Metal.
        let angle = wrapOrbitPhase(phase) + slot + activity * (
            0.16 * sin(time * 0.91 + slot)
                + 0.055 * sin(time * 1.37 - 2 * slot + 0.6)
        )
        let radial: Float = 0.109 + activity * (
            0.014 * sin(time * 0.73 + slot + 0.35)
                + 0.006 * sin(time * 1.31 - 2 * slot + 0.8)
        )
        return SIMD2(cos(angle), sin(angle)) * radial
    }

    static func adaptiveSpeakingBarMapping(
        anchorPhase: Float,
        time: Float = 0,
        motionScale: Float = 0,
        presence: Float = 1
    ) -> [Int] {
        let ordered = (0..<morphCellCount).map { index in
            AssignmentPoint(
                index: index,
                point: thinkingAssignmentPoint(
                    cellIndex: index,
                    phase: anchorPhase,
                    time: time,
                    motionScale: motionScale,
                    presence: presence
                )
            )
        }.sorted(by: comesBefore)

        var mapping = [Int](repeating: 0, count: morphCellCount)
        for (rank, item) in ordered.enumerated() {
            switch rank {
            case 0:
                mapping[item.index] = 0
            case 1:
                mapping[item.index] = 1
            case 2:
                mapping[item.index] = item.point.x < 0 ? 1 : 2
            case 3:
                mapping[item.index] = 2
            default:
                mapping[item.index] = 3
            }
        }
        return mapping
    }

    static func speakingLayoutCode(
        anchorPhase: Float,
        time: Float = 0,
        motionScale: Float = 0,
        presence: Float = 1
    ) -> Float {
        let mapping = adaptiveSpeakingBarMapping(
            anchorPhase: anchorPhase,
            time: time,
            motionScale: motionScale,
            presence: presence
        )
        var code: UInt32 = 0
        for cellIndex in 0..<morphCellCount {
            code |= UInt32(mapping[cellIndex]) << UInt32(cellIndex * 2)
        }
        return Float(code)
    }

    private static func comesBefore(_ left: AssignmentPoint, _ right: AssignmentPoint) -> Bool {
        if left.point.x < right.point.x { return true }
        if left.point.x > right.point.x { return false }
        if left.point.y < right.point.y { return true }
        if left.point.y > right.point.y { return false }
        return left.index < right.index
    }
}
