import Synchronization

/// A value that callbacks on other threads fill in, read once they are done. The lock makes the compiler
/// check what the hand-made boxes used to promise.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    var value: Value { mutex.withLock { $0 } }

    @discardableResult
    func update<Result: Sendable>(_ change: (inout Value) -> Result) -> Result {
        mutex.withLock { change(&$0) }
    }
}
