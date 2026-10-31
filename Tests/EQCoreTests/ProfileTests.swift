import Foundation
import Testing
@testable import EQCore

@Suite struct ProfileTests {
    @Test func s12UltraProfileRespectsSpecLimits() throws {
        let url = try #require(Bundle.module.url(forResource: "s12-ultra", withExtension: "json", subdirectory: "Fixtures"))
        let profile = try Profile.load(from: url)

        #expect(profile.filters.count <= 8)
        #expect((0.5...0.6).contains(profile.defaultStrength))
        for f in profile.filters {
            #expect(abs(f.gain) <= 6.0, "gain \(f.gain) at \(f.frequency) Hz")
            #expect(f.frequency <= 10_000)
            #expect(f.q <= (f.frequency > 4000 ? 2.0 : 3.0), "Q \(f.q) at \(f.frequency) Hz")
        }
    }
}
