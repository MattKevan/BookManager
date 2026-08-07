import Foundation
import Testing
@testable import StacksCore

@Suite
struct BonjourTests {
    @Test
    func txtRecordCarriesIdentityAndPaths() {
        let id = UUID()
        let record = BonjourAdvertiser.txtRecord(name: "My Library", libraryID: id)
        #expect(String(data: record["name"] ?? Data(), encoding: .utf8) == "My Library")
        #expect(String(data: record["id"] ?? Data(), encoding: .utf8) == id.uuidString)
        #expect(String(data: record["v"] ?? Data(), encoding: .utf8) == "1")
        #expect(String(data: record["path"] ?? Data(), encoding: .utf8) == "/opds")
        #expect(String(data: record["api"] ?? Data(), encoding: .utf8) == "/api")
    }

    @Test
    func txtRecordEncodesToValidTXTData() {
        // NetService.data(fromTXTRecord:) must accept the builder's output —
        // a malformed record would fail at publish time.
        let data = NetService.data(fromTXTRecord: BonjourAdvertiser.txtRecord(
            name: "Books", libraryID: UUID()
        ))
        #expect(!data.isEmpty)
    }
}
