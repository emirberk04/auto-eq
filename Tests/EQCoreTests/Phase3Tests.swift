import Foundation
import Testing
@testable import EQCore

@Suite struct PersonalOffsetTests {
    @Test func bassAndTrebleShelvesAddToL0() throws {
        let fs = 48_000.0
        var design = EQDesign(profile: try loadProfile())
        let base = design.bands(sampleRate: fs)
        design.bassDb = 4
        design.trebleDb = -2
        let shaped = design.bands(sampleRate: fs)
        #expect(shaped.count == base.count)
        let d30 = EQDesign.responseDb(shaped, at: 30, sampleRate: fs) - EQDesign.responseDb(base, at: 30, sampleRate: fs)
        let d1k = EQDesign.responseDb(shaped, at: 1000, sampleRate: fs) - EQDesign.responseDb(base, at: 1000, sampleRate: fs)
        let d16k = EQDesign.responseDb(shaped, at: 16_000, sampleRate: fs) - EQDesign.responseDb(base, at: 16_000, sampleRate: fs)
        #expect(abs(d30 - 4) < 0.3)
        #expect(abs(d1k) < 0.3)
        #expect(abs(d16k - -2) < 0.3)
    }

    @Test func offsetsAreClampedToSpecRanges() throws {
        var design = EQDesign(profile: try loadProfile())
        design.bassDb = 20
        design.trebleDb = -20
        #expect(design.bassDb == 6)
        #expect(design.trebleDb == -3)
    }

    @Test func flatEverythingIsBitTransparent() throws {
        var design = EQDesign(profile: try loadProfile(), strength: 0)
        design.levelMatch = false
        design.adaptStrength = 0
        let s = design.settings(sampleRate: 48_000)
        #expect(s.preampDb == 0)
        let kernel = readyKernel(s, sampleRate: 48_000)
        var rng = SystemRandomNumberGenerator()
        // Below the limiter ceiling: with EQ on, overs are limited even when the EQ is flat.
        let x = (0..<20_000).map { _ in Float.random(in: -0.9...0.9, using: &rng) }
        let out = runStream(kernel, left: x, right: x, sampleRate: 48_000)
        let d = kernel.latencyFrames
        #expect((d..<x.count).allSatisfy { out.left[$0] == x[$0 - d] })
    }

    @Test func bassBoostRaisesPreampHeadroom() throws {
        var design = EQDesign(profile: try loadProfile())
        let before = design.settings(sampleRate: 48_000).preampDb
        design.bassDb = 6
        let after = design.settings(sampleRate: 48_000).preampDb
        #expect(after < before)
    }
}

@Suite struct AnalysisTests {
    @Test func ringReturnsLatestSamplesInOrder() {
        let ring = SampleRing(capacity: 16)
        for i in 0..<20 { ring.push(Float(i)) }
        var out = [Float](repeating: 0, count: 4)
        #expect(!ring.copyLatest(4, into: &out)) // nothing committed yet
        ring.commit()
        #expect(ring.copyLatest(4, into: &out))
        #expect(out == [16, 17, 18, 19])
    }

    @Test(arguments: [100.0, 1000.0, 5000.0])
    func sineReadsItsLevelInItsBand(frequency: Double) {
        let fs = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let x = (0..<analyzer.size).map { Float(0.5 * sin(2 * Double.pi * frequency * Double($0) / fs)) }
        let levels = x.withUnsafeBufferPointer { analyzer.analyze($0.baseAddress!, sampleRate: fs) }
        let peak = levels.indices.max { levels[$0] < levels[$1] }!
        let ratio = analyzer.centers[peak] / frequency
        #expect(ratio > 0.9 && ratio < 1.1, "peak band \(analyzer.centers[peak]) Hz")
        // The tone's power can straddle two bands; together they hold −6 dBFS. Below ~300 Hz
        // bands are narrower than an FFT bin and share bins, so only the peak position counts.
        if frequency >= 300 {
            let total = 10 * log10(levels.map { pow(10, Double($0) / 10) }.reduce(0, +))
            #expect(abs(total - -6.02) < 0.5, "total \(total)")
        }
    }

    @Test func kernelFillsInputAndOutputHistory() throws {
        let kernel = readyKernel(EQDesign(profile: try loadProfile()).settings(sampleRate: 48_000), sampleRate: 48_000)
        let x = (0..<8192).map { Float(sin(Double($0) * 0.1)) * 0.25 }
        _ = runStream(kernel, left: x, right: x, sampleRate: 48_000)
        var input = [Float](repeating: 0, count: 4096), output = [Float](repeating: 0, count: 4096)
        #expect(kernel.inputHistory.copyLatest(4096, into: &input))
        #expect(kernel.outputHistory.copyLatest(4096, into: &output))
        #expect(input.last == x.last)
        #expect(output.contains { $0 != 0 })
    }
}
