import Foundation

/// Thread-safe 1-to-N broadcaster for `AsyncStream`-style delivery.
///
/// One publish call reaches all live subscribers. Unsubscription is implicit
/// via `AsyncStream` termination (task cancellation finishes the iterator).
internal final class PeerStreamFanOut<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    private var finished: Bool = false
    private var last: Value?

    internal func subscribe(replayLast: Bool = true) -> AsyncStream<Value> {
        AsyncStream { cont in
            let id = UUID()
            let (alreadyFinished, replay) = lock.withLock { () -> (Bool, Value?) in
                if finished { return (true, nil) }
                let r = replayLast ? last : nil
                continuations[id] = cont
                return (false, r)
            }
            if alreadyFinished {
                cont.finish()
                return
            }
            if let replay { cont.yield(replay) }
            cont.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    internal func publish(_ value: Value) {
        let conts = lock.withLock { () -> [AsyncStream<Value>.Continuation] in
            guard !finished else { return [] }
            last = value
            return Array(continuations.values)
        }
        for c in conts { c.yield(value) }
    }

    internal func finish() {
        let conts = lock.withLock { () -> [AsyncStream<Value>.Continuation] in
            finished = true
            let cs = Array(continuations.values)
            continuations.removeAll()
            return cs
        }
        for c in conts { c.finish() }
    }

    internal var lastValue: Value? {
        lock.withLock { last }
    }
}
