import CoreAudio
import Testing
@testable import EQCore

@Suite struct RenderKernelTests {
    let sampleRate = 48_000.0
    let frames = 512

    @Test func fadesInFromSilenceThenPassesThroughBitExact() {
        let kernel = RenderKernel()
        kernel.prepare(sampleRate: sampleRate)
        kernel.setTargetGain(1)
        let input = TestBuffers(frames: frames, layout: [2])
        let output = TestBuffers(frames: frames, layout: [1, 1])
        input.fill({ ch, i in Float(sin(Double(i) * 0.01 + Double(ch))) * 0.9 }, frames: frames)

        // First callback starts at gain 0.
        kernel.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        #expect(output.sample(channel: 0, frame: 0) == 0)

        // 50 ms ramp at 48 kHz = 2400 frames; after 5 callbacks (2560 frames) gain is 1.
        for _ in 0..<5 {
            kernel.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        }
        #expect(kernel.currentGain == 1)
        // The input repeats every callback, so the stream is periodic: out[i] = in[i - delay].
        let delay = kernel.latencyFrames
        for ch in 0..<2 {
            for i in 0..<frames {
                let src = ((i - delay) % frames + frames) % frames
                #expect(output.sample(channel: ch, frame: i) == input.sample(channel: ch, frame: src))
            }
        }
    }

    @Test func rampTakesFiftyMilliseconds() {
        let kernel = RenderKernel()
        kernel.prepare(sampleRate: sampleRate)
        kernel.setTargetGain(1)
        let n = 1200 // 25 ms
        let input = TestBuffers(frames: n, layout: [2])
        let output = TestBuffers(frames: n, layout: [2])
        input.fill({ _, _ in 1 }, frames: n)
        kernel.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        #expect(abs(kernel.currentGain - 0.5) < 1e-9)
        // Monotonic: no zipper from per-channel restarts.
        #expect(output.sample(channel: 0, frame: n - 1) == output.sample(channel: 1, frame: n - 1))
    }

    @Test func monoInputFeedsBothChannelsAndExtraOutputsAreSilenced() {
        let kernel = RenderKernel()
        kernel.prepare(sampleRate: sampleRate)
        kernel.setTargetGain(1)
        let input = TestBuffers(frames: frames, layout: [1])
        let output = TestBuffers(frames: frames, layout: [4])
        input.fill({ _, _ in 0.25 }, frames: frames)
        output.fill({ _, _ in 9 }, frames: frames)
        for _ in 0..<10 {
            kernel.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        }
        #expect(output.sample(channel: 0, frame: 7) == 0.25)
        #expect(output.sample(channel: 1, frame: 7) == 0.25)
        #expect(output.sample(channel: 2, frame: 7) == 0.25)
        #expect(output.sample(channel: 3, frame: 7) == 0.25)
    }

    @Test func silenceCounterTracksZeroInput() {
        let kernel = RenderKernel()
        kernel.prepare(sampleRate: sampleRate)
        kernel.setTargetGain(1)
        let input = TestBuffers(frames: frames, layout: [2])
        let output = TestBuffers(frames: frames, layout: [2])
        kernel.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        kernel.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        #expect(kernel.silentFrames.load(ordering: .relaxed) == 2 * frames)
        input.fill({ _, i in i == 100 ? 1e-6 : 0 }, frames: frames)
        kernel.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        #expect(kernel.silentFrames.load(ordering: .relaxed) == 0)
    }

    @Test func fadeOutReachesZero() {
        let kernel = RenderKernel()
        kernel.prepare(sampleRate: sampleRate)
        kernel.setTargetGain(1)
        let input = TestBuffers(frames: frames, layout: [2])
        let output = TestBuffers(frames: frames, layout: [2])
        input.fill({ _, _ in 0.5 }, frames: frames)
        for _ in 0..<6 { kernel.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer) }
        kernel.setTargetGain(0)
        for _ in 0..<6 { kernel.render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer) }
        #expect(kernel.currentGain == 0)
        #expect(output.sample(channel: 0, frame: frames - 1) == 0)
    }
}
