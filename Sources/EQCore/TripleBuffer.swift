import Synchronization

/// Lock-free single-writer / single-reader hand-off of a fixed-size value.
///
/// Three slots: the writer owns one ("back"), the reader owns one ("front"), the third sits
/// in the middle. Publishing and taking are a single atomic exchange of the middle index,
/// so neither side ever waits or sees a half-written value. The reader always gets the
/// latest published value; intermediate ones may be skipped.
public final class TripleBuffer<T: BitwiseCopyable>: @unchecked Sendable {
    private static var dirty: Int { 4 }

    private let slots: UnsafeMutablePointer<T>
    private let middle: Atomic<Int>
    private var back = 0   // writer only
    private var front = 2  // reader only

    public init(_ initial: T) {
        slots = .allocate(capacity: 3)
        slots.initialize(repeating: initial, count: 3)
        middle = Atomic(1)
    }

    deinit { slots.deallocate() }

    /// Writer side (control thread).
    public func publish(_ value: T) {
        slots[back] = value
        let old = middle.exchange(back | Self.dirty, ordering: .acquiringAndReleasing)
        back = old & 3
    }

    /// Reader side (IO thread). Returns the newest value if one was published since the last
    /// call, otherwise nil. No allocation, no locks.
    public func take() -> UnsafePointer<T>? {
        guard middle.load(ordering: .relaxed) & Self.dirty != 0 else { return nil }
        let old = middle.exchange(front, ordering: .acquiringAndReleasing)
        front = old & 3
        return UnsafePointer(slots + front)
    }

    /// Reader side: the value currently held by the reader.
    public var current: UnsafePointer<T> { UnsafePointer(slots + front) }
}
