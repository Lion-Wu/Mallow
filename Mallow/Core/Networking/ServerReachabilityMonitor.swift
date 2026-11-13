//
//  ServerReachabilityMonitor.swift
//  Mallow
//
//  Created by OpenAI Codex on 2025/03/10.
//

import Foundation
import Network

private final class TCPProbeResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var connection: NWConnection?
    private var pendingResult: Result<Void, Error>?

    func install(
        connection: NWConnection,
        continuation: CheckedContinuation<Void, Error>
    ) {
        lock.lock()
        if let pendingResult {
            lock.unlock()
            connection.cancel()
            continuation.resume(with: pendingResult)
            return
        }
        self.connection = connection
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard pendingResult == nil else {
            lock.unlock()
            return
        }
        pendingResult = result
        let connection = connection
        let continuation = continuation
        self.connection = nil
        self.continuation = nil
        lock.unlock()

        connection?.cancel()
        continuation?.resume(with: result)
    }
}

/// Connection evidence from a real request, independent of API success or failure.
struct ServerConnectionObservation: Sendable {
    let baseURL: String
    let observedAt = Date()
    let errorCode: URLError.Code?

    init(baseURL: String, errorCode: URLError.Code? = nil) {
        self.baseURL = baseURL
        self.errorCode = errorCode
    }
}

/// Observes network changes and checks endpoints only when their status is needed.
@MainActor
final class ServerReachabilityMonitor: ObservableObject {
    enum Service: Hashable {
        case chat, tts
    }

    private enum ProbeResult {
        case completed
        case superseded
    }

    private struct Probe {
        let id: UUID
        let task: Task<ProbeResult, Never>
    }

    private let noticePublisher: any AppNoticePublishing
    // These values describe the latest evidence, not a guarantee of API availability.
    @Published private(set) var isChatReachable: Bool?
    @Published private(set) var isTTSReachable: Bool?

    private var pathMonitor: NWPathMonitor?
    private var pathMonitorID: UUID?
    private var lastPath: NWPath?
    private var awaitingInitialPath = false
    private var snapshotProvider: (@MainActor () -> ServerReachabilitySnapshot)?
    private var snapshot: ServerReachabilitySnapshot?
    private var probes: [Service: Probe] = [:]
    // Timestamps order observations; they do not expire connection state.
    private var observationDates: [Service: Date] = [:]
    private var pendingServices: Set<Service> = []
    private var isActive = true

    init(noticePublisher: any AppNoticePublishing = NoopAppNoticePublisher.shared) {
        self.noticePublisher = noticePublisher
    }

