import Foundation

/// A fixed headphone correction (L0), produced offline by tools/generate_profile.py.
public struct Profile: Codable, Sendable, Equatable {
    public struct Filter: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable, BitwiseCopyable {
            case peaking, lowShelf, highShelf
        }

        public var type: Kind
        public var frequency: Double
        public var q: Double
        public var gain: Double
    }

    public var name: String
    public var defaultStrength: Double
    /// Preamp for the profile at full strength (dB, negative).
    public var preampDb: Double
    public var filters: [Filter]

    public static func load(from url: URL) throws -> Profile {
        try JSONDecoder().decode(Profile.self, from: Data(contentsOf: url))
    }
}
