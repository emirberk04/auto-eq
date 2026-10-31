import Foundation
import Testing
@testable import EQCore

@Suite struct EqualLoudnessTests {
    /// ISO 226:2003 reference values.
    @Test func matchesStandardContours() {
        #expect(abs(EqualLoudness.spl(frequency: 1000, phon: 40) - 40) < 0.05)
        #expect(abs(EqualLoudness.spl(frequency: 20, phon: 40) - 99.85) < 0.05)
        #expect(abs(EqualLoudness.spl(frequency: 100, phon: 40) - 64.37) < 0.05)
        #expect(abs(EqualLoudness.spl(frequency: 1000, phon: 80) - 80) < 0.05)
    }

    @Test func compensationGrowsAsVolumeDrops() {
        let c10 = EqualLoudness.compensationDb(frequency: 40, phon: 73, referencePhon: 83)
        let c20 = EqualLoudness.compensationDb(frequency: 40, phon: 63, referencePhon: 83)
        #expect(c10 > 2 && c20 > c10)
        #expect(abs(EqualLoudness.compensationDb(frequency: 1000, phon: 63, referencePhon: 83)) < 1e-9)
        #expect(EqualLoudness.compensationDb(frequency: 40, phon: 83, referencePhon: 83) == 0)
    }
}

@Suite struct ToneTests {
    func design(_ tone: EQDesign.Tone) throws -> EQDesign {
        var d = EQDesign(profile: try loadProfile())
        d.tone = tone
        return d
    }

    @Test func naturalToneKeepsBandsAtZero() throws {
        let fs = 48_000.0
        let natural = try design(.natural).bands(sampleRate: fs)
        let harman = try design(.harman).bands(sampleRate: fs)
        #expect(natural.count == harman.count) // same chain: switching glides, no filter reset
        #expect(natural.allSatisfy { $0.gainDb == 0 })
    }

    @Test func naturalWithNothingElseIsBitTransparent() throws {
        let fs = 48_000.0
        var d = try design(.natural)
        d.adaptStrength = 0
        d.levelMatch = false
        let s = d.settings(sampleRate: fs)
        #expect(s.preampDb == 0 && s.dryGainDb == 0)
        let x = coloredNoise(slope: -4.5, count: 20_000, sampleRate: fs, rms: 0.2)
        let kernel = readyKernel(s, sampleRate: fs)
        let out = runStream(kernel, left: x, right: x, sampleRate: fs)
        let lag = kernel.latencyFrames
        #expect((lag..<x.count).allSatisfy { out.left[$0] == x[$0 - lag] })
    }

    @Test func loudnessCompensationFollowsVolume() throws {
        let fs = 48_000.0
        var d = try design(.natural)
        d.loudnessCompensation = true
        d.listeningOffsetDb = 0
        #expect(d.loudnessGains == (0, 0))
        d.listeningOffsetDb = 3 // above the reference: nothing
        #expect(d.loudnessGains == (0, 0))
        d.listeningOffsetDb = -10
        let g10 = d.loudnessGains
        #expect(g10.bass > 2.5 && g10.bass < 4.5 && g10.treble > 0.5 && g10.treble < 2)
        let bands = d.bands(sampleRate: fs)
        #expect(EQDesign.responseDb(bands, at: 40, sampleRate: fs) > 2)
        #expect(abs(EQDesign.responseDb(bands, at: 1000, sampleRate: fs)) < 0.5)
        d.listeningOffsetDb = -50
        #expect(d.loudnessGains == (EQDesign.maxLoudnessBassDb, EQDesign.maxLoudnessTrebleDb))
        d.listeningOffsetDb = nil // unreadable volume: off
        #expect(d.loudnessGains == (0, 0))
        d.listeningOffsetDb = -10
        d.loudnessCompensation = false
        #expect(d.loudnessGains == (0, 0))
    }

    @Test func libraryTargetMakesTypicalTracksNeutral() {
        // A library of −6 dB/octave tracks: a −6 track needs nothing, a −3.5 track is darkened.
        func features(_ slope: Double, seed: UInt64) -> TrackFeatures {
            let fs = 32_000.0
            let analyzer = TrackAnalyzer(sampleRate: fs)
            feed(analyzer, coloredNoise(slope: slope, count: Int(fs * 6), sampleRate: fs, seed: seed))
            return analyzer.features
        }
        let library = (1...8).map { features(-6, seed: $0) }
        let target = AdaptiveFit.libraryTarget(library)
        #expect(target != nil)
        #expect(AdaptiveFit.libraryTarget(Array(library.prefix(7))) == nil)

        let typical = AdaptiveFit.correction(for: features(-6, seed: 42), target: target)
        #expect(typical.gains.allSatisfy { abs($0) < 0.4 }, "\(typical.gains)")
        // Against the default −4.5 line the same track would be brightened.
        #expect(AdaptiveFit.correction(for: features(-6, seed: 42)).gains.last! > 0.5)

        let bright = AdaptiveFit.correction(for: features(-3.5, seed: 43), target: target)
        #expect(bright.gains.first! > 0.5 && bright.gains.last! < -0.5, "\(bright.gains)")
    }
}

@Suite struct AdaptiveHeadroomTests {
    /// Natural tone, flat L1/L2: when L3 wakes up 10 s into a track the level must not step,
    /// and the headroom for source overs is there from the first sample.
    @Test func l3ArrivalDoesNotStepTheLevel() throws {
        let fs = 48_000.0
        var d = EQDesign(profile: try loadProfile())
        d.tone = .natural
        d.levelMatch = false
        let neutral = d.settings(sampleRate: fs)
        #expect(neutral.preampDb <= -(EQDesign.headroomDb + EQDesign.sourceOverHeadroomDb))
        d.adaptive = AdaptiveCorrection(gains: [0.3, 0, 0, 0, 0, 0], presenceReduction: 0)
        let small = d.settings(sampleRate: fs)
        let loud = { (s: DSPSettings) in EQDesign.loudnessChangeDb(s.bands, sampleRate: fs) + s.preampDb }
        #expect(abs(loud(neutral) - loud(small)) < 0.05)
    }
}
