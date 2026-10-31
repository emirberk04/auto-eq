import Foundation

/// ISO 226:2003 equal-loudness contours, for L2 loudness compensation (CLAUDE.md §5.3): at a
/// lower listening level the ear loses more bass (and some top) than midrange, so quieter
/// playback gets back what a louder one would have had.
public enum EqualLoudness {
    static let frequencies: [Double] = [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500,
                                        630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000,
                                        10000, 12500]
    static let af: [Double] = [0.532, 0.506, 0.480, 0.455, 0.432, 0.409, 0.387, 0.367, 0.349, 0.330, 0.315,
                               0.301, 0.288, 0.276, 0.267, 0.259, 0.253, 0.250, 0.246, 0.244, 0.243, 0.243,
                               0.243, 0.242, 0.242, 0.245, 0.254, 0.271, 0.301]
    static let lu: [Double] = [-31.6, -27.2, -23.0, -19.1, -15.9, -13.0, -10.3, -8.1, -6.2, -4.5, -3.1, -2.0,
                               -1.1, -0.4, 0.0, 0.3, 0.5, 0.0, -2.7, -4.1, -1.0, 1.7, 2.5, 1.2, -2.1, -7.1,
                               -11.2, -10.7, -3.1]
    static let tf: [Double] = [78.5, 68.7, 59.5, 51.1, 44.0, 37.5, 31.5, 26.5, 22.1, 17.9, 14.4, 11.4, 8.6,
                               6.2, 4.4, 3.0, 2.2, 2.4, 3.5, 1.7, -1.3, -4.2, -6.0, -5.4, -1.5, 6.0, 12.6,
                               13.9, 12.3]

    /// Sound pressure level (dB) of a tone at table index `i` that sounds as loud as `phon`.
    static func spl(index i: Int, phon: Double) -> Double {
        let a = 4.47e-3 * (pow(10, 0.025 * phon) - 1.15) + pow(0.4 * pow(10, (tf[i] + lu[i]) / 10 - 9), af[i])
        return 10 / af[i] * log10(a) - lu[i] + 94
    }

    /// Sound pressure level for any frequency in 20 Hz – 12.5 kHz (log-interpolated).
    public static func spl(frequency f: Double, phon: Double) -> Double {
        let x = log(min(max(f, frequencies.first!), frequencies.last!))
        var i = 0
        while i < frequencies.count - 2 && log(frequencies[i + 1]) < x { i += 1 }
        let x0 = log(frequencies[i]), x1 = log(frequencies[i + 1])
        let t = (x - x0) / (x1 - x0)
        return spl(index: i, phon: phon) * (1 - t) + spl(index: i + 1, phon: phon) * t
    }

    /// Boost (dB, relative to 1 kHz) that makes `frequency` heard at `phon` balance like it does
    /// at `referencePhon`. Positive when listening below the reference.
    public static func compensationDb(frequency f: Double, phon: Double, referencePhon: Double) -> Double {
        (spl(frequency: f, phon: phon) - spl(frequency: 1000, phon: phon))
            - (spl(frequency: f, phon: referencePhon) - spl(frequency: 1000, phon: referencePhon))
    }
}
