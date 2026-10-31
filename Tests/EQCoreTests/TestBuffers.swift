import CoreAudio
import Foundation
import Testing
@testable import EQCore

/// Owns the sample memory behind an AudioBufferList for tests.
final class TestBuffers {
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []

    /// `layout` lists channels per buffer, e.g. [2] = interleaved stereo, [1, 1] = planar stereo.
    init(frames: Int, layout: [Int]) {
        list = AudioBufferList.allocate(maximumBuffers: layout.count)
        for (i, channels) in layout.enumerated() {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels)
            p.initialize(repeating: 0, count: frames * channels)
            storage.append(p)
            list[i] = AudioBuffer(mNumberChannels: UInt32(channels),
                                  mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.size),
                                  mData: p)
        }
    }

    func sample(channel: Int, frame: Int) -> Float {
        let (p, stride) = RenderKernel.channel(list, channel)!
        return p[frame * stride]
    }

    func fill(_ value: (_ channel: Int, _ frame: Int) -> Float, frames: Int) {
        for ch in 0..<RenderKernel.channelCount(list) {
            let (p, stride) = RenderKernel.channel(list, ch)!
            for i in 0..<frames { p[i * stride] = value(ch, i) }
        }
    }

    deinit {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }
}


/// Streams stereo signals through the kernel in fixed blocks and returns the output.
/// The kernel is prepared at full output gain so tests see the DSP, not the start-up fade.
func runStream(_ kernel: RenderKernel, left: [Float], right: [Float], sampleRate: Double,
               block: Int = 512, beforeBlock: ((Int) -> Void)? = nil) -> (left: [Float], right: [Float]) {
    let input = TestBuffers(frames: block, layout: [2])
    let output = TestBuffers(frames: block, layout: [1, 1])
    var outL = [Float](), outR = [Float]()
    outL.reserveCapacity(left.count); outR.reserveCapacity(left.count)
    var start = 0
    while start < left.count {
        beforeBlock?(start)
        input.fill({ ch, i in
            let j = start + i
            guard j < left.count else { return 0 }
            return ch == 0 ? left[j] : right[j]
        }, frames: block)
        kernel.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        for i in 0..<min(block, left.count - start) {
            outL.append(output.sample(channel: 0, frame: i))
            outR.append(output.sample(channel: 1, frame: i))
        }
        start += block
    }
    return (outL, outR)
}

/// A kernel already faded in, with `settings` applied.
func readyKernel(_ settings: DSPSettings, sampleRate: Double) -> RenderKernel {
    let kernel = RenderKernel()
    kernel.settings.publish(settings)
    kernel.prepare(sampleRate: sampleRate)
    kernel.setTargetGain(1)
    let silence = [Float](repeating: 0, count: Int(sampleRate * 0.1))
    _ = runStream(kernel, left: silence, right: silence, sampleRate: sampleRate)
    return kernel
}

/// Magnitude in dB of the DFT of `x` at frequency `f` (single bin, exact frequency).
func dftMagnitudeDb(_ x: [Float], at f: Double, sampleRate: Double) -> Double {
    var re = 0.0, im = 0.0
    let w = 2 * Double.pi * f / sampleRate
    for (n, v) in x.enumerated() {
        re += Double(v) * cos(w * Double(n))
        im -= Double(v) * sin(w * Double(n))
    }
    return 10 * log10(re * re + im * im)
}

func loadProfile() throws -> Profile {
    let url = try #require(Bundle.module.url(forResource: "s12-ultra", withExtension: "json", subdirectory: "Fixtures"))
    return try Profile.load(from: url)
}
