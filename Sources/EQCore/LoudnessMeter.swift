import Foundation

/// ITU-R BS.1770-4 loudness for a stereo pair: K-weighting, 100 ms blocks, momentary (400 ms),
/// short-term (3 s) and gated integrated loudness. Not real-time: analysis side only.
///
/// Integrated loudness keeps a 0.1 LU histogram of the 400 ms block powers instead of every
/// block, so memory stays fixed however long a track plays.
public struct LoudnessMeter {
    public let sampleRate: Double
    private var shelf: BiquadCoefficients
    private var highPass: BiquadCoefficients
    /// TDF-II state: [stage][channel][z1, z2].
    private var z = [Double](repeating: 0, count: 8)

    private let blockLength: Int
    private var blockFill = 0
    private var blockSum = 0.0        // K-weighted L² + R²
    private var blockRawSum = 0.0     // unweighted, for crest factor
    private var blockPeak = 0.0
    /// Last 30 blocks (3 s), newest last.
    private var blocks: [Double] = []
    private var rawBlocks: [Double] = []
    private var peakBlocks: [Double] = []

    private static let histogramFloor = -70.0
    private static let histogramStep = 0.1
    private var histogramCount = [Int](repeating: 0, count: 800)   // −70 … +10 LUFS
    private var histogramPower = [Double](repeating: 0, count: 800)

    /// Highest sample peak since `resetIntegrated()`, linear.
    public private(set) var peak = 0.0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        (shelf, highPass) = Self.kWeighting(sampleRate: sampleRate)
        blockLength = max(1, Int((sampleRate * 0.1).rounded()))
    }

    /// The two K-weighting stages for any sample rate (same analog prototype as BS.1770's 48 kHz
    /// coefficients; formulation as in pyloudnorm).
    static func kWeighting(sampleRate fs: Double) -> (BiquadCoefficients, BiquadCoefficients) {
        let g = 3.999843853973347, q1 = 0.7071752369554196, f1 = 1681.974450955533
        var k = tan(Double.pi * f1 / fs)
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q1 + k * k
        let shelf = BiquadCoefficients(b0: (vh + vb * k / q1 + k * k) / a0, b1: 2 * (k * k - vh) / a0,
                                       b2: (vh - vb * k / q1 + k * k) / a0,
                                       a1: 2 * (k * k - 1) / a0, a2: (1 - k / q1 + k * k) / a0)
        let q2 = 0.5003270373238773, f2 = 38.13547087602444
        k = tan(Double.pi * f2 / fs)
        a0 = 1 + k / q2 + k * k
        let highPass = BiquadCoefficients(b0: 1, b1: -2, b2: 1,
                                          a1: 2 * (k * k - 1) / a0, a2: (1 - k / q2 + k * k) / a0)
        return (shelf, highPass)
    }

    @inline(__always)
    private mutating func filter(_ x: Double, channel: Int) -> Double {
        let y = Self.step(shelf, x, &z, (0 * 2 + channel) * 2)
        return Self.step(highPass, y, &z, (1 * 2 + channel) * 2)
    }

    @inline(__always)
    private static func step(_ c: BiquadCoefficients, _ x: Double, _ z: inout [Double], _ i: Int) -> Double {
        let y = c.b0 * x + z[i]
        z[i] = c.b1 * x - c.a1 * y + z[i + 1]
        z[i + 1] = c.b2 * x - c.a2 * y
        return y
    }

    /// Feeds mid (L+R)/2 and side (L−R)/2 samples. Returns true each time a 100 ms block completes.
    @discardableResult
    public mutating func process(mid: Double, side: Double) -> Bool {
        let l = mid + side, r = mid - side
        let kl = filter(l, channel: 0), kr = filter(r, channel: 1)
        blockSum += kl * kl + kr * kr
        blockRawSum += (l * l + r * r) * 0.5
        blockPeak = max(blockPeak, abs(l), abs(r))
        blockFill += 1
        guard blockFill == blockLength else { return false }

        let n = Double(blockLength)
        Self.append(blockSum / n, to: &blocks)
        Self.append(blockRawSum / n, to: &rawBlocks)
        Self.append(blockPeak, to: &peakBlocks)
        peak = max(peak, blockPeak)
        blockSum = 0; blockRawSum = 0; blockPeak = 0; blockFill = 0
        // Flush denormals in the filter state.
        for i in z.indices where abs(z[i]) < 1e-30 { z[i] = 0 }

        // Gating block = momentary window (400 ms, 75 % overlap).
        if blocks.count >= 4 {
            let power = momentaryPower
            let lufs = Self.lufs(power)
            if lufs > Self.histogramFloor {
                let bin = min(histogramCount.count - 1, Int((lufs - Self.histogramFloor) / Self.histogramStep))
                histogramCount[bin] += 1
                histogramPower[bin] += power
            }
        }
        return true
    }

    private static func append(_ value: Double, to array: inout [Double]) {
        if array.count == 30 { array.removeFirst() }
        array.append(value)
    }

    private var momentaryPower: Double { blocks.suffix(4).reduce(0, +) / Double(min(4, blocks.count)) }

    static func lufs(_ power: Double) -> Double { power > 0 ? -0.691 + 10 * log10(power) : -.infinity }

    /// 400 ms loudness (LUFS); −∞ for silence.
    public var momentary: Double { blocks.isEmpty ? -.infinity : Self.lufs(momentaryPower) }
    /// 3 s loudness (LUFS) over the blocks seen so far.
    public var shortTerm: Double { blocks.isEmpty ? -.infinity : Self.lufs(blocks.reduce(0, +) / Double(blocks.count)) }

    /// Gated integrated loudness since `resetIntegrated()` (−70 LUFS absolute, −10 LU relative gate).
    public var integrated: Double {
        var count = 0, power = 0.0
        for i in histogramCount.indices { count += histogramCount[i]; power += histogramPower[i] }
        guard count > 0 else { return -.infinity }
        let threshold = Self.lufs(power / Double(count)) - 10
        count = 0; power = 0
        for i in histogramCount.indices
        where Self.histogramFloor + (Double(i) + 1) * Self.histogramStep > threshold {
            count += histogramCount[i]; power += histogramPower[i]
        }
        return count > 0 ? Self.lufs(power / Double(count)) : -.infinity
    }

    /// Peak-to-RMS ratio over the last 3 s, dB (unweighted).
    public var shortTermCrestDb: Double {
        let ms = rawBlocks.reduce(0, +) / Double(max(1, rawBlocks.count))
        let p = peakBlocks.max() ?? 0
        return ms > 0 && p > 0 ? 20 * log10(p) - 10 * log10(ms) : 0
    }

    /// Starts a new integrated measurement (new track). Momentary / short-term keep running.
    public mutating func resetIntegrated() {
        histogramCount = [Int](repeating: 0, count: histogramCount.count)
        histogramPower = [Double](repeating: 0, count: histogramPower.count)
        peak = 0
    }
}
