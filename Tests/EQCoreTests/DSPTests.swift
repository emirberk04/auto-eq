import Foundation
import Testing
@testable import EQCore

private struct AutoEqFixture: Decodable {
    struct Coefficients: Decodable { let b0, b1, b2, a1, a2: Double }
    struct Rate: Decodable {
        let frequencies: [Double]
        let responseDb: [Double]
        let coefficients: [Coefficients]
    }
    let rates: [String: Rate]

    init(from decoder: Decoder) throws {
        rates = try [String: Rate](from: decoder)
    }

    static func load() throws -> AutoEqFixture {
        let url = try #require(Bundle.module.url(forResource: "autoeq-s12-ultra-response", withExtension: "json",
                                                  subdirectory: "Fixtures"))
        return try JSONDecoder().decode(AutoEqFixture.self, from: Data(contentsOf: url))
    }
}

@Suite struct DSPTests {
    @Test(arguments: [44_100.0, 48_000.0, 96_000.0])
    func rbjCoefficientsMatchAutoEq(sampleRate: Double) throws {
        let profile = try loadProfile()
        let fixture = try #require(try AutoEqFixture.load().rates[String(Int(sampleRate))])
        for (filter, expected) in zip(profile.filters, fixture.coefficients) {
            let c = BiquadCoefficients(filter.type, frequency: filter.frequency, q: filter.q,
                                       gainDb: filter.gain, sampleRate: sampleRate)
            for (a, b) in [(c.b0, expected.b0), (c.b1, expected.b1), (c.b2, expected.b2),
                           (c.a1, expected.a1), (c.a2, expected.a2)] {
                #expect(abs(a - b) < 1e-9, "\(filter.type) \(filter.frequency) Hz: \(a) vs \(b)")
            }
        }
    }

    /// Phase 2 acceptance: impulse through the real-time kernel, DFT, compare with AutoEq ±0.3 dB.
    @Test(arguments: [48_000.0, 96_000.0])
    func measuredChainResponseMatchesAutoEq(sampleRate: Double) throws {
        let profile = try loadProfile()
        let fixture = try #require(try AutoEqFixture.load().rates[String(Int(sampleRate))])
        var design = EQDesign(profile: profile, strength: 1)
        design.levelMatch = false
        let settings = design.settings(sampleRate: sampleRate)
        let kernel = readyKernel(settings, sampleRate: sampleRate)

        let n = 1 << 16
        let amplitude: Float = 0.01
        var impulse = [Float](repeating: 0, count: n)
        impulse[0] = amplitude
        let out = runStream(kernel, left: impulse, right: impulse, sampleRate: sampleRate)
        #expect(kernel.limitedFrames.load(ordering: .relaxed) == 0)

        var worst = 0.0
        for (f, expected) in zip(fixture.frequencies, fixture.responseDb) where f < sampleRate / 2 {
            let measured = dftMagnitudeDb(out.left, at: f, sampleRate: sampleRate)
                - 20 * log10(Double(amplitude)) - settings.preampDb
            worst = max(worst, abs(measured - expected))
            #expect(abs(measured - expected) <= 0.3, "\(f) Hz: \(measured) vs \(expected)")
        }
        print("max deviation from AutoEq at \(sampleRate) Hz: \(worst) dB")
    }

    @Test func bypassIsBitExactEvenAboveLimiterCeiling() throws {
        var design = EQDesign(profile: try loadProfile(), strength: 1)
        design.eqEnabled = false
        design.levelMatch = false
        let kernel = readyKernel(design.settings(sampleRate: 48_000), sampleRate: 48_000)
        var rng = SystemRandomNumberGenerator()
        let x = (0..<48_000).map { _ in Float.random(in: -1...1, using: &rng) }
        let y = (0..<48_000).map { _ in Float.random(in: -1...1, using: &rng) }
        let out = runStream(kernel, left: x, right: y, sampleRate: 48_000)
        let d = kernel.latencyFrames
        var mismatches = 0
        for i in d..<x.count where out.left[i] != x[i - d] || out.right[i] != y[i - d] { mismatches += 1 }
        #expect(mismatches == 0)
    }

