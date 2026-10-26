import Foundation
import Network
import os

/// A TLS connection to a Cast device using `Network.framework`.
///
/// Cast devices present self-signed certificates, so TLS peer verification
/// is disabled for this connection. Device authentication is not yet
/// implemented, so peers are unauthenticated.
public final class NetworkTransport: CastTransport, @unchecked Sendable {
    private enum OpenState {
        case idle
        case opening(CheckedContinuation<Void, any Error>)
        case open
        case closed
    }

    private let endpoint: NWEndpoint
    private let connectTimeout: Duration
    private let queue = DispatchQueue(label: "SwiftCast.NetworkTransport")
    private let connection: NWConnection
    private let lock = OSAllocatedUnfairLock<OpenState>(initialState: .idle)
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    public let inbound: AsyncThrowingStream<Data, any Error>

    /// Creates a transport for an arbitrary endpoint (host/port or Bonjour service).
    public init(endpoint: NWEndpoint, connectTimeout: Duration = .seconds(10)) {
        self.endpoint = endpoint
        self.connectTimeout = connectTimeout

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, DispatchQueue(label: "SwiftCast.TLSVerify"))
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.connectionTimeout = Int(connectTimeout.components.seconds.clamped(to: 1...120))
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        connection = NWConnection(to: endpoint, using: parameters)

        (inbound, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    }

    /// Creates a transport for a host and port (default 8009).
    public convenience init(host: String, port: UInt16 = 8009, connectTimeout: Duration = .seconds(10)) {
        self.init(
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 8009),
            connectTimeout: connectTimeout
        )
    }

    deinit {
        connection.cancel()
    }

    public func open() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                let shouldStart = lock.withLock { state -> Bool in
                    switch state {
                    case .idle:
                        state = .opening(cont)
                        return true
                    case .open:
                        cont.resume()
                        return false
                    case .opening, .closed:
                        cont.resume(throwing: CastError.connectionFailed("Transport cannot be reopened"))
                        return false
                    }
                }
                guard shouldStart else { return }
                connection.stateUpdateHandler = { [weak self] state in
                    self?.handle(state)
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + connectTimeout.timeInterval) { [weak self] in
                    self?.finishOpening(with: CastError.connectionFailed("Connection timed out"))
                }
            }
        } onCancel: {
            self.finishOpening(with: CancellationError())
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: CastError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    public func close() {
        let pending = lock.withLock { state -> CheckedContinuation<Void, any Error>? in
            defer { state = .closed }
            if case .opening(let cont) = state { return cont }
            return nil
        }
        pending?.resume(throwing: CastError.connectionFailed("Connection closed"))
        connection.cancel()
        continuation.finish()
    }

    // MARK: - Private

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            let opened = lock.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard case .opening(let cont) = state else { return nil }
                state = .open
                return cont
            }
            if let opened {
                opened.resume()
                receive()
            }
        case .waiting(let error):
            // A waiting connection has no viable path (e.g. host unreachable).
            finishOpening(with: CastError.connectionFailed(error.localizedDescription))
        case .failed(let error):
            finishOpening(with: CastError.connectionFailed(error.localizedDescription))
            continuation.finish(throwing: CastError.connectionFailed(error.localizedDescription))
        case .cancelled:
            continuation.finish()
        default:
            break
        }
    }

    private func finishOpening(with error: any Error) {
        let pending = lock.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard case .opening(let cont) = state else { return nil }
            state = .closed
            return cont
        }
        guard let pending else { return }
        pending.resume(throwing: error)
        connection.cancel()
        continuation.finish(throwing: error)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                continuation.yield(content)
            }
            if let error {
                continuation.finish(throwing: CastError.connectionFailed(error.localizedDescription))
                connection.cancel()
            } else if isComplete {
                continuation.finish()
                connection.cancel()
            } else {
                receive()
            }
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
