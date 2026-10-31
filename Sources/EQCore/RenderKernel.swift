import CoreAudio
import Synchronization

/// The per-callback audio path:
///
///     tap input ─┬─ biquad cascade (Float64) ─ preamp ─┬─ look-ahead limiter ─┐
///                └──────────── dry (bypass) ───────────┴─ same delay ─ gain ─┴─ cross-fade ─ fade ─ output
///
/// Threading: `render` is called only from the real-time IO thread. It does not allocate,
/// lock, log or touch Objective-C. Control threads talk to it only through atomics and the
/// `settings` triple buffer; filter coefficients are derived on the IO thread from the
/// published band parameters (pure math), with gains smoothed so changes never click.
public final class RenderKernel: @unchecked Sendable {
    /// Control side publishes, IO side takes. See `EQDesign.settings(sampleRate:)`.
    public let settings = TripleBuffer(DSPSettings())
    /// Mono (L+R)/2 history for analysis and the spectrum: tap input, and final output.
    public let inputHistory = SampleRing()
    public let outputHistory = SampleRing()
    /// (L−R)/2 of the tap input: with `inputHistory` it gives back L and R for loudness and width.
    public let sideHistory = SampleRing()

    /// Fade the whole output towards this gain (start-up / shutdown), as `Double.bitPattern`.
    private let targetGainBits = Atomic<UInt64>(0.0.bitPattern)
    private let currentGainBits = Atomic<UInt64>(0.0.bitPattern)

    /// Consecutive frames whose input was exactly zero. Reset on the first non-zero sample.
    public let silentFrames = Atomic<Int>(0)
    /// Total frames rendered since `prepare`.
    public let renderedFrames = Atomic<Int>(0)
    /// Callbacks in which input and output frame counts disagreed (should stay 0).
    public let frameMismatches = Atomic<Int>(0)
    /// Frames in which the limiter reduced gain. Should stay 0 in normal listening.
    public let limitedFrames = Atomic<Int>(0)
    /// Lowest limiter gain since the control side last called `takeMaxLimiterReductionDb()`.
    private let minLimiterGainBits = Atomic<UInt64>(1.0.bitPattern)
    /// Highest |input sample| and |EQ path sample before the limiter| since the last `takePeaks()`.
    private let inputPeakBits = Atomic<UInt64>(0.0.bitPattern)
    private let wetPeakBits = Atomic<UInt64>(0.0.bitPattern)
    /// Output sample time minus input sample time of the last callback: the measured
    /// capture-to-presentation distance inside the IO device, in frames.
    public let ioDistanceFrames = Atomic<Int>(0)

    public static let rampSeconds = 0.05
    /// Time constant for gain / preamp smoothing (≈ 120 ms to settle).
    public static let smoothingSeconds = 0.04
    public static let maxChunk = 4096
    static let controlBlock = 32
    static let maxOutputChannels = 32

    // MARK: IO-thread-only state

    private var sampleRate = 48_000.0
    private var fade = 0.0
    private var fadeStep = 0.0
    private var mix = 1.0             // 1 = EQ path, 0 = bypass path
    private var preamp = 1.0          // linear, ramped per sample
    private var dryGain = 1.0         // linear, ramped per sample
    private var preampDb = 0.0        // smoothed, per chunk
    private var dryGainDb = 0.0
    private var needsSnap = true

    private var activeCount = 0
    private let active: UnsafeMutablePointer<BandParameters>
    private let coefficients: UnsafeMutablePointer<BiquadCoefficients>
    /// z1, z2 per band per channel: [band][channel][2].
    private let state: UnsafeMutablePointer<Double>
    private let wet: UnsafeMutablePointer<Double>   // [channel][maxChunk]
    private let dry: UnsafeMutablePointer<Double>
    private let outPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let outStrides: UnsafeMutablePointer<Int>
    private let limiter = LookaheadLimiter()

