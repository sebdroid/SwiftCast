import Foundation
import os

/// Fans a sequence of values out to any number of `AsyncStream` subscribers.
final class Broadcaster<Element: Sendable>: Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
        var isClosed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Creates a new subscription. The stream ends when ``finishAll()`` or
    /// ``close()`` is called or the consumer stops iterating. While the
    /// broadcaster is closed, it delivers `initial` and ends at once.
    func subscribe(
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .bufferingNewest(256),
        initial: Element? = nil
    ) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: bufferingPolicy)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        if let initial { continuation.yield(initial) }
        let isClosed = state.withLock { state in
            if !state.isClosed { state.continuations[id] = continuation }
            return state.isClosed
        }
        if isClosed { continuation.finish() }
        return stream
    }

    func yield(_ element: Element) {
        let targets = state.withLock { Array($0.continuations.values) }
        for continuation in targets { continuation.yield(element) }
    }

    /// Finishes every current subscription. New subscriptions may still be made.
    func finishAll() {
        finish(closing: false)
    }

    /// Finishes every current subscription, and ends later ones as soon as
    /// they are made, until ``reopen()``.
    func close() {
        finish(closing: true)
    }

    func reopen() {
        state.withLock { $0.isClosed = false }
    }

    private func finish(closing: Bool) {
        let targets = state.withLock { state -> [AsyncStream<Element>.Continuation] in
            if closing { state.isClosed = true }
            defer { state.continuations.removeAll() }
            return Array(state.continuations.values)
        }
        for continuation in targets { continuation.finish() }
    }

    var subscriberCount: Int { state.withLock { $0.continuations.count } }
}
