import Foundation

/// A rough "is this well recorded and mastered" score for a short excerpt (a 30 s store
/// preview), used by discovery to drop crushed, clipped, dull or thin tracks. Genre-neutral:
/// it only looks at dynamics, overs and how far the spectrum reaches at both ends.
public struct SoundQuality: Sendable, Equatable {
    public var plrDb = 0.0
    /// Runs of ≥ 3 samples at full scale, per second.
    public var clipsPerSecond = 0.0
    /// PSD around 10–12.5 kHz relative to 1–4 kHz (dB): very negative = dull / band-limited.
    public var trebleDb = 0.0
    /// PSD around 40–63 Hz relative to 1–4 kHz (dB): very negative = thin.
    public var bassDb = 0.0
    public var tiltDbPerOctave = 0.0
    public var seconds = 0.0
    /// 0…100.
    public var score = 0.0

    public static let acceptScore = 70.0
    static let clipLevel: Float = 0.995

    public init() {}

    /// Short descriptions of what lowered the score (Turkish, for the UI).
    public var issues: [String] {
        var out: [String] = []
        if plrDb < 8 { out.append("sıkıştırılmış") }
        if clipsPerSecond > 0.3 { out.append("kırpılma") }
        if trebleDb < -32 { out.append("tizler kesik") }
        if bassDb < 3 { out.append("bas zayıf") }
        return out
    }

    /// `left`/`right` at `sampleRate`; needs at least ~10 s of music.
    public static func measure(left: [Float], right: [Float], sampleRate: Double) -> SoundQuality {
        precondition(left.count == right.count)
        let analyzer = TrackAnalyzer(sampleRate: sampleRate)
        analyzer.detectsChanges = false
        var mid = [Float](repeating: 0, count: 4800)
        var side = mid
        var i = 0
        while i < left.count {
            let n = min(mid.count, left.count - i)
            for k in 0..<n {
                mid[k] = (left[i + k] + right[i + k]) / 2
                side[k] = (left[i + k] - right[i + k]) / 2
            }
            _ = mid.withUnsafeBufferPointer { m in
                side.withUnsafeBufferPointer { s in analyzer.process(mid: m.baseAddress!, side: s.baseAddress!, count: n) }
            }
            i += n
        }
        var q = SoundQuality()
        let f = analyzer.features
        q.seconds = f.seconds
        q.plrDb = f.plrDb
        q.clipsPerSecond = Double(clipRuns(left) + clipRuns(right)) / max(Double(left.count) / sampleRate, 1)
        let psd = f.psdDb
        func mean(_ range: ClosedRange<Double>) -> Double {
            let picked = ThirdOctave.centers.indices.filter { range.contains(ThirdOctave.centers[$0]) }.map { psd[$0] }
            return picked.reduce(0, +) / Double(max(picked.count, 1))
        }
        let reference = mean(1000...4000)
        q.trebleDb = mean(10_000...12_500) - reference
        q.bassDb = mean(40...63) - reference
        q.tiltDbPerOctave = f.tiltDbPerOctave
        q.score = score(q)
        return q
    }

    static func score(_ q: SoundQuality) -> Double {
        guard q.seconds >= 8 else { return 0 }
        func ramp(_ x: Double, _ bad: Double, _ good: Double) -> Double { min(max((x - bad) / (good - bad), 0), 1) }
        return 40 * ramp(q.plrDb, 5, 12)
            + 20 * (1 - ramp(q.clipsPerSecond, 0.05, 2))
            + 20 * ramp(q.trebleDb, -45, -22)
            + 10 * ramp(q.bassDb, -5, 12)
            + 10 * (1 - ramp(abs(q.tiltDbPerOctave + 4.5), 2.5, 5))
    }

    private static func clipRuns(_ x: [Float]) -> Int {
        var runs = 0, length = 0
        for v in x {
            if abs(v) >= clipLevel {
                length += 1
                if length == 3 { runs += 1 }
            } else {
                length = 0
            }
        }
        return runs
    }
}