    public init() {
        let bands = DSPSettings.maxBands
        active = .allocate(capacity: bands)
        active.initialize(repeating: .flat, count: bands)
        coefficients = .allocate(capacity: bands)
        coefficients.initialize(repeating: .identity, count: bands)
        state = .allocate(capacity: bands * 4)
        state.initialize(repeating: 0, count: bands * 4)
        wet = .allocate(capacity: 2 * Self.maxChunk)
        wet.initialize(repeating: 0, count: 2 * Self.maxChunk)
        dry = .allocate(capacity: 2 * Self.maxChunk)
        dry.initialize(repeating: 0, count: 2 * Self.maxChunk)
        outPointers = .allocate(capacity: Self.maxOutputChannels)
        outPointers.initialize(repeating: nil, count: Self.maxOutputChannels)
        outStrides = .allocate(capacity: Self.maxOutputChannels)
        outStrides.initialize(repeating: 0, count: Self.maxOutputChannels)
    }

    deinit {
        active.deallocate(); coefficients.deallocate(); state.deallocate()
        wet.deallocate(); dry.deallocate(); outPointers.deallocate(); outStrides.deallocate()
    }

    /// Call before the IO proc starts (never while it runs). Output fades in from silence;
    /// filters, preamp and mix start directly at the latest published settings.
    public func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        fade = 0
        fadeStep = 1.0 / max(1, Self.rampSeconds * sampleRate)
        needsSnap = true
        state.update(repeating: 0, count: DSPSettings.maxBands * 4)
        limiter.prepare(sampleRate: sampleRate)
        currentGainBits.store(0.0.bitPattern, ordering: .relaxed)
        silentFrames.store(0, ordering: .relaxed)
        renderedFrames.store(0, ordering: .relaxed)
        frameMismatches.store(0, ordering: .relaxed)
        limitedFrames.store(0, ordering: .relaxed)
        minLimiterGainBits.store(1.0.bitPattern, ordering: .relaxed)
    }

    public func setTargetGain(_ value: Double) {
        targetGainBits.store(value.bitPattern, ordering: .releasing)
    }

    public var currentGain: Double {
        Double(bitPattern: currentGainBits.load(ordering: .relaxed))
    }

    /// Highest input and pre-limiter EQ-path peaks (dBFS) since the previous call. Control side.
    public func takePeaksDb() -> (input: Double, eq: Double) {
        let i = Double(bitPattern: inputPeakBits.exchange(0.0.bitPattern, ordering: .relaxed))
        let w = Double(bitPattern: wetPeakBits.exchange(0.0.bitPattern, ordering: .relaxed))
        return (20 * log10(i), 20 * log10(w))
    }

    private static func raise(_ atomic: borrowing Atomic<UInt64>, to value: Double) {
        var old = atomic.load(ordering: .relaxed)
        while value > Double(bitPattern: old) {
            let (exchanged, current) = atomic.compareExchange(expected: old, desired: value.bitPattern, ordering: .relaxed)
            if exchanged { break }
            old = current
        }
    }

    /// Deepest limiter gain reduction (dB, <= 0) since the previous call. Control side.
    public func takeMaxLimiterReductionDb() -> Double {
        let gain = Double(bitPattern: minLimiterGainBits.exchange(1.0.bitPattern, ordering: .relaxed))
        return 20 * log10(gain)
    }

    /// Delay added by the kernel (limiter look-ahead), in frames.
    public var latencyFrames: Int { limiter.latencyFrames }

    /// Records the timestamps of the current IO cycle. Called on the IO thread.
    public func noteTimes(input: UnsafePointer<AudioTimeStamp>, output: UnsafePointer<AudioTimeStamp>) {
        let valid = AudioTimeStampFlags.sampleTimeValid
        guard input.pointee.mFlags.contains(valid), output.pointee.mFlags.contains(valid) else { return }
        ioDistanceFrames.store(Int(output.pointee.mSampleTime - input.pointee.mSampleTime), ordering: .relaxed)
    }

    // MARK: - Render

    public func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outBuffers = UnsafeMutableAudioBufferListPointer(output)

        let outFrames = Self.frameCount(outBuffers)
        let inFrames = Self.frameCount(inBuffers)
        if inFrames != outFrames && inFrames > 0 {
            frameMismatches.add(1, ordering: .relaxed)
        }
        let inChannels = Self.channelCount(inBuffers)
        let outChannels = min(Self.channelCount(outBuffers), Self.maxOutputChannels)
        for ch in 0..<outChannels {
            let c = Self.channel(outBuffers, ch)
            outPointers[ch] = c?.0
            outStrides[ch] = c?.1 ?? 0
        }
        let left = inChannels > 0 ? Self.channel(inBuffers, 0) : nil
        let right = inChannels > 1 ? Self.channel(inBuffers, 1) : left

        _ = settings.take()
        let target = settings.current
        let targetFade = Double(bitPattern: targetGainBits.load(ordering: .acquiring))
        var sawSignal = false
        var limited = 0
        var minGain = 1.0
        var inputPeak = 0.0, wetPeak = 0.0

        var done = 0
        while done < outFrames {
            let n = min(Self.maxChunk, outFrames - done)
            let valid = max(0, min(n, inFrames - done))

            // Deinterleave into Float64 (exact); missing input is silence.
            for i in 0..<n {
                var l = 0.0, r = 0.0
                if i < valid, let (p, s) = left {
                    l = Double(p[(done + i) * s])
                    if let (q, t) = right { r = Double(q[(done + i) * t]) }
                }
                if l != 0 || r != 0 { sawSignal = true }
                inputPeak = max(inputPeak, abs(l), abs(r))
                dry[i] = l; dry[Self.maxChunk + i] = r
                wet[i] = l; wet[Self.maxChunk + i] = r
            }

            // Parameters move in control blocks of 32 frames: filter coefficients, preamp and
            // dry gain all step together (in dB, same time constant), so boost and preamp stay
            // matched and each step is tiny (< 0.15 dB). Gains ramp linearly within a block.
            var sub = 0
            while sub < n {
                let m = min(Self.controlBlock, n - sub)
                updateFilters(target, frames: m)
                runCascade(offset: sub, frames: m)

                let alpha = smoothingAlpha(frames: m)
                if needsSnapGains {
                    preampDb = target.pointee.preampDb
                    dryGainDb = target.pointee.dryGainDb
                    preamp = Self.linear(preampDb)
                    dryGain = Self.linear(dryGainDb)
                    needsSnapGains = false
                } else {
                    preampDb = Self.approach(preampDb, target.pointee.preampDb, alpha)
                    dryGainDb = Self.approach(dryGainDb, target.pointee.dryGainDb, alpha)
                }
                let preampEnd = Self.linear(preampDb)
                let dryEnd = Self.linear(dryGainDb)
                let preampStep = (preampEnd - preamp) / Double(m)
                let dryStep = (dryEnd - dryGain) / Double(m)
                let mixTarget = target.pointee.eqEnabled ? 1.0 : 0.0

                for i in sub..<(sub + m) {
                    preamp += preampStep
                    dryGain += dryStep
                    if mix != mixTarget {
                        mix = mix < mixTarget ? min(mix + fadeStep, mixTarget) : max(mix - fadeStep, mixTarget)
                    }
                    if fade != targetFade {
                        fade = fade < targetFade ? min(fade + fadeStep, targetFade) : max(fade - fadeStep, targetFade)
                    }

                    let wl = wet[i] * preamp, wr = wet[Self.maxChunk + i] * preamp
                    wetPeak = max(wetPeak, abs(wl), abs(wr))
                    let o = limiter.process(wetL: wl, wetR: wr, dryL: dry[i], dryR: dry[Self.maxChunk + i])
                    if limiter.gain < 0.9999 {
                        limited += 1
                        minGain = min(minGain, limiter.gain)
                    }

                    var l: Double, r: Double
                    if mix >= 1 {
                        (l, r) = (o.wetL, o.wetR)
                    } else if mix <= 0 {
                        (l, r) = (o.dryL * dryGain, o.dryR * dryGain)
                    } else {
                        l = o.wetL * mix + o.dryL * dryGain * (1 - mix)
                        r = o.wetR * mix + o.dryR * dryGain * (1 - mix)
                    }
                    if fade != 1 { l *= fade; r *= fade }
                    inputHistory.push(Float((dry[i] + dry[Self.maxChunk + i]) * 0.5))
                    sideHistory.push(Float((dry[i] - dry[Self.maxChunk + i]) * 0.5))
                    outputHistory.push(Float((l + r) * 0.5))

                    let frame = done + i
                    for ch in 0..<outChannels {
                        guard let p = outPointers[ch] else { continue }
                        let value: Double
                        switch ch {
                        case 0: value = l
                        case 1: value = r
                        default: value = inChannels == 1 ? l : 0
                        }
                        p[frame * outStrides[ch]] = Float(value)
                    }
                }
                preamp = preampEnd
                dryGain = dryEnd
                sub += m
            }
            done += n
        }

        inputHistory.commit()
        sideHistory.commit()
        outputHistory.commit()
        currentGainBits.store(fade.bitPattern, ordering: .relaxed)
        renderedFrames.add(outFrames, ordering: .relaxed)
        Self.raise(inputPeakBits, to: inputPeak)
        Self.raise(wetPeakBits, to: wetPeak)
        if limited > 0 {
            limitedFrames.add(limited, ordering: .relaxed)
            var old = minLimiterGainBits.load(ordering: .relaxed)
            while minGain < Double(bitPattern: old) {
                let (exchanged, current) = minLimiterGainBits.compareExchange(
                    expected: old, desired: minGain.bitPattern, ordering: .relaxed)
                if exchanged { break }
                old = current
            }
        }
        if sawSignal {
            silentFrames.store(0, ordering: .relaxed)
        } else {
            silentFrames.add(outFrames, ordering: .relaxed)
        }
    }

    // MARK: - Filters

    private var needsSnapGains = true

    private func smoothingAlpha(frames: Int) -> Double {
        1 - exp(-Double(frames) / (Self.smoothingSeconds * sampleRate))
    }

    private func updateFilters(_ target: UnsafePointer<DSPSettings>, frames: Int) {
        let count = target.pointee.bandCount
        if needsSnap || count != activeCount {
            if count != activeCount { state.update(repeating: 0, count: DSPSettings.maxBands * 4) }
            for i in 0..<count {
                active[i] = target.pointee.band(i)
                coefficients[i] = active[i].coefficients(sampleRate: sampleRate)
            }
            activeCount = count
            if needsSnap {
                mix = target.pointee.eqEnabled ? 1 : 0
                needsSnapGains = true
            }
            needsSnap = false
            return
        }
        let alpha = smoothingAlpha(frames: frames)
        for i in 0..<count {
            let goal = target.pointee.band(i)
            var band = active[i]
            if goal.type != band.type || goal.frequency != band.frequency || goal.q != band.q {
                band = goal
            } else if goal.gainDb != band.gainDb {
                band.gainDb = Self.approach(band.gainDb, goal.gainDb, alpha)
            } else {
                continue
            }
            active[i] = band
            coefficients[i] = band.coefficients(sampleRate: sampleRate)
        }
    }

    /// Transposed direct form II, Float64, in place on `wet[offset ..< offset + frames]`.
    private func runCascade(offset: Int, frames: Int) {
        for b in 0..<activeCount {
            let c = coefficients[b]
            for ch in 0..<2 {
                let x = wet + ch * Self.maxChunk + offset
                let z = state + (b * 2 + ch) * 2
                var z1 = z[0], z2 = z[1]
                for i in 0..<frames {
                    let input = x[i]
                    let y = c.b0 * input + z1
                    z1 = c.b1 * input - c.a1 * y + z2
                    z2 = c.b2 * input - c.a2 * y
                    x[i] = y
                }
                // Flush denormals.
                z[0] = abs(z1) < 1e-30 ? 0 : z1
                z[1] = abs(z2) < 1e-30 ? 0 : z2
            }
        }
    }

    @inline(__always)
    static func linear(_ db: Double) -> Double { pow(10, db / 20) }

    /// One-pole step towards `goal` (in dB); snaps when closer than 0.005 dB.
    @inline(__always)
    static func approach(_ value: Double, _ goal: Double, _ alpha: Double) -> Double {
        let diff = goal - value
        return abs(diff) < 0.005 ? goal : value + diff * alpha
    }

    // MARK: - Buffer list helpers (no allocation)

    static func frameCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        guard let first = list.first, first.mNumberChannels > 0 else { return 0 }
        return Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
    }

    static func channelCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var n = 0
        for b in list { n += Int(b.mNumberChannels) }
        return n
    }

    /// Pointer to the first sample of a flat channel index and the stride between its samples.
    static func channel(_ list: UnsafeMutableAudioBufferListPointer, _ index: Int) -> (UnsafeMutablePointer<Float>, Int)? {
        var base = 0
        for b in list {
            let n = Int(b.mNumberChannels)
            if index < base + n {
                guard let data = b.mData else { return nil }
                return (data.assumingMemoryBound(to: Float.self) + (index - base), n)
            }
            base += n
        }
        return nil
    }
}
