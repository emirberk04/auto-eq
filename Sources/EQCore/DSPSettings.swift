import Foundation

/// Everything the IO thread needs, as one fixed-size value (no references, no arrays) so it
/// can cross threads through a `TripleBuffer`.
public struct DSPSettings: Sendable, BitwiseCopyable {
    public static let maxBands = 20

    public var bandCount = 0
    // Fixed storage for up to 20 bands; use `band(_:)` / `setBand(_:_:)`.
    private var storage: (
        BandParameters, BandParameters, BandParameters, BandParameters,
        BandParameters, BandParameters, BandParameters, BandParameters,
        BandParameters, BandParameters, BandParameters, BandParameters,
        BandParameters, BandParameters, BandParameters, BandParameters,
        BandParameters, BandParameters, BandParameters, BandParameters
    ) = (.flat, .flat, .flat, .flat, .flat, .flat, .flat, .flat, .flat, .flat,
         .flat, .flat, .flat, .flat, .flat, .flat, .flat, .flat, .flat, .flat)

    /// Gain applied to the EQ path (negative: headroom for the boosts).
    public var preampDb = 0.0
    /// Gain applied to the bypass path (level-matched A/B), never positive.
    public var dryGainDb = 0.0
    /// true: EQ path audible; false: bypass path. Switching cross-fades over 50 ms.
    public var eqEnabled = true

    public init() {}

    public func band(_ i: Int) -> BandParameters {
        precondition(i < Self.maxBands)
        return withUnsafeBytes(of: storage) { $0.load(fromByteOffset: i * MemoryLayout<BandParameters>.stride, as: BandParameters.self) }
    }

    public mutating func setBand(_ i: Int, _ band: BandParameters) {
        precondition(i < Self.maxBands)
        withUnsafeMutableBytes(of: &storage) {
            $0.storeBytes(of: band, toByteOffset: i * MemoryLayout<BandParameters>.stride, as: BandParameters.self)
        }
    }

    public var bands: [BandParameters] { (0..<bandCount).map(band) }
}

extension BandParameters {
    static let flat = BandParameters(type: .peaking, frequency: 1000, q: 0.7, gainDb: 0)
}

/// Turns user-level choices (profile, strength, toggles) into `DSPSettings`. Control thread only.
public struct EQDesign: Sendable {
    /// Base tone. `.natural` keeps the S12 Ultra's own tuning (L0 bands stay in the chain at 0 dB,
    /// so switching tone glides instead of resetting filters); `.harman` applies the profile.
    public enum Tone: String, Sendable, CaseIterable { case natural, harman }

    public var profile: Profile
    public var tone = Tone.harman
    /// 0...1, scales every L0 gain (Harman tone only).
    public var strength: Double
    public var eqEnabled = true
    public var levelMatch = true
    /// L1 personal preference (CLAUDE.md §5.2): low shelf at 100 Hz, high shelf at 8 kHz.
    public var bassDb = 0.0 {
        didSet { bassDb = min(max(bassDb, Self.bassRange.lowerBound), Self.bassRange.upperBound) }
    }
    public var trebleDb = 0.0 {
        didSet { trebleDb = min(max(trebleDb, Self.trebleRange.lowerBound), Self.trebleRange.upperBound) }
    }
    /// L3 track adaptation (CLAUDE.md §5.4). `adaptive` comes from `AdaptationController`.
    public var adaptEnabled = true
    public var adaptStrength = Self.defaultAdaptStrength {
        didSet { adaptStrength = min(max(adaptStrength, 0), 1) }
    }
    public var adaptive = AdaptiveCorrection()
    /// L2 (CLAUDE.md §5.3): output volume minus the reference volume, dB; nil when the device
    /// volume cannot be read (then L2 stays off).
    public var loudnessCompensation = false
    public var listeningOffsetDb: Double?

    public static let bassRange = -3.0...6.0
    public static let trebleRange = -3.0...3.0
    public static let bassShelf = (frequency: 100.0, q: 0.7)
    public static let trebleShelf = (frequency: 8000.0, q: 0.7)
    public static let defaultAdaptStrength = 0.3
    public static let maxAdaptiveGainDb = 2.0
    /// L0 bands boosting in this range are scaled down for bright tracks.
    public static let presenceRange = 2500.0...5500.0
    /// L2 assumes the reference volume plays at about mastering level.
    public static let referencePhon = 83.0
    public static let loudnessBassShelf = (frequency: 150.0, q: 0.5)
    public static let loudnessTrebleShelf = (frequency: 10_000.0, q: 0.7)
    public static let maxLoudnessBassDb = 6.0
    public static let maxLoudnessTrebleDb = 3.0
    static let fixedBandCount = 2 + 2 + AdaptiveCorrection.filters.count // L1, L2, L3

