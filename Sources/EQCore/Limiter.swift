import Foundation

/// Stereo-linked look-ahead peak limiter. IO thread only; all memory allocated up front.
///
/// The required gain per sample (ceiling / peak) goes through a sliding-window minimum over
/// the look-ahead, a release smoother that can only lower it, and a box average as long as
/// the look-ahead. Because the signal is delayed by the look-ahead, the averaged gain has
/// fully reached each peak's requirement when that peak is output: no overs, no hard clip.
///
/// The bypass ("dry") signal travels through the same delay but is never gain-reduced, so
/// bypass stays bit-exact apart from the constant delay.
public final class LookaheadLimiter {
    public static let maxSampleRate = 384_000.0
    public static let lookaheadSeconds = 0.002
    public static let releaseSeconds = 0.1

    public let ceiling: Double
    private let capacity: Int

    private var lookahead = 1
    private var releaseCoef = 0.0

    // Delay lines (index: position * 2 + channel).
    private let wetDelay: UnsafeMutablePointer<Double>
    private let dryDelay: UnsafeMutablePointer<Double>
    private var pos = 0

    // Monotonic deque for the sliding minimum.
    private let dequeIndex: UnsafeMutablePointer<Int>
    private let dequeValue: UnsafeMutablePointer<Double>
    private var head = 0, count = 0
    private var n = 0

    // Box average.
    private let boxValues: UnsafeMutablePointer<Double>
    private var boxPos = 0
    private var boxSum = 0.0
    private var released = 1.0

    /// Gain applied to the last wet sample (1 = idle).
    public private(set) var gain = 1.0

    public init(ceilingDb: Double = -0.5) {
        ceiling = pow(10, ceilingDb / 20)
        capacity = Int(Self.maxSampleRate * Self.lookaheadSeconds) + 2
        wetDelay = .allocate(capacity: capacity * 2)
        dryDelay = .allocate(capacity: capacity * 2)
        dequeIndex = .allocate(capacity: capacity + 1)
        dequeValue = .allocate(capacity: capacity + 1)
        boxValues = .allocate(capacity: capacity)
        prepare(sampleRate: 48_000)
    }

    deinit {
        [wetDelay, dryDelay, dequeValue, boxValues].forEach { $0.deallocate() }
        dequeIndex.deallocate()
    }

    /// Delay in frames introduced for both paths.
    public var latencyFrames: Int { lookahead }

    public func prepare(sampleRate: Double) {
        lookahead = max(1, min(capacity - 2, Int((sampleRate * Self.lookaheadSeconds).rounded())))
        releaseCoef = 1 - exp(-1 / (Self.releaseSeconds * sampleRate))
        wetDelay.initialize(repeating: 0, count: capacity * 2)
        dryDelay.initialize(repeating: 0, count: capacity * 2)
        boxValues.initialize(repeating: 1, count: capacity)
        pos = 0; head = 0; count = 0; n = 0; boxPos = 0
        boxSum = Double(lookahead)
        released = 1
        gain = 1
    }

    /// Pushes one stereo frame, returns the delayed, limited wet frame and the delayed dry frame.
    @inline(__always)
    public func process(wetL: Double, wetR: Double, dryL: Double, dryR: Double)
        -> (wetL: Double, wetR: Double, dryL: Double, dryR: Double)
    {
        let peak = max(abs(wetL), abs(wetR))
        let required = peak > ceiling ? ceiling / peak : 1

        // Sliding minimum over the last lookahead + 1 required gains.
        let window = lookahead + 1
        let cap = capacity + 1
        while count > 0 && dequeValue[(head + count - 1) % cap] >= required { count -= 1 }
        dequeIndex[(head + count) % cap] = n
        dequeValue[(head + count) % cap] = required
        count += 1
        while dequeIndex[head] <= n - window { head = (head + 1) % cap; count -= 1 }
        let windowMin = dequeValue[head]
        n &+= 1

        // Release: rise slowly towards 1, but never above the window minimum.
        released = min(windowMin, released + (1 - released) * releaseCoef)

        // Box average over `lookahead` samples.
        boxSum += released - boxValues[boxPos]
        boxValues[boxPos] = released
        boxPos = boxPos + 1 == lookahead ? 0 : boxPos + 1
        gain = min(1, boxSum / Double(lookahead))

        // Delay lines.
        let i = pos * 2
        let out = (wetDelay[i] * gain, wetDelay[i + 1] * gain, dryDelay[i], dryDelay[i + 1])
        wetDelay[i] = wetL; wetDelay[i + 1] = wetR
        dryDelay[i] = dryL; dryDelay[i + 1] = dryR
        pos = pos + 1 == lookahead ? 0 : pos + 1
        return out
    }
}
