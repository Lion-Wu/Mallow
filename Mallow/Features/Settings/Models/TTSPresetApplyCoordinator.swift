//
//  TTSPresetApplyCoordinator.swift
//  Mallow
//
//  Created by Codex on 2026/6/13.
//

import Foundation

struct TTSPresetApplyStatus: Equatable {
    var isApplying: Bool = false
    var isRetrying: Bool = false
    var retryAttempt: Int = 0
    var retryLastError: String?
    var lastError: String?
    var lastAppliedAt: Date?
    var lastSucceeded: Bool = false

    static let idle = TTSPresetApplyStatus()

    func starting() -> TTSPresetApplyStatus {
        TTSPresetApplyStatus(
            isApplying: true,
            isRetrying: false,
            retryAttempt: 0,
            retryLastError: nil,
            lastError: nil,
            lastAppliedAt: nil,
            lastSucceeded: false
        )
    }

    func updatingRetry(_ retryStatus: TTSPresetApplyRetryStatus?) -> TTSPresetApplyStatus {
        var next = self
        if let retryStatus {
            next.isRetrying = true
            next.retryAttempt = retryStatus.retryAttempt
            next.retryLastError = retryStatus.lastErrorDescription
        } else {
            next.isRetrying = false
            next.retryAttempt = 0
            next.retryLastError = nil
        }
        return next
    }

    func recordingFailure(_ message: String, at date: Date) -> TTSPresetApplyStatus {
        var next = updatingRetry(nil)
        next.isApplying = false
        next.lastError = message
        next.lastAppliedAt = date
        next.lastSucceeded = false
        return next
    }

    func recordingSuccess(at date: Date) -> TTSPresetApplyStatus {
        var next = updatingRetry(nil)
        next.isApplying = false
        next.lastError = nil
        next.lastAppliedAt = date
        next.lastSucceeded = true
        return next
    }
}

@MainActor
final class TTSPresetApplyCoordinator {
    typealias StatusPublisher = @MainActor @Sendable (TTSPresetApplyStatus) -> Void

    var connectionReporter: @MainActor @Sendable (ServerConnectionObservation) -> Void = { _ in }

    private let presetApplyService: TTSPresetApplyService
    private let now: @Sendable () -> Date
    private(set) var status: TTSPresetApplyStatus
    private var generation = UUID()

    init(
        presetApplyService: TTSPresetApplyService = TTSPresetApplyService(),
        initialStatus: TTSPresetApplyStatus = .idle,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.presetApplyService = presetApplyService
        self.status = initialStatus
        self.now = now
    }

    func apply(
        _ request: TTSPresetApplyRequest,
        publish: @escaping StatusPublisher
    ) async {
        guard !status.isApplying else { return }
        let generation = generation
        update(status.starting(), publish: publish)

        do {
            let report = connectionReporter
            try await presetApplyService.apply(request, connectionReporter: { observation in
                await report(observation)
            }) { [weak self] retryStatus in
                await MainActor.run {
                    guard let self, self.generation == generation else { return }
                    self.update(self.status.updatingRetry(retryStatus), publish: publish)
                }
            }
        } catch let applyError as TTSPresetApplyError {
            guard self.generation == generation else { return }
            update(status.recordingFailure(applyError.settingsMessage, at: now()), publish: publish)
            return
        } catch {
            guard self.generation == generation else { return }
            update(status.recordingFailure(error.localizedDescription, at: now()), publish: publish)
            return
        }

        guard self.generation == generation else { return }
        update(status.recordingSuccess(at: now()), publish: publish)
    }

    func reset() {
        generation = UUID()
        status = .idle
    }

    private func update(_ nextStatus: TTSPresetApplyStatus, publish: StatusPublisher) {
        status = nextStatus
        publish(nextStatus)
    }
}