    public static let headroomDb = 0.5
    /// Decoded/resampled Music.app output regularly peaks above 0 dBFS (measured +1.2 dBFS on a
    /// loud master: AAC and 48→96 kHz inter-sample overs). Without this margin the limiter
    /// would work on such tracks all the time.
    public static let sourceOverHeadroomDb = 1.5
    public static let maxTotalBoostDb = 10.0
    /// Extra headroom held whenever L3 may act (enabled or not, so its A/B stays level-matched),
    /// so L3 boosts rarely push the preamp down. Not held at adaptation strength 0.
    public static let adaptiveReserveDb = 1.0

    public init(profile: Profile, strength: Double? = nil) {
        self.profile = profile
        self.strength = strength ?? profile.defaultStrength
    }

    /// The applied L3 gains (strength-scaled, clamped), one per `AdaptiveCorrection.filters`.
    public var adaptiveGains: [Double] {
        adaptive.gains.map { adaptEnabled ? min(max($0 * adaptStrength, -Self.maxAdaptiveGainDb), Self.maxAdaptiveGainDb) : 0 }
    }

    /// Applied factor on L0's presence boost: 1 = untouched, 0.5 = halved. Full effect from the
    /// default adaptation strength upwards.
    public var presenceScale: Double {
        guard adaptEnabled else { return 1 }
        return 1 - adaptive.presenceReduction * min(1, adaptStrength / Self.defaultAdaptStrength)
    }

    /// L2 shelf gains (bass, treble) for the current listening offset; 0 at or above the reference.
    public var loudnessGains: (bass: Double, treble: Double) {
        guard loudnessCompensation, let offset = listeningOffsetDb, offset < 0 else { return (0, 0) }
        let phon = max(20, Self.referencePhon + offset)
        func comp(_ f: Double) -> Double {
            EqualLoudness.compensationDb(frequency: f, phon: phon, referencePhon: Self.referencePhon)
        }
        return (min(max(comp(40), 0), Self.maxLoudnessBassDb), min(max(comp(12_500), 0), Self.maxLoudnessTrebleDb))
    }

    private var adaptationIsNeutral: Bool {
        !adaptEnabled || adaptStrength == 0 || adaptive.isNeutral
    }

    /// L0 bands scaled by strength (and presence scale), the two L1 shelves, then the six L3
    /// bands. All always present, so the band count never changes and filter state is never
    /// reset. Then the +10 dB total-boost clamp.
    public func bands(sampleRate: Double) -> [BandParameters] {
        bands(sampleRate: sampleRate, adaptation: true)
    }

    func bands(sampleRate: Double, adaptation: Bool) -> [BandParameters] {
        let presence = adaptation ? presenceScale : 1
        let l0 = tone == .harman ? strength : 0
        var bands = profile.filters.prefix(DSPSettings.maxBands - Self.fixedBandCount).map {
            var gain = $0.gain * l0
            if $0.type == .peaking, Self.presenceRange.contains($0.frequency), gain > 0 { gain *= presence }
            return BandParameters(type: $0.type, frequency: $0.frequency, q: $0.q, gainDb: gain)
        }
        bands.append(BandParameters(type: .lowShelf, frequency: Self.bassShelf.frequency,
                                    q: Self.bassShelf.q, gainDb: bassDb))
        bands.append(BandParameters(type: .highShelf, frequency: Self.trebleShelf.frequency,
                                    q: Self.trebleShelf.q, gainDb: trebleDb))
        let loudness = loudnessGains
        bands.append(BandParameters(type: .lowShelf, frequency: Self.loudnessBassShelf.frequency,
                                    q: Self.loudnessBassShelf.q, gainDb: loudness.bass))
        bands.append(BandParameters(type: .highShelf, frequency: Self.loudnessTrebleShelf.frequency,
                                    q: Self.loudnessTrebleShelf.q, gainDb: loudness.treble))
        let l3 = adaptation ? adaptiveGains : [Double](repeating: 0, count: AdaptiveCorrection.filters.count)
        for (filter, gain) in zip(AdaptiveCorrection.filters, l3) {
            bands.append(BandParameters(type: filter.type, frequency: filter.frequency, q: filter.q, gainDb: gain))
        }
        let peak = Self.peakBoostDb(bands, sampleRate: sampleRate)
        if peak > Self.maxTotalBoostDb {
            let k = Self.maxTotalBoostDb / peak
            for i in bands.indices { bands[i].gainDb *= k }
        }
        return bands
    }

