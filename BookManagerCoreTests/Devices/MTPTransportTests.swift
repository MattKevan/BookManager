import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct MTPTransportTests {
    /// Compilation/contract smoke: the factory enumerates without crashing and
    /// returns a result whether or not a device is attached (empty array in CI).
    @Test
    func factoryShape() async throws {
        let factory = MTPTransportFactory()
        let candidates = try? await factory.candidates()
        #expect(candidates != nil)
    }
}
