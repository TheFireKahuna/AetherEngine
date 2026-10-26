import Synchronization

/// A once-only claim any thread can make, for logging a failure once from the GPU's completions: a reference to an
/// atomic, so a completion closure can hold it.
final class OnceFlag: Sendable {
    private let claimed = Atomic<Bool>(false)

    /// True for the first caller only.
    func claim() -> Bool { !claimed.exchange(true, ordering: .relaxed) }
}
