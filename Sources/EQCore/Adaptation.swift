import Foundation

/// L3 (CLAUDE.md §5.4): what the track's tonal balance asks for, before strength and clamps.
public struct AdaptiveCorrection: Sendable, Equatable, Codable {
    /// Fixed broad filters; only their gains adapt, so the kernel only ever smooths gains.
    public static let filters: [(type: Profile.Filter.Kind, frequency: Double, q: Double)] = [
        (.lowShelf, 90, 0.7), (.peaking, 250, 0.7), (.peaking, 600, 0.7),
        (.peaking, 1400, 0.7), (.peaking, 3000, 0.7), (.highShelf, 6500, 0.7),
    ]

    /// Full correction per filter (dB) towards the target slope. `EQDesign` scales it by the
    /// adaptation strength and clamps each band to ±2 dB.
    public var gains = [Double](repeating: 0, count: Self.filters.count)
    /// 0…0.5: how much of L0's presence boost (2.5–5.5 kHz) a bright track would remove at full
    /// adaptation (S12 Ultra rule, a hypothesis to verify by ear).
    public var presenceReduction = 0.0

    public init() {}
    public init(gains: [Double], presenceReduction: Double) {
        self.gains = gains
        self.presenceReduction = presenceReduction
    }

    public var isNeutral: Bool { gains.allSatisfy { $0 == 0 } && presenceReduction == 0 }
}

public enum AdaptiveFit {
    /// Target LTAS slope, PSD dB/octave (typical pop master; HoRNet BalancEQ uses the same).
    public static let targetSlope = -4.5
    /// The fit is computed on the full difference; this only stops absurd values on odd input.
    static let maxFullGainDb = 12.0
    static let ridge = 0.5

    /// The default target shape: a straight −4.5 dB/octave line (PSD dB per band).
    public static let defaultTarget: [Double] = ThirdOctave.centers.map { targetSlope * log2($0 / 1000) }

    /// Minimum analysed tracks before the listener's library average replaces the default target.
    public static let minLibraryTracks = 8

    /// The average tonal shape of the analysed tracks (each track's level removed first), or nil
    /// with too few tracks. Used as L3's target: tracks are pulled towards what this listener
    /// usually hears, so only outliers (too bright, too dark, thin, boomy) get corrected.
    public static func libraryTarget(_ tracks: [TrackFeatures]) -> [Double]? {
        guard tracks.count >= minLibraryTracks else { return nil }
        var sum = [Double](repeating: 0, count: ThirdOctave.centers.count)
        for t in tracks {
            let psd = t.psdDb
            let mean = zip(psd, weights).map { $0 * $1 }.reduce(0, +) / weights.reduce(0, +)
            for i in sum.indices { sum[i] += psd[i] - mean }
        }
        return sum.map { $0 / Double(tracks.count) }
    }

    /// Target minus track (PSD dB per third-octave band) with the level difference removed,
    /// smoothed across neighbouring bands. Positive: the track lacks energy there.
    public static func difference(_ features: TrackFeatures, target: [Double]? = nil) -> [Double] {
        let psd = features.psdDb
        let t = target ?? defaultTarget
        let w = weights
        // Level: weighted mean of (psd − target).
        let offset = zip(zip(psd, t), w).map { ($0.0 - $0.1) * $1 }.reduce(0, +) / w.reduce(0, +)
        let raw = zip(psd, t).map { offset + $0.1 - $0.0 }
        return raw.indices.map { i in
            let a = raw[max(0, i - 1)], b = raw[i], c = raw[min(raw.count - 1, i + 1)]
            return 0.25 * a + 0.5 * b + 0.25 * c
        }
    }

    /// Bands outside 50 Hz – 10 kHz count half: least reliable (low-frequency seal, coupler
    /// limits, CLAUDE.md §2).
    static let weights: [Double] = ThirdOctave.centers.map { $0 < 50 || $0 > 10_500 ? 0.5 : 1 }

    /// Filter responses at 1 dB gain, sampled at the band centres: [band][filter].
    static let basis: [[Double]] = {
        let fs = 48_000.0
        let coefficients = AdaptiveCorrection.filters.map {
            BiquadCoefficients($0.type, frequency: $0.frequency, q: $0.q, gainDb: 1, sampleRate: fs)
        }
        return ThirdOctave.centers.map { f in coefficients.map { $0.magnitudeDb(at: f, sampleRate: fs) } }
    }()

