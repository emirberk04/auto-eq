import Foundation

/// Nominal 1/3-octave bands, 40 Hz – 12.5 kHz (CLAUDE.md §5.4 analysis range).
public enum ThirdOctave {
    public static let centers: [Double] = (-14...11).map { 1000 * pow(10, Double($0) / 10) }
    public static let edges: [Double] = centers.map { $0 * pow(10, -1.0 / 20) } + [centers.last! * pow(10, 1.0 / 20)]
    public static let bandwidths: [Double] = centers.indices.map { edges[$0 + 1] - edges[$0] }

    /// Band power → power spectral density in dB (per Hz). On this scale pink noise falls
    /// 3 dB/octave and typical pop masters ≈ 4.5 dB/octave.
    public static func psdDb(_ power: [Double]) -> [Double] {
        zip(power, bandwidths).map { 10 * log10(max($0 / $1, 1e-20)) }
    }

    /// Least-squares slope of `psdDb` against log2(f) between 100 Hz and 8 kHz, dB/octave.
    public static func tilt(_ psdDb: [Double]) -> Double {
        var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for (f, y) in zip(centers, psdDb) where f >= 99 && f <= 8100 {
            let x = log2(f / 1000)
            n += 1; sx += x; sy += y; sxx += x * x; sxy += x * y
        }
        return (n * sxy - sx * sy) / (n * sxx - sx * sx)
    }

    /// Fraction of power in the bands up to 100 Hz (35–112 Hz).
    public static func lowRatio(_ power: [Double]) -> Double {
        let total = power.reduce(0, +)
        guard total > 0 else { return 0 }
        return zip(centers, power).filter { $0.0 < 120 }.map(\.1).reduce(0, +) / total
    }

    public static func centroid(_ power: [Double]) -> Double {
        let total = power.reduce(0, +)
        guard total > 0 else { return 0 }
        return zip(centers, power).map { $0 * $1 }.reduce(0, +) / total
    }
}

/// Long-term features of what is playing now. Derived numbers only; no audio is kept.
public struct TrackFeatures: Sendable, Codable, Equatable {
    /// Mean 1/3-octave band power over the gated part of the track (L and R averaged).
    public var ltasPower = [Double](repeating: 0, count: ThirdOctave.centers.count)
    /// Gated audio seconds behind `ltasPower`.
    public var seconds = 0.0
    public var integratedLufs = -Double.infinity
    public var shortTermLufs = -Double.infinity
    /// Peak-to-RMS over the last 3 s, dB.
    public var crestDb = 0.0
    /// Track sample peak minus integrated loudness, dB.
    public var plrDb = 0.0
    /// Side share of total power: 0 = mono, 0.5 = uncorrelated, 1 = out of phase.
    public var width = 0.0

    public init() {}

    public var psdDb: [Double] { ThirdOctave.psdDb(ltasPower) }
    public var tiltDbPerOctave: Double { ThirdOctave.tilt(psdDb) }
    public var lowRatio: Double { ThirdOctave.lowRatio(ltasPower) }
    public var centroidHz: Double { ThirdOctave.centroid(ltasPower) }
}

/// Turns the pre-EQ mid/side stream into `TrackFeatures` and notices track changes from the
/// audio alone (silence gap, or a lasting spectral change). Analysis side, one thread.
public final class TrackAnalyzer {
    public enum ChangeReason: String, Sendable { case silenceGap, novelty, external }

    public let sampleRate: Double
    /// Off when a reliable metadata source reports track changes instead.
    public var detectsChanges = true

    /// Short-term loudness below which audio is ignored (CLAUDE.md §5.4).
    public static let gateLufs = -50.0
    static let silenceLufs = -60.0
    static let minGapSeconds = 0.5
    static let minTrackSecondsForGap = 15.0
    static let noveltyThresholdDb = 6.0
    static let noveltyHoldSeconds = 6.0
    static let minTrackSecondsForNovelty = 30.0
    static let recentSeconds = 3.0

    private var meter: LoudnessMeter
    private let fft: SpectrumAnalyzer
    private let hop: Int
    private var mid: [Float], side: [Float]
    private var fill = 0

