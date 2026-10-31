import Synchronization

/// Single-writer (IO thread) / single-reader (analysis) mono sample history. Lock-free.
///
/// The writer pushes samples into a power-of-two ring and publishes the running total once
/// per callback. The reader copies the most recent N samples. The writer never waits; if the
/// reader were slow enough to be lapped it would get mixed samples, which for analysis
/// (N ≪ capacity) is harmless.
public final class SampleRing: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private var cursor = 0 // writer only

    public init(capacity: Int = 1 << 16) {
        precondition(capacity > 0 && capacity & (capacity - 1) == 0, "capacity must be a power of two")
        self.capacity = capacity
        mask = capacity - 1
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit { buffer.deallocate() }

    /// IO thread. Not visible to the reader until `commit()`.
    @inline(__always)
    public func push(_ value: Float) {
        buffer[cursor & mask] = value
        cursor &+= 1
    }

    /// IO thread, once per callback.
    public func commit() {
        written.store(cursor, ordering: .releasing)
    }

    /// Total samples published so far.
    public var totalWritten: Int { written.load(ordering: .acquiring) }

    /// Reader: copies the latest `count` samples (oldest first). Returns false until enough exist.
    public func copyLatest(_ count: Int, into destination: UnsafeMutablePointer<Float>) -> Bool {
        let end = written.load(ordering: .acquiring)
        guard count <= capacity / 2, end >= count else { return false }
        for i in 0..<count { destination[i] = buffer[(end - count + i) & mask] }
        return true
    }

    /// Reader: copies samples `start ..< start + count` (absolute positions, see `totalWritten`).
    /// Returns false if they are not all published yet or the writer may have overwritten them.
    public func copy(from start: Int, count: Int, into destination: UnsafeMutablePointer<Float>) -> Bool {
        let end = written.load(ordering: .acquiring)
        guard start >= 0, start + count <= end, end - start <= capacity / 2 else { return false }
        for i in 0..<count { destination[i] = buffer[(start + i) & mask] }
        // The writer keeps going during the copy; it must not have reached our oldest sample.
        return written.load(ordering: .acquiring) - start <= capacity - 1024
    }
}