    public static func correction(for features: TrackFeatures, target: [Double]? = nil) -> AdaptiveCorrection {
        let d = difference(features, target: target)
        let n = AdaptiveCorrection.filters.count
        // Ridge-regularised weighted least squares: (BᵀWB + λI) g = BᵀWd.
        var a = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        var b = [Double](repeating: 0, count: n)
        for (i, row) in basis.enumerated() {
            for j in 0..<n {
                b[j] += weights[i] * row[j] * d[i]
                for k in 0..<n { a[j][k] += weights[i] * row[j] * row[k] }
            }
        }
        for j in 0..<n { a[j][j] += ridge }
        let gains = solve(a, b).map { min(max($0, -maxFullGainDb), maxFullGainDb) }

        // Presence: how far the track sits above the target line at 3.15–5 kHz.
        let presence = ThirdOctave.centers.indices.filter { (3000...5100).contains(ThirdOctave.centers[$0]) }
        let excess = -presence.map { d[$0] }.reduce(0, +) / Double(presence.count)
        let reduction = 0.5 * min(max(excess / 4, 0), 1)
        return AdaptiveCorrection(gains: gains, presenceReduction: reduction)
    }

    /// Gaussian elimination with partial pivoting (small, well-conditioned systems).
    static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double] {
        var m = matrix, v = rhs
        let n = v.count
        for col in 0..<n {
            let pivot = (col..<n).max { abs(m[$0][col]) < abs(m[$1][col]) }!
            m.swapAt(col, pivot); v.swapAt(col, pivot)
            guard abs(m[col][col]) > 1e-12 else { continue }
            for row in (col + 1)..<n {
                let f = m[row][col] / m[col][col]
                for k in col..<n { m[row][k] -= f * m[col][k] }
                v[row] -= f * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = v[row]
            for k in (row + 1)..<n { sum -= m[row][k] * x[k] }
            x[row] = abs(m[row][row]) > 1e-12 ? sum / m[row][row] : 0
        }
        return x
    }
}

/// Moves the applied correction slowly towards what the current track asks for.
///
/// Time only advances while audio is playing. After a track change the correction is held for
/// the first 10 s of audio (or moves towards a cached measurement of the track at once), then
/// follows the track's growing LTAS. Moving away from flat uses the attack time constant,
/// moving back towards flat the (slower) release.
public struct AdaptationController: Sendable {
    public enum Phase: String, Sendable { case learning, cached, adapting }

    public static let freezeSeconds = 10.0
    public static let attackSeconds = 10.0
    public static let releaseSeconds = 20.0

    public private(set) var current = AdaptiveCorrection()
    public private(set) var goal: AdaptiveCorrection?
    public private(set) var phase = Phase.learning
    /// Target shape (see `AdaptiveFit.libraryTarget`); nil = the default −4.5 dB/octave line.
    public var target: [Double]?

    public init() {}

    /// New track: keep the current correction; aim at the cached one if the track is known.
    public mutating func trackChanged(cached: TrackFeatures?) {
        if let cached, cached.seconds >= Self.freezeSeconds {
            goal = AdaptiveFit.correction(for: cached, target: target)
            phase = .cached
        } else {
            goal = nil
            phase = .learning
        }
    }

    /// `features`: the track's LTAS so far (already merged with any cached measurement by the
    /// caller); `ownSeconds`: gated audio heard of this track in this play; `dt`: playing time
    /// since the last call.
    public mutating func update(features: TrackFeatures, ownSeconds: Double, dt: Double) {
        if ownSeconds >= Self.freezeSeconds {
            goal = AdaptiveFit.correction(for: features, target: target)
            phase = .adapting
        }
        guard let goal, dt > 0 else { return }
        current.gains = zip(current.gains, goal.gains).map { Self.step($0, $1, dt) }
        current.presenceReduction = Self.step(current.presenceReduction, goal.presenceReduction, dt)
    }

    static func step(_ value: Double, _ goal: Double, _ dt: Double) -> Double {
        let away = abs(goal) > abs(value) && goal * value >= 0
        let tau = away ? attackSeconds : releaseSeconds
        let next = value + (goal - value) * (1 - exp(-dt / tau))
        return abs(next - goal) < 1e-4 ? goal : next
    }
}