    private var ltasSum = [Double](repeating: 0, count: ThirdOctave.centers.count)
    private var midPowerSum = 0.0, sidePowerSum = 0.0
    private var gatedHops = 0
    private var recent: [Double]?
    private var noveltySeconds = 0.0
    private var gapSeconds = 0.0
    private var secondsSinceChange = 0.0
    public private(set) var lastNoveltyDb = 0.0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        meter = LoudnessMeter(sampleRate: sampleRate)
        // ≈ 6 Hz bins, so the 40 Hz third-octave band (9 Hz wide) still gets its own bin.
        let size = sampleRate <= 50_000 ? 8192 : sampleRate <= 100_000 ? 16384 : 32768
        fft = SpectrumAnalyzer(size: size, edges: ThirdOctave.edges)
        hop = size / 2
        mid = [Float](repeating: 0, count: size)
        side = [Float](repeating: 0, count: size)
    }

    private var hopSeconds: Double { Double(hop) / sampleRate }
    public var gatedSeconds: Double { Double(gatedHops) * hopSeconds }
    /// Something audible is playing (short-term loudness above the gate).
    public var isActive: Bool { meter.shortTerm > Self.gateLufs }

    /// Carries the current track's accumulation over to a new analyzer (sample-rate change).
    public func adopt(_ other: TrackAnalyzer) {
        ltasSum = other.ltasSum
        midPowerSum = other.midPowerSum
        sidePowerSum = other.sidePowerSum
        gatedHops = Int((other.gatedSeconds / hopSeconds).rounded())
        let scale = Double(gatedHops) / Double(max(other.gatedHops, 1))
        ltasSum = ltasSum.map { $0 * scale }
        midPowerSum *= scale; sidePowerSum *= scale
        secondsSinceChange = other.secondsSinceChange
        detectsChanges = other.detectsChanges
    }

    public func startNewTrack() {
        ltasSum = [Double](repeating: 0, count: ltasSum.count)
        midPowerSum = 0; sidePowerSum = 0
        gatedHops = 0
        recent = nil
        noveltySeconds = 0
        secondsSinceChange = 0
        meter.resetIntegrated()
    }

    public var features: TrackFeatures {
        var f = TrackFeatures()
        if gatedHops > 0 { f.ltasPower = ltasSum.map { $0 / Double(gatedHops) } }
        f.seconds = gatedSeconds
        f.integratedLufs = meter.integrated
        f.shortTermLufs = meter.shortTerm
        f.crestDb = meter.shortTermCrestDb
        if meter.peak > 0, f.integratedLufs.isFinite { f.plrDb = 20 * log10(meter.peak) - f.integratedLufs }
        let total = midPowerSum + sidePowerSum
        f.width = total > 0 ? sidePowerSum / total : 0
        return f
    }

    /// Feeds `count` new samples. Returns the reason if a track change was detected (the
    /// analyzer has already started the new track by then).
    public func process(mid m: UnsafePointer<Float>, side s: UnsafePointer<Float>, count: Int) -> ChangeReason? {
        var change: ChangeReason?
        for i in 0..<count {
            if meter.process(mid: Double(m[i]), side: Double(s[i])), let reason = blockDone() {
                change = change ?? reason
            }
            mid[fill] = m[i]
            side[fill] = s[i]
            fill += 1
            if fill == mid.count {
                if let reason = hopDone() { change = change ?? reason }
                // Keep the second half: 50 % overlap.
                for j in 0..<hop { mid[j] = mid[j + hop]; side[j] = side[j + hop] }
                fill = hop
            }
        }
        return change
    }

    /// Every 100 ms: silence-gap detection.
    private func blockDone() -> ChangeReason? {
        secondsSinceChange += 0.1
        let m = meter.momentary
        if m < Self.silenceLufs {
            gapSeconds += 0.1
        } else if m > Self.gateLufs {
            defer { gapSeconds = 0 }
            if detectsChanges, gapSeconds >= Self.minGapSeconds, gatedSeconds >= Self.minTrackSecondsForGap {
                startNewTrack()
                return .silenceGap
            }
        }
        return nil
    }

    /// Every hop: LTAS accumulation and novelty detection.
    private func hopDone() -> ChangeReason? {
        guard meter.shortTerm > Self.gateLufs else { noveltySeconds = 0; return nil }
        let pm = mid.withUnsafeBufferPointer { fft.bandPowers($0.baseAddress!, sampleRate: sampleRate) }
        let ps = side.withUnsafeBufferPointer { fft.bandPowers($0.baseAddress!, sampleRate: sampleRate) }
        // (|M|² + |S|²) = (|L|² + |R|²) / 2: the mean of the two channels' spectra.
        let bands = zip(pm, ps).map { $0 + $1 }
        for i in bands.indices { ltasSum[i] += bands[i] }
        midPowerSum += pm.reduce(0, +)
        sidePowerSum += ps.reduce(0, +)
        gatedHops += 1

        // Recent shape: averaged in dB, so a quiet new spectrum replaces a loud old one as fast
        // as the reverse (a power average would hold on to the old peaks for many seconds).
        let alpha = 1 - exp(-hopSeconds / Self.recentSeconds)
        let bandsDb = bands.map { 10 * log10(max($0, 1e-20)) }
        if let old = recent {
            recent = zip(old, bandsDb).map { $0 + ($1 - $0) * alpha }
        } else {
            recent = bandsDb
        }
        guard detectsChanges, let recent, gatedSeconds >= Self.minTrackSecondsForNovelty,
              secondsSinceChange >= Self.minTrackSecondsForNovelty else {
            noveltySeconds = 0
            return nil
        }
        lastNoveltyDb = Self.shapeDistanceDb(recent, ltasSum.map { 10 * log10(max($0, 1e-20)) })
        noveltySeconds = lastNoveltyDb > Self.noveltyThresholdDb ? noveltySeconds + hopSeconds : 0
        if noveltySeconds >= Self.noveltyHoldSeconds {
            startNewTrack()
            return .novelty
        }
        return nil
    }

    /// RMS difference of two band spectra's shapes (dB, level removed), 63 Hz – 10 kHz.
    static func shapeDistanceDb(_ a: [Double], _ b: [Double]) -> Double {
        let idx = ThirdOctave.centers.indices.filter { ThirdOctave.centers[$0] >= 60 && ThirdOctave.centers[$0] <= 10_500 }
        let diff = idx.map { a[$0] - b[$0] }
        let mean = diff.reduce(0, +) / Double(diff.count)
        return (diff.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(diff.count)).squareRoot()
    }
}
