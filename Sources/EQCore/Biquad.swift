import Foundation

/// Normalised biquad coefficients (a0 = 1), RBJ Audio EQ Cookbook.
public struct BiquadCoefficients: Sendable, Equatable, BitwiseCopyable {
    public var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    public static let identity = BiquadCoefficients()

    public init() {}

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        (self.b0, self.b1, self.b2, self.a1, self.a2) = (b0, b1, b2, a1, a2)
    }

    /// Pure math (sin/cos/pow), no allocation: safe to call on the IO thread.
    public init(_ type: Profile.Filter.Kind, frequency: Double, q: Double, gainDb: Double, sampleRate: Double) {
        let nyquistSafe = min(frequency, sampleRate * 0.49)
        let w0 = 2 * Double.pi * nyquistSafe / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * q)
        let a = pow(10, gainDb / 40)
        var b0, b1, b2, a0, a1, a2: Double
        switch type {
        case .peaking:
            b0 = 1 + alpha * a; b1 = -2 * cosw; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cosw; a2 = 1 - alpha / a
        case .lowShelf:
            let s = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) - (a - 1) * cosw + s)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
            b2 = a * ((a + 1) - (a - 1) * cosw - s)
            a0 = (a + 1) + (a - 1) * cosw + s
            a1 = -2 * ((a - 1) + (a + 1) * cosw)
            a2 = (a + 1) + (a - 1) * cosw - s
        case .highShelf:
            let s = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) + (a - 1) * cosw + s)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
            b2 = a * ((a + 1) + (a - 1) * cosw - s)
            a0 = (a + 1) - (a - 1) * cosw + s
            a1 = 2 * ((a - 1) - (a + 1) * cosw)
            a2 = (a + 1) - (a - 1) * cosw - s
        }
        self.init(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Magnitude response in dB at `frequency`.
    public func magnitudeDb(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }
}

/// One EQ band as the control side describes it.
public struct BandParameters: Sendable, Equatable, BitwiseCopyable {
    public var type: Profile.Filter.Kind
    public var frequency: Double
    public var q: Double
    public var gainDb: Double

    public init(type: Profile.Filter.Kind, frequency: Double, q: Double, gainDb: Double) {
        (self.type, self.frequency, self.q, self.gainDb) = (type, frequency, q, gainDb)
    }

    public func coefficients(sampleRate: Double) -> BiquadCoefficients {
        BiquadCoefficients(type, frequency: frequency, q: q, gainDb: gainDb, sampleRate: sampleRate)
    }
}
