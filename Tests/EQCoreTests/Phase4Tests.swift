import Accelerate
import Foundation
import Testing
@testable import EQCore

/// Deterministic generator for reproducible noise.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Stationary noise whose power spectral density falls `slope` dB/octave (−3 = pink), at the
/// given RMS, built by inverse FFT with random phases and tiled to `count` samples.
func coloredNoise(slope: Double, count: Int, sampleRate: Double, rms: Double = 0.1, seed: UInt64 = 1) -> [Float] {
    let log2n = 17, n = 1 << log2n
    var rng = SplitMix(state: seed)
    var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
    for k in 1..<(n / 2) {
        let f = Double(k) * sampleRate / Double(n)
        guard f >= 20 else { continue }
        let amp = pow(f / 1000, slope / (20 * log10(2.0)))
        let phase = Double.random(in: 0..<(2 * .pi), using: &rng)
        re[k] = Float(amp * cos(phase)); im[k] = Float(amp * sin(phase))
    }
    var x = [Float](repeating: 0, count: n)
    let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(setup) }
    re.withUnsafeMutableBufferPointer { r in
        im.withUnsafeMutableBufferPointer { i in
            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
            vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
            x.withUnsafeMutableBytes {
                vDSP_ztoc(&split, 1, $0.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(n / 2))
            }
        }
    }
    let current = (x.map { Double($0) * Double($0) }.reduce(0, +) / Double(n)).squareRoot()
    let k = Float(rms / current)
    return (0..<count).map { x[$0 % n] * k }
}

/// Feeds a mono signal (mid only) through the analyzer; returns the detected changes with times.
@discardableResult
func feed(_ analyzer: TrackAnalyzer, _ x: [Float], side: [Float]? = nil) -> [(seconds: Double, reason: TrackAnalyzer.ChangeReason)] {
    var changes: [(Double, TrackAnalyzer.ChangeReason)] = []
    let s = side ?? [Float](repeating: 0, count: x.count)
    let block = 4800
    var start = 0
    while start < x.count {
        let n = min(block, x.count - start)
        let reason = x.withUnsafeBufferPointer { m in
            s.withUnsafeBufferPointer { sd in
                analyzer.process(mid: m.baseAddress! + start, side: sd.baseAddress! + start, count: n)
            }
        }
        if let reason { changes.append((Double(start) / analyzer.sampleRate, reason)) }
        start += n
    }
    return changes
}

@Suite struct LoudnessTests {
    /// BS.1770: a 997 Hz sine at 0 dBFS in both channels reads 0 LUFS.
    @Test(arguments: [44_100.0, 48_000.0, 96_000.0])
    func sineReadsReferenceLoudness(sampleRate: Double) {
        var meter = LoudnessMeter(sampleRate: sampleRate)
        for i in 0..<Int(sampleRate * 3) {
            meter.process(mid: 0.1 * sin(2 * .pi * 997 * Double(i) / sampleRate), side: 0)
        }
        #expect(abs(meter.momentary - -20) < 0.1, "M \(meter.momentary)")
        #expect(abs(meter.integrated - -20) < 0.1, "I \(meter.integrated)")
        #expect(abs(meter.shortTermCrestDb - 3.01) < 0.1, "crest \(meter.shortTermCrestDb)")
    }

    @Test func gatesSilenceAndQuietPassages() {
        let fs = 48_000.0
        var meter = LoudnessMeter(sampleRate: fs)
        for (amp, seconds) in [(0.1, 5.0), (0.0, 5.0), (0.01, 5.0)] {
            for i in 0..<Int(fs * seconds) { meter.process(mid: amp * sin(2 * .pi * 997 * Double(i) / fs), side: 0) }
        }
        // The −40 LUFS part is more than 10 LU below the ungated mean; silence below −70.
        #expect(abs(meter.integrated - -20) < 0.2, "I \(meter.integrated)")
    }
}

