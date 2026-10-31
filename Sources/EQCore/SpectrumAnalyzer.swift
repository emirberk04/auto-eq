import Accelerate
import Foundation

/// Hann-windowed FFT reduced to bands (log-spaced 20 Hz – 20 kHz by default, or given edges).
/// Not real-time: runs on the UI / analysis side on samples copied out of a `SampleRing`.
///
/// Band level = power in the band's bins, corrected for the Hann window's noise bandwidth, so a
/// full-scale sine reads 0 dBFS in its band and broadband noise reads its in-band power.
public final class SpectrumAnalyzer {
    public let size: Int
    public let bandCount: Int
    /// Band centre frequencies (Hz): geometric mean of each band's edges.
    public let centers: [Double]
    /// bandCount + 1 ascending band edges (Hz).
    public let edges: [Double]

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]

    public static let minFrequency = 20.0
    public static let maxFrequency = 20_000.0
    /// Equivalent noise bandwidth of the Hann window, in bins.
    private static let hannENBW: Float = 1.5

    public convenience init(size: Int = 4096, bandCount: Int = 96) {
        let ratio = Self.maxFrequency / Self.minFrequency
        self.init(size: size, edges: (0...bandCount).map { Self.minFrequency * pow(ratio, Double($0) / Double(bandCount)) })
    }

    public init(size: Int, edges: [Double]) {
        precondition(size > 0 && size & (size - 1) == 0)
        precondition(edges.count >= 2)
        self.size = size
        self.edges = edges
        bandCount = edges.count - 1
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        windowed = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
        power = [Float](repeating: 0, count: size / 2)
        centers = (0..<edges.count - 1).map { (edges[$0] * edges[$0 + 1]).squareRoot() }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// `samples` must hold `size` values. Returns `bandCount` levels in dBFS (floor −140).
    public func analyze(_ samples: UnsafePointer<Float>, sampleRate: Double) -> [Float] {
        bandPowers(samples, sampleRate: sampleRate).map { Float(max(-140, 10 * log10(max($0, 1e-14)))) }
    }

    /// Linear band powers, scaled so a sine of amplitude 1 gives 1 in its band (0 dBFS).
    public func bandPowers(_ samples: UnsafePointer<Float>, sampleRate: Double) -> [Double] {
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBytes {
                    vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(size / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                im[0] = 0 // packed Nyquist; drop it with DC
                re[0] = 0
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size / 2))
            }
        }
        // zrip output is 2× the DFT; a sine of amplitude A has |DFT peak| = A·N/4 with Hann.
        // Scale so that sum over the main lobe / ENBW = A² / 1 → 0 dBFS for A = 1.
        let norm = Double(size * size) / 4 * Double(Self.hannENBW) // (2·N/4)² · ENBW
        let binHz = sampleRate / Double(size)
        var powers = [Double](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            var first = Int((edges[b] / binHz).rounded(.up))
            var last = Int((edges[b + 1] / binHz).rounded(.down))
            if first > last { // band narrower than a bin: use the nearest bin
                first = Int((centers[b] / binHz).rounded())
                last = first
            }
            first = max(first, 1)
            last = min(last, size / 2 - 1)
            guard first <= last else { continue }
            var sum: Float = 0
            for k in first...last { sum += power[k] }
            powers[b] = Double(sum) / norm
        }
        return powers
    }
}
