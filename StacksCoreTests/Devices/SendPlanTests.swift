import Foundation
import Testing
@testable import StacksCore

@Suite
struct SendPlanTests {
    private let profile = KindlePaperwhite12Profile() // ["epub", "pdf", "azw3", "txt"]

    private func format(_ kind: String) -> BookFormatRecord {
        BookFormatRecord(kind: kind, filename: "f.\(kind.lowercased())", contentHash: "h", size: 1)
    }

    private struct FakeConverter: FormatConverter {
        let conversions: [(from: String, to: String)]
        func canConvert(from sourceFormat: String, to targetFormat: String) -> Bool {
            conversions.contains { $0.from == sourceFormat && $0.to == targetFormat }
        }
        func convert(_ source: URL, from sourceFormat: String, to targetFormat: String) async throws -> URL {
            source
        }
    }

    @Test
    func copyPicksHighestPrioritySupportedFormat() {
        let plan = SendPlan(profile: profile, converter: IdentityConverter())
        let outcome = plan.outcome(for: [format("PDF"), format("EPUB")])
        #expect(outcome == .copy(format: "epub"))
    }

    @Test
    func copyFallsBackToLowerPriorityFormat() {
        let plan = SendPlan(profile: profile, converter: IdentityConverter())
        #expect(plan.outcome(for: [format("AZW3")]) == .copy(format: "azw3"))
    }

    @Test
    func djvuOnlyIsNoCompatibleFormat() {
        let plan = SendPlan(profile: profile, converter: IdentityConverter())
        #expect(plan.outcome(for: [format("DJVU")]) == .noCompatibleFormat)
    }

    @Test
    func converterIsConsultedWhenNoDirectCopy() {
        let fake = FakeConverter(conversions: [("azw3", "epub")])
        let plan = SendPlan(profile: profile, converter: fake)
        #expect(plan.outcome(for: [format("AZW3")]) == .copy(format: "azw3")) // direct copy wins
        let epubOnly = SendPlan(profile: DeviceProfileStub(supported: ["epub"]), converter: fake)
        #expect(epubOnly.outcome(for: [format("AZW3")]) == .convert(from: "azw3", to: "epub"))
    }

    private struct DeviceProfileStub: DeviceProfile {
        let supported: [String]
        var id: String { "stub" }
        var displayName: String { "Stub" }
        var supportedFormats: [String] { supported }
        var bookFolder: DeviceFolder { DeviceFolder(path: "Books") }
        func matches(_ info: DeviceInfo) -> Bool { false }
    }
}