@Suite struct TrackAnalysisTests {
    @Test(arguments: [-3.0, -4.5, -6.0])
    func measuresSpectralTilt(slope: Double) {
        let fs = 48_000.0
        let analyzer = TrackAnalyzer(sampleRate: fs)
        feed(analyzer, coloredNoise(slope: slope, count: Int(fs * 12), sampleRate: fs))
        let f = analyzer.features
        #expect(f.seconds > 5)
        #expect(abs(f.tiltDbPerOctave - slope) < 0.3, "tilt \(f.tiltDbPerOctave)")
        #expect(f.width == 0)
        #expect(abs(f.integratedLufs - f.shortTermLufs) < 1)
    }

    @Test func widthFromSide() {
        let fs = 32_000.0
        let analyzer = TrackAnalyzer(sampleRate: fs)
        let m = coloredNoise(slope: -4.5, count: Int(fs * 6), sampleRate: fs, seed: 1)
        let s = coloredNoise(slope: -4.5, count: Int(fs * 6), sampleRate: fs, seed: 2)
        feed(analyzer, m, side: s)
        #expect(abs(analyzer.features.width - 0.5) < 0.05)
    }

    @Test func steadySignalIsOneTrack() {
        let fs = 32_000.0
        let analyzer = TrackAnalyzer(sampleRate: fs)
        let changes = feed(analyzer, coloredNoise(slope: -4.5, count: Int(fs * 70), sampleRate: fs))
        #expect(changes.isEmpty)
        #expect(analyzer.lastNoveltyDb < 1)
    }

    @Test func silenceGapStartsNewTrack() {
        let fs = 32_000.0
        let analyzer = TrackAnalyzer(sampleRate: fs)
        let a = coloredNoise(slope: -4.5, count: Int(fs * 20), sampleRate: fs)
        let gap = [Float](repeating: 0, count: Int(fs * 1.5))
        let b = coloredNoise(slope: -3, count: Int(fs * 5), sampleRate: fs, seed: 9)
        let changes = feed(analyzer, a + gap + b)
        #expect(changes.map(\.reason) == [.silenceGap])
        #expect(changes.first.map { $0.seconds > 21 && $0.seconds < 22.5 } == true)
        #expect(analyzer.gatedSeconds < 5)
    }

    @Test func lastingSpectralChangeStartsNewTrack() {
        let fs = 32_000.0
        let analyzer = TrackAnalyzer(sampleRate: fs)
        let a = coloredNoise(slope: -3, count: Int(fs * 40), sampleRate: fs)
        let b = coloredNoise(slope: -9, count: Int(fs * 20), sampleRate: fs, seed: 5)
        let changes = feed(analyzer, a + b)
        #expect(changes.map(\.reason) == [.novelty])
        // Detected within ~3 s smoothing + 6 s hold of the switch at 40 s.
        #expect(changes.first.map { $0.seconds > 40 && $0.seconds < 50 } == true, "\(changes)")

        let quiet = TrackAnalyzer(sampleRate: fs)
        quiet.detectsChanges = false
        #expect(feed(quiet, a + b).isEmpty)
    }
}

@Suite struct AdaptationTests {
    func features(slope: Double, fs: Double = 32_000) -> TrackFeatures {
        let analyzer = TrackAnalyzer(sampleRate: fs)
        feed(analyzer, coloredNoise(slope: slope, count: Int(fs * 12), sampleRate: fs))
        return analyzer.features
    }

    @Test func targetSlopeNeedsNoCorrection() {
        let c = AdaptiveFit.correction(for: features(slope: AdaptiveFit.targetSlope))
        #expect(c.gains.allSatisfy { abs($0) < 0.4 }, "\(c.gains)")
        #expect(c.presenceReduction < 0.05)
    }

    @Test func darkTrackGetsBrighterAndBrightTrackDarker() {
        let dark = AdaptiveFit.correction(for: features(slope: -6.5))
        #expect(dark.gains.first! < -0.5 && dark.gains.last! > 0.5, "\(dark.gains)")
        #expect(dark.presenceReduction == 0)

        let bright = AdaptiveFit.correction(for: features(slope: -2.5))
        #expect(bright.gains.first! > 0.5 && bright.gains.last! < -0.5, "\(bright.gains)")
        #expect(bright.presenceReduction > 0.2)
    }