    public func settings(sampleRate: Double) -> DSPSettings {
        var s = DSPSettings()
        let bands = bands(sampleRate: sampleRate)
        s.bandCount = bands.count
        for (i, b) in bands.enumerated() { s.setBand(i, b) }
        let peak = Self.peakBoostDb(bands, sampleRate: sampleRate)
        // Nothing boosted (e.g. strength 0, flat L1): stay bit-transparent, overs pass as in bypass.
        s.preampDb = peak > 0.01 ? -(peak + Self.headroomDb + Self.sourceOverHeadroomDb) : 0
        if adaptStrength > 0 {
            // L3 changes balance, not level: the preamp is set from the bands without L3 (plus a
            // fixed reserve) and then compensates L3's loudness change. Only if L3's boosts
            // exceed the reserve does the preamp drop further, to keep the source-over margin.
            // The headroom is held even while L3 is still neutral (start of a track), so its
            // arrival never steps the level and source overs never reach the limiter.
            let plain = self.bands(sampleRate: sampleRate, adaptation: false)
            let plainPeak = max(0, Self.peakBoostDb(plain, sampleRate: sampleRate))
            var preamp = -(plainPeak + Self.headroomDb + Self.sourceOverHeadroomDb + Self.adaptiveReserveDb)
            if !adaptationIsNeutral {
                preamp -= Self.loudnessChangeDb(bands, sampleRate: sampleRate) - Self.loudnessChangeDb(plain, sampleRate: sampleRate)
            }
            s.preampDb = min(preamp, peak > 0.01 ? -(peak + Self.headroomDb + Self.sourceOverHeadroomDb) : 0)
        }
        s.eqEnabled = eqEnabled
        if levelMatch {
            // Make both paths equally loud; only ever attenuate.
            let eqLoudness = Self.loudnessChangeDb(bands, sampleRate: sampleRate) + s.preampDb
            if eqLoudness < 0 { s.dryGainDb = eqLoudness } else { s.preampDb -= eqLoudness }
        }
        return s
    }

    // MARK: - Analysis on a dense log grid

    static let grid: [Double] = (0..<480).map { 20 * pow(1000, Double($0) / 479) } // 20 Hz - 20 kHz

    public static func responseDb(_ bands: [BandParameters], at f: Double, sampleRate: Double) -> Double {
        bands.reduce(0) { $0 + $1.coefficients(sampleRate: sampleRate).magnitudeDb(at: f, sampleRate: sampleRate) }
    }

    /// Total response on `grid` (below Nyquist), coefficients computed once.
    static func gridResponse(_ bands: [BandParameters], sampleRate: Double) -> [(f: Double, db: Double)] {
        let coefficients = bands.map { $0.coefficients(sampleRate: sampleRate) }
        return grid.filter { $0 < sampleRate / 2 }.map { f in
            (f, coefficients.reduce(0) { $0 + $1.magnitudeDb(at: f, sampleRate: sampleRate) })
        }
    }

    public static func peakBoostDb(_ bands: [BandParameters], sampleRate: Double) -> Double {
        gridResponse(bands, sampleRate: sampleRate).map(\.db).max() ?? 0
    }

    /// Change in K-weighted (BS.1770) loudness the bands cause on music-like content
    /// (-4.5 dB/octave power slope, typical pop LTAS). K-weighting is the standard for programme
    /// loudness; A-weighting (a 40-phon contour) underrates bass changes at listening levels.
    public static func loudnessChangeDb(_ bands: [BandParameters], sampleRate: Double) -> Double {
        var num = 0.0, den = 0.0
        for (f, db) in gridResponse(bands, sampleRate: sampleRate) {
            let w = pow(f / 1000, -4.5 / (10 * log10(2.0))) * pow(10, kWeightingDb(f) / 10)
            num += w * pow(10, db / 10)
            den += w
        }
        return 10 * log10(num / den)
    }

    static let kWeighting = LoudnessMeter.kWeighting(sampleRate: 48_000)

    static func kWeightingDb(_ f: Double) -> Double {
        kWeighting.0.magnitudeDb(at: f, sampleRate: 48_000) + kWeighting.1.magnitudeDb(at: f, sampleRate: 48_000)
    }

    static func aWeightingDb(_ f: Double) -> Double {
        let f2 = f * f
        let ra = (12194.0 * 12194 * f2 * f2) /
            ((f2 + 20.6 * 20.6) * ((f2 + 107.7 * 107.7) * (f2 + 737.9 * 737.9)).squareRoot() * (f2 + 12194.0 * 12194))
        return 20 * log10(ra) + 2.0
    }
}