    @Test func zeroStrengthEqualsBypass() throws {
        var design = EQDesign(profile: try loadProfile(), strength: 0)
        design.levelMatch = false
        design.adaptStrength = 0 // the L0 chain alone (L3 holds headroom whenever it may act)
        let settings = design.settings(sampleRate: 48_000)
        #expect(settings.preampDb == 0)
        let kernel = readyKernel(settings, sampleRate: 48_000)
        let x = (0..<20_000).map { Float(sin(Double($0) * 0.05)) * 0.8 }
        let out = runStream(kernel, left: x, right: x, sampleRate: 48_000)
        let d = kernel.latencyFrames
        #expect((d..<x.count).allSatisfy { out.left[$0] == x[$0 - d] })
    }

    @Test func limiterHoldsCeilingAtFullStrengthAndFullScale() throws {
        let design = EQDesign(profile: try loadProfile(), strength: 1)
        let kernel = readyKernel(design.settings(sampleRate: 48_000), sampleRate: 48_000)
        // Worst case: clipped noise plus a tone at the 3.6 kHz boost, peaking above 0 dBFS.
        var rng = SystemRandomNumberGenerator()
        let x = (0..<96_000).map { i -> Float in
            let tone = sin(2 * Double.pi * 3600 * Double(i) / 48_000)
            // +3.5 dBFS: beyond any real source over, so the limiter must work.
            return Float(1.5 * max(-1, min(1, tone + Double.random(in: -0.5...0.5, using: &rng))))
        }
        let out = runStream(kernel, left: x, right: x, sampleRate: 48_000)
        let ceiling = Float(pow(10, -0.5 / 20))
        let peak = out.left.map(abs).max() ?? 0
        #expect(peak <= ceiling + 1e-6, "peak \(peak)")
        #expect(kernel.limitedFrames.load(ordering: .relaxed) > 0)
    }

    /// Normal listening level: limiter idle, THD+N of the EQ path far below audibility.
    @Test(arguments: [1000.0, 3600.0])
    func cleanSineAtMinusSixDbfs(frequency: Double) throws {
        let fs = 48_000.0
        let design = EQDesign(profile: try loadProfile(), strength: 1)
        let kernel = readyKernel(design.settings(sampleRate: fs), sampleRate: fs)
        let n = 48_000
        let x = (0..<n).map { Float(0.5 * sin(2 * Double.pi * frequency * Double($0) / fs)) }
        let out = runStream(kernel, left: x, right: x, sampleRate: fs)
        #expect(kernel.limitedFrames.load(ordering: .relaxed) == 0)

        // Least-squares fit of the fundamental over the steady-state second half; residual = THD+N.
        let seg = Array(out.left[(n / 2)...]).map(Double.init)
        let w = 2 * Double.pi * frequency / fs
        var ss = 0.0, cc = 0.0, sc = 0.0, sy = 0.0, cy = 0.0
        for (k, y) in seg.enumerated() {
            let s = sin(w * Double(k)), c = cos(w * Double(k))
            ss += s * s; cc += c * c; sc += s * c; sy += s * y; cy += c * y
        }
        let det = ss * cc - sc * sc
        let a = (sy * cc - cy * sc) / det, b = (cy * ss - sy * sc) / det
        var signal = 0.0, residual = 0.0
        for (k, y) in seg.enumerated() {
            let fit = a * sin(w * Double(k)) + b * cos(w * Double(k))
            signal += fit * fit
            residual += (y - fit) * (y - fit)
        }
        let thdN = 10 * log10(residual / signal)
        print("THD+N at \(frequency) Hz: \(thdN) dB")
        #expect(thdN < -120) // Float32 output quantisation is ~-140 dB
    }

