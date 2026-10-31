import Foundation
import Testing
@testable import EQCore

@Suite struct SoundQualityTests {
    let fs = 44_100.0

    /// Pink-ish noise with slow level swings: dynamic, full range.
    func dynamic(seed: UInt64 = 5) -> [Float] {
        let x = coloredNoise(slope: -4.5, count: Int(fs * 20), sampleRate: fs, rms: 0.08, seed: seed)
        return x.enumerated().map { i, v in v * Float(0.6 + 0.4 * sin(Double(i) / fs * 3)) }
    }

    @Test func dynamicFullRangeScoresWell() {
        let x = dynamic()
        let q = SoundQuality.measure(left: x, right: x, sampleRate: fs)
        #expect(q.score >= SoundQuality.acceptScore, "\(q)")
        #expect(q.issues.isEmpty, "\(q.issues)")
    }

    @Test func crushedAndClippedScoresBadly() {
        // Loud, hard-clipped: low PLR and many full-scale runs.
        let x = dynamic().map { min(max($0 * 12, -1), 1) }
        let q = SoundQuality.measure(left: x, right: x, sampleRate: fs)
        #expect(q.score < SoundQuality.acceptScore, "\(q)")
        #expect(q.issues.contains("kırpılma") && q.issues.contains("sıkıştırılmış"), "\(q.issues)")
    }

    @Test func dullRecordingLosesTrebleScore() {
        let full = SoundQuality.measure(left: dynamic(), right: dynamic(), sampleRate: fs)
        let dark = coloredNoise(slope: -16, count: Int(fs * 20), sampleRate: fs, rms: 0.08, seed: 6)
        let q = SoundQuality.measure(left: dark, right: dark, sampleRate: fs)
        #expect(q.trebleDb < -32 && q.issues.contains("tizler kesik"), "\(q)")
        #expect(q.score < full.score)
    }

    @Test func tooShortIsZero() {
        let x = Array(dynamic().prefix(Int(fs * 3)))
        #expect(SoundQuality.measure(left: x, right: x, sampleRate: fs).score == 0)
    }
}