    func startMonitoring(
        snapshotProvider: @escaping @MainActor () -> ServerReachabilitySnapshot
    ) {
        self.snapshotProvider = snapshotProvider
        updateSnapshot(snapshotProvider())
        startPathMonitorIfNeeded()
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            startPathMonitorIfNeeded()
        } else {
            pauseMonitoring()
        }
    }

    func stopMonitoring() {
        pauseMonitoring()
        snapshotProvider = nil
        snapshot = nil
        lastPath = nil
        pendingServices.removeAll()
        observationDates.removeAll()
        isChatReachable = nil
        isTTSReachable = nil
    }

    private func pauseMonitoring() {
        pathMonitorID = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        cancelProbes()
    }

    private func startPathMonitorIfNeeded() {
        guard isActive, pathMonitor == nil, snapshotProvider != nil else { return }
        let monitor = NWPathMonitor()
        let id = UUID()
        pathMonitorID = id
        awaitingInitialPath = true
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self, self.pathMonitorID == id else { return }
                self.networkPathChanged(path)
            }
        }
        monitor.start(queue: DispatchQueue(label: "Mallow.NetworkPath"))
    }

    private func networkPathChanged(_ path: NWPath) {
        guard let snapshotProvider else { return }
        let isInitialUpdate = awaitingInitialPath
        awaitingInitialPath = false
        let pathChanged = lastPath.map { $0 != path } ?? false
        if !isInitialUpdate, !pathChanged { return }
        lastPath = path
        updateSnapshot(snapshotProvider())
        var services = pendingServices
        if pathChanged {
            // Recheck every path change, even when the system reports no usable path.
            // Preserve the last result until new connection evidence replaces it.
            cancelProbes()
            services.formUnion([.chat, .tts])
        }
        pendingServices.formUnion(services)
        // The first path callback is a baseline, not another launch check.
        guard !services.isEmpty else { return }
        let requestedServices = services
        let monitorID = pathMonitorID
        Task { [weak self] in
            guard let self, self.isActive, self.pathMonitorID == monitorID,
                  let snapshotProvider = self.snapshotProvider else { return }
            await self.checkAll(snapshot: snapshotProvider(), services: requestedServices)
        }
    }

    private func updateSnapshot(_ newSnapshot: ServerReachabilitySnapshot) {
        if snapshot?.chatBaseURL != newSnapshot.chatBaseURL {
            invalidate(.chat)
        }
        if snapshot?.ttsBaseURL != newSnapshot.ttsBaseURL ||
            snapshot?.requiresTTSNetworkService != newSnapshot.requiresTTSNetworkService {
            invalidate(.tts)
        }
        snapshot = newSnapshot
        if !newSnapshot.requiresTTSNetworkService {
            isTTSReachable = true
            pendingServices.remove(.tts)
            clearConnectionNotice(for: .tts)
        }
    }

    /// Reuse the last observation until an explicit probe or a real request updates it.
    func checkAll(
        snapshot: ServerReachabilitySnapshot,
        services: Set<Service> = [.chat, .tts],
        force: Bool = false
    ) async {
        guard snapshotProvider != nil, !Task.isCancelled else { return }
        updateSnapshot(snapshot)
        // Keep the intent until a probe takes ownership, including across scene pauses.
        pendingServices.formUnion(services.filter { force || observationDates[$0] == nil })
        guard isActive else {
            // A launch check requested while the scene is inactive runs on activation.
            pendingServices.formUnion(services)
            return
        }
        repeat {
            await withTaskGroup(of: Void.self) { group in
                for service in services {
                    group.addTask { await self.check(service) }
                }
            }
            // A path change may also replace a service that finished before its peers.
        } while isActive && !Task.isCancelled && services.contains {
            pendingServices.contains($0) || probes[$0] != nil
        }
    }

    func record(_ observation: ServerConnectionObservation, for service: Service) {
        if let snapshotProvider { updateSnapshot(snapshotProvider()) }
        guard let base = baseURL(for: service),
              base.trimmingCharacters(in: .whitespacesAndNewlines) ==
                observation.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
              observation.observedAt >= (observationDates[service] ?? .distantPast) else { return }
        let reachable: Bool?
        switch observation.errorCode {
        case nil:
            reachable = true
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
             .notConnectedToInternet, .networkConnectionLost:
            reachable = false
        case .timedOut:
            // A timeout does not establish whether the server is offline or merely busy.
            reachable = nil
        default:
            // Cancellation, TLS, authorization and payload errors retain their own UI.
            return
        }
        observationDates[service] = observation.observedAt
        setReachable(reachable, for: service)
        if reachable == true {
            clearConnectionNotice(for: service)
        } else if let code = observation.errorCode {
            publishConnectionFailure(URLError(code), base: base, service: service)
        }
    }

    private func check(_ service: Service) async {
        while isActive, !Task.isCancelled {
            guard let base = baseURL(for: service),
                  let endpoint = hostPort(from: base, defaultPort: service == .chat ? 80 : 9880) else {
                pendingServices.remove(service)
                return
            }
            let probe: Probe
            if let currentProbe = probes[service] {
                probe = currentProbe
            } else {
                guard pendingServices.contains(service) || observationDates[service] == nil else { return }
                probe = startProbe(service, base: base, endpoint: endpoint)
                probes[service] = probe
            }
            pendingServices.remove(service)
            switch await probe.task.value {
            case .completed:
                return
            case .superseded:
                // Follow only explicit lifecycle replacements, never retry a failed probe.
                continue
            }
        }
    }

    private func startProbe(
        _ service: Service,
        base: String,
        endpoint: (host: String, port: UInt16)
    ) -> Probe {
        let id = UUID()
        let startedAt = Date()
        let task = Task { [weak self] () -> ProbeResult in
            guard let self else { return .completed }
            defer {
                if self.probes[service]?.id == id { self.probes[service] = nil }
            }
            do {
                try await self.tcpProbe(host: endpoint.host, port: endpoint.port)
                guard !Task.isCancelled, self.probes[service]?.id == id else { return .superseded }
                guard (self.observationDates[service] ?? .distantPast) <= startedAt else { return .completed }
                self.observationDates[service] = Date()
                self.setReachable(true, for: service)
                self.clearConnectionNotice(for: service)
            } catch is CancellationError {
                return .superseded
            } catch {
                guard !Task.isCancelled, self.probes[service]?.id == id else { return .superseded }
                guard (self.observationDates[service] ?? .distantPast) <= startedAt else { return .completed }
                self.observationDates[service] = Date()
                self.setReachable(false, for: service)
                self.publishConnectionFailure(error, base: base, service: service)
            }
            return .completed
        }
        return Probe(id: id, task: task)
    }

    private func baseURL(for service: Service) -> String? {
        guard let snapshot else { return nil }
        switch service {
        case .chat: return snapshot.chatBaseURL
        case .tts: return snapshot.requiresTTSNetworkService ? snapshot.ttsBaseURL : nil
        }
    }

    private func setReachable(_ reachable: Bool?, for service: Service) {
        switch service {
        case .chat: isChatReachable = reachable
        case .tts: isTTSReachable = reachable
        }
    }

    private func invalidate(_ service: Service) {
        if let probe = probes.removeValue(forKey: service) {
            pendingServices.insert(service)
            probe.task.cancel()
        }
        observationDates[service] = nil
        setReachable(nil, for: service)
        clearConnectionNotice(for: service)
    }

    private func cancelProbes() {
        pendingServices.formUnion(probes.keys)
        let activeProbes = probes.values
        probes.removeAll()
        for probe in activeProbes { probe.task.cancel() }
    }

    private func category(for service: Service) -> AppErrorNotice.Category {
        service == .chat ? .chatConnection : .ttsConnection
    }

    private func noticeTitle(for service: Service) -> String {
        switch service {
        case .chat:
            return NSLocalizedString("CHAT_SERVER_UNREACHABLE", value: "Text server unreachable", comment: "Shown when the LLM endpoint cannot be reached")
        case .tts:
            return NSLocalizedString("VOICE_TTS_SERVER_UNREACHABLE", value: "Voice server unreachable", comment: "Shown when the TTS endpoint cannot be reached")
        }
    }

    private func publishConnectionFailure(_ error: Error, base: String, service: Service) {
        let category = category(for: service)
        guard shouldPublishNotice(for: category) else { return }
        noticePublisher.publishCritical(
            title: noticeTitle(for: service),
            message: friendlyMessage(for: error, base: base),
            category: category
        )
    }

    private func clearConnectionNotice(for service: Service) {
        // Connection recovery must not dismiss an unrelated API or playback error.
        noticePublisher.clear(category: category(for: service))
    }

    private func hostPort(from base: String, defaultPort: UInt16) -> (host: String, port: UInt16)? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Ensure we have a scheme so URLComponents can parse host/port reliably.
        let normalized: String
        if trimmed.contains("://") {
            normalized = trimmed
        } else {
            normalized = "http://\(trimmed)"
        }

        guard let comps = URLComponents(string: normalized) else { return nil }
        let pathHost = comps.path.split(separator: "/").first.map(String.init)
        guard let resolvedHost = comps.host ?? pathHost, !resolvedHost.isEmpty else { return nil }

        let resolvedPort: UInt16? = {
            if let p = comps.port {
                return UInt16(exactly: p)
            }
            if let scheme = comps.scheme?.lowercased() {
                switch scheme {
                case "https": return 443
                case "http": return 80
                default: break
                }
            }
            return defaultPort
        }()
        guard let resolvedPort else { return nil }

        return (resolvedHost, resolvedPort)
    }

    private func tcpProbe(
        host: String,
        port: UInt16,
        timeout: TimeInterval = NetworkRequestTimeouts.connection
    ) async throws {
        let gate = TCPProbeResumeGate()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let endpointHost = NWEndpoint.Host(host)
                guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                    continuation.resume(throwing: URLError(.badURL))
                    return
                }

                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let connection = NWConnection(host: endpointHost, port: endpointPort, using: params)
                let queue = DispatchQueue(label: "Mallow.TCPProbe.\(host):\(port)")

                gate.install(connection: connection, continuation: continuation)

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.finish(.success(()))
                    case .failed(let error):
                        gate.finish(.failure(error))
                    case .cancelled:
                        gate.finish(.failure(URLError(.cancelled)))
                    default:
                        break
                    }
                }

                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    gate.finish(.failure(URLError(.timedOut)))
                }
            }
        }, onCancel: {
            gate.finish(.failure(CancellationError()))
        })
    }

    private func friendlyMessage(for error: Error, base: String) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .cannotConnectToHost:
                return String(format: NSLocalizedString("NETWORK_CONNECTION_FAILED", value: "Could not connect to %@", comment: "Shown when a server host is unreachable"), base)
            case .notConnectedToInternet:
                return NSLocalizedString("NETWORK_OFFLINE", value: "You appear to be offline. Please check your internet connection.", comment: "Shown when the device is offline")
            case .networkConnectionLost:
                return NSLocalizedString("NETWORK_CONNECTION_LOST", value: "The network connection was lost.", comment: "Shown when the connection drops")
            case .timedOut:
                return NSLocalizedString("NETWORK_REQUEST_TIMEOUT", value: "The request timed out. The server may be offline or busy.", comment: "Shown when a server request times out")
            default:
                return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private func shouldPublishNotice(for category: AppErrorNotice.Category) -> Bool {
        // Avoid re-publishing if the same category is already displayed or was dismissed and not yet resolved.
        guard !noticePublisher.isDismissed(for: category) else { return false }
        return !noticePublisher.notices.contains(where: { $0.category == category })
    }
}