    @Test func strengthChangeIsSmooth() throws {
        let fs = 48_000.0
        let profile = try loadProfile()
        var design = EQDesign(profile: profile, strength: 0)
        design.levelMatch = false
        design.adaptStrength = 0
        let kernel = readyKernel(design.settings(sampleRate: fs), sampleRate: fs)
        let f = 3600.0, amp = 0.3
        let x = (0..<48_000).map { Float(amp * sin(2 * Double.pi * f * Double($0) / fs)) }
        design.strength = 1
        let out = runStream(kernel, left: x, right: x, sampleRate: fs) { start in
            if start == 9_728 { kernel.settings.publish(design.settings(sampleRate: fs)) }
        }
        // A sine's sample-to-sample step is bounded by amp·gain·2πf/fs; a coefficient jump
        // (zipper) would exceed it. Gain at 3.6 kHz after preamp ≤ 1.
        let bound = Float(amp * 2 * Double.pi * f / fs) * 1.05
        let maxStep = zip(out.left.dropFirst(), out.left).map { abs($0 - $1) }.max() ?? 0
        let peakOut = out.left.map(abs).max() ?? 0
        print("strength step: max step \(maxStep), bound \(bound), peak \(peakOut) vs amp \(amp)")
        #expect(maxStep <= bound, "max step \(maxStep) > \(bound)")
        // And it actually reached the new response: gain at 3.6 kHz rises by ~+7 dB minus preamp.
        let early = Array(out.left[2_000..<9_000]), late = Array(out.left[40_000..<47_000])
        let rise = 20 * log10(Double(late.map(abs).max()!) / Double(early.map(abs).max()!))
        let expected = EQDesign.responseDb(design.bands(sampleRate: fs), at: f, sampleRate: fs)
            + design.settings(sampleRate: fs).preampDb
        #expect(abs(rise - expected) < 0.1, "rise \(rise) vs \(expected)")
    }

    @Test func autoPreampAndLevelMatch() throws {
        let profile = try loadProfile()
        var design = EQDesign(profile: profile, strength: 1)
        design.adaptStrength = 0 // no L3 reserve: L0 alone
        let s = design.settings(sampleRate: 48_000)
        let peak = EQDesign.peakBoostDb(design.bands(sampleRate: 48_000), sampleRate: 48_000)
        #expect(abs(s.preampDb - -(peak + 0.5 + EQDesign.sourceOverHeadroomDb)) < 1e-9)
        design.adaptStrength = 0.3
        #expect(abs(design.settings(sampleRate: 48_000).preampDb - (s.preampDb - EQDesign.adaptiveReserveDb)) < 1e-9)
        // AutoEq's own preamp (+0.5 headroom) for the same filters agrees with ours.
        #expect(abs(s.preampDb + EQDesign.sourceOverHeadroomDb - profile.preampDb) < 0.3)
        // Bypass is attenuated to the EQ path's loudness; never boosted.
        #expect(s.dryGainDb < 0 && s.dryGainDb > -12)
        print("preamp \(s.preampDb) dB, level-matched bypass \(s.dryGainDb) dB")
    }

    /// Real-time budget: one second of 96 kHz stereo at full strength in 256-frame callbacks.
    @Test func renderCostIsSmallFractionOfRealTime() throws {
        let fs = 96_000.0
        let kernel = readyKernel(EQDesign(profile: try loadProfile()).settings(sampleRate: fs), sampleRate: fs)
        let input = TestBuffers(frames: 256, layout: [2])
        let output = TestBuffers(frames: 256, layout: [2])
        input.fill({ ch, i in Float(sin(Double(i + ch) * 0.1)) * 0.5 }, frames: 256)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<375 { kernel.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer) }
        }
        let fraction = elapsed / .seconds(1)
        print("render cost: \(fraction * 100)% of real time")
        // Only meaningful optimised (`swift test -c release`, ~0.5 %): the app ships the
        // release build, and debug timings also swing with the other tests running in parallel.
        #if !DEBUG
        #expect(fraction < 0.05)
        #endif
    }

    @Test func tripleBufferDeliversLatest() {
        let buffer = TripleBuffer(0)
        #expect(buffer.take() == nil)
        buffer.publish(1)
        buffer.publish(2)
        #expect(buffer.take()?.pointee == 2)
        #expect(buffer.take() == nil)
        #expect(buffer.current.pointee == 2)
        buffer.publish(3)
        #expect(buffer.take()?.pointee == 3)
    }
}
