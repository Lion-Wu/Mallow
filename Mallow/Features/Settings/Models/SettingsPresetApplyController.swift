//
//  SettingsPresetApplyController.swift
//  Mallow
//
//  Created by Codex on 2026/6/14.
//

import Foundation

@MainActor
final class SettingsPresetApplyController {
    typealias StatusPublisher = @MainActor @Sendable (TTSPresetApplyStatus) -> Void
    typealias ApplyOperation = @MainActor (TTSPresetApplyRequest, @escaping StatusPublisher) async -> Void

    var onStatusChange: ((TTSPresetApplyStatus) -> Void)?
    var connectionReporter: @MainActor @Sendable (ServerConnectionObservation) -> Void = { _ in } {
        didSet { coordinator.connectionReporter = connectionReporter }
    }

    private let coordinator: TTSPresetApplyCoordinator

    private let applyOperation: ApplyOperation
    private(set) var status: TTSPresetApplyStatus
    private var didApplyOnLaunch = false
    private var generation = UUID()
    private var activeTask: Task<Void, Never>?

    init(
        initialStatus: TTSPresetApplyStatus = .idle,
        applyOperation: ApplyOperation? = nil
    ) {
        let coordinator = TTSPresetApplyCoordinator(initialStatus: initialStatus)
        self.coordinator = coordinator
        self.status = initialStatus
        self.applyOperation = applyOperation ?? { request, publish in
            await coordinator.apply(request, publish: publish)
        }
    }

    func applyOnLaunchIfNeeded(makeRequest: () -> TTSPresetApplyRequest?) async {
        guard !didApplyOnLaunch else { return }
        didApplyOnLaunch = true
        await apply(makeRequest())
    }

    func apply(_ request: TTSPresetApplyRequest?) async {
        guard let request, activeTask == nil else { return }

        let generation = generation
        let applyOperation = applyOperation
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await applyOperation(request) { [weak self] status in
                guard let self, self.generation == generation else { return }
                self.update(status)
            }
        }
        activeTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if self.generation == generation { activeTask = nil }
    }

    func reset() {
        generation = UUID()
        activeTask?.cancel()
        activeTask = nil
        didApplyOnLaunch = false
        coordinator.reset()
        update(.idle)
    }

    private func update(_ nextStatus: TTSPresetApplyStatus) {
        status = nextStatus
        onStatusChange?(nextStatus)
    }
}