    @Test func designScalesAndClampsL3() throws {
        var design = EQDesign(profile: try loadProfile())
        design.adaptive = AdaptiveCorrection(gains: [8, -8, 3, 0, -3, 8], presenceReduction: 0.5)
        design.adaptStrength = 1
        #expect(design.adaptiveGains == [2, -2, 2, 0, -2, 2])
        design.adaptStrength = 0.3
        #expect(design.adaptiveGains.map { ($0 * 100).rounded() / 100 } == [2, -2, 0.9, 0, -0.9, 2])
        #expect(design.presenceScale == 0.5)
        design.adaptStrength = 0.15
        #expect(abs(design.presenceScale - 0.75) < 1e-12)
        design.adaptEnabled = false
        #expect(design.adaptiveGains.allSatisfy { $0 == 0 } && design.presenceScale == 1)
    }

    @Test func presenceRuleOnlyTouchesL0PresenceBoosts() throws {
        let fs = 48_000.0
        var design = EQDesign(profile: try loadProfile())
        let before = design.bands(sampleRate: fs)
        design.adaptive = AdaptiveCorrection(gains: [0, 0, 0, 0, 0, 0], presenceReduction: 0.5)
        let after = design.bands(sampleRate: fs)
        for (b, a) in zip(before, after) {
            if b.type == .peaking, EQDesign.presenceRange.contains(b.frequency), b.gainDb > 0 {
                #expect(abs(a.gainDb - b.gainDb * 0.5) < 1e-12)
            } else {
                #expect(a == b)
            }
        }
    }

    @Test func zeroStrengthIsBitIdenticalToNoL3() throws {
        let fs = 48_000.0
        let profile = try loadProfile()
        // The Phase 3 chain: no L3 at all.
        var plain = EQDesign(profile: profile)
        plain.adaptEnabled = false
        plain.adaptStrength = 0
        var zero = EQDesign(profile: profile)
        zero.adaptive = AdaptiveCorrection(gains: [3, -2, 1, 2, -1, 4], presenceReduction: 0.4)
        zero.adaptStrength = 0

        let a = plain.settings(sampleRate: fs), b = zero.settings(sampleRate: fs)
        #expect(a.bands == b.bands && a.preampDb == b.preampDb && a.dryGainDb == b.dryGainDb)

        let x = coloredNoise(slope: -4.5, count: 24_000, sampleRate: fs, rms: 0.2)
        let outA = runStream(readyKernel(a, sampleRate: fs), left: x, right: x, sampleRate: fs)
        let outB = runStream(readyKernel(b, sampleRate: fs), left: x, right: x, sampleRate: fs)
        #expect(outA.left == outB.left && outA.right == outB.right)
    }

    @Test func l3ChangesBalanceNotLoudness() throws {
        let fs = 48_000.0
        var design = EQDesign(profile: try loadProfile())
        design.levelMatch = false
        let base = design.settings(sampleRate: fs)
        func loudness(_ s: DSPSettings) -> Double { EQDesign.loudnessChangeDb(s.bands, sampleRate: fs) + s.preampDb }
        func margin(_ s: DSPSettings) -> Double { -s.preampDb - EQDesign.peakBoostDb(s.bands, sampleRate: fs) }

        // Typical correction (boosts within the reserve): same loudness as without L3.
        design.adaptive = AdaptiveCorrection(gains: [-3, -2, 0, 1, 2, 2], presenceReduction: 0.3)
        let adapted = design.settings(sampleRate: fs)
        #expect(abs(loudness(base) - loudness(adapted)) < 0.05, "\(loudness(base)) vs \(loudness(adapted))")
        // Turning L3 off for A/B keeps the reserve, so the level does not jump either.
        design.adaptEnabled = false
        #expect(abs(loudness(base) - loudness(design.settings(sampleRate: fs))) < 1e-9)

        // Large boosts: level gives way so the headroom is never eaten.
        design.adaptEnabled = true
        design.adaptStrength = 1
        design.adaptive = AdaptiveCorrection(gains: [-4, -2, 0, 2, 4, 6], presenceReduction: 0)
        let big = design.settings(sampleRate: fs)
        #expect(margin(big) >= EQDesign.headroomDb + EQDesign.sourceOverHeadroomDb - 1e-9)
        #expect(margin(adapted) >= EQDesign.headroomDb + EQDesign.sourceOverHeadroomDb - 1e-9)
    }

    @Test func controllerHoldsThenSettlesWithoutOvershoot() {
        let f = features(slope: -6.5)
        let goal = AdaptiveFit.correction(for: f)
        var c = AdaptationController()
        c.trackChanged(cached: nil)
        // First 10 s of audio: frozen.
        for t in stride(from: 0.5, to: 10, by: 0.5) { c.update(features: f, ownSeconds: t, dt: 0.5) }
        #expect(c.current.isNeutral && c.phase == .learning)

        var previous = c.current.gains
        for t in stride(from: 10.0, to: 130, by: 0.5) {
            c.update(features: f, ownSeconds: t, dt: 0.5)
            for (j, g) in c.current.gains.enumerated() {
                // Monotonic towards the goal: never past it, never back.
                #expect(abs(goal.gains[j] - g) <= abs(goal.gains[j] - previous[j]) + 1e-12)
                #expect((goal.gains[j] - g) * (goal.gains[j] - previous[j]) >= 0)
            }
            previous = c.current.gains
        }
        #expect(c.phase == .adapting)
        #expect(zip(c.current.gains, goal.gains).allSatisfy { abs($0 - $1) < 0.01 })
        // ~63 % after one attack time constant.
        var d = AdaptationController()
        d.update(features: f, ownSeconds: 10, dt: AdaptationController.attackSeconds)
        let j = goal.gains.indices.max { abs(goal.gains[$0]) < abs(goal.gains[$1]) }!
        #expect(abs(d.current.gains[j] / goal.gains[j] - 0.632) < 0.01)
    }

    @Test func controllerUsesCacheImmediatelyAndPausesWithAudio() {
        let f = features(slope: -6.5)
        var c = AdaptationController()
        c.trackChanged(cached: f)
        #expect(c.phase == .cached)
        c.update(features: TrackFeatures(), ownSeconds: 1, dt: 1)
        #expect(!c.current.isNeutral)
        let held = c.current
        c.update(features: TrackFeatures(), ownSeconds: 1, dt: 0) // paused: no time passes
        #expect(c.current == held)
    }
}

@Suite struct CacheTests {
    @Test func roundTripAndMerge() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try TrackCache(path: dir.appendingPathComponent("tracks.sqlite").path)
        var f = TrackFeatures()
        f.ltasPower = f.ltasPower.indices.map { Double($0 + 1) }
        f.seconds = 30
        f.integratedLufs = -9.5
        let entry = TrackCache.Entry(title: "Şarkı", artist: "Sanatçı", durationSeconds: 201.4, features: f)
        try cache.store(entry)
        #expect(cache.count == 1)
        #expect(cache.entry(forKey: TrackCache.key(title: "Şarkı", artist: "Sanatçı", durationSeconds: 201)) == entry)

        var silent = TrackFeatures()   // −∞ loudness must survive the round trip
        silent.seconds = 1
        try cache.store(.init(title: "x", artist: "y", durationSeconds: 1, features: silent))
        #expect(cache.entry(forKey: TrackCache.key(title: "x", artist: "y", durationSeconds: 1))?.features == silent)

        var g = f
        g.ltasPower = g.ltasPower.map { $0 * 3 }
        g.seconds = 10
        let m = f.merged(with: g)
        #expect(m.seconds == 40)
        #expect(abs(m.ltasPower[0] - (1 * 30 + 3 * 10) / 40.0) < 1e-12)
    }

    @Test func ringCopyDetectsOverwrite() {
        let ring = SampleRing(capacity: 4096)
        for i in 0..<3000 { ring.push(Float(i)) }
        ring.commit()
        var out = [Float](repeating: 0, count: 100)
        #expect(ring.copy(from: 1000, count: 100, into: &out))
        #expect(out.first == 1000 && out.last == 1099)
        #expect(!ring.copy(from: 2950, count: 100, into: &out)) // not written yet
        for i in 3000..<6000 { ring.push(Float(i)) }
        ring.commit()
        #expect(!ring.copy(from: 1000, count: 100, into: &out)) // overwritten
    }
}
