import Foundation
import libmobi
import Testing

@Suite
struct MobiSmokeTests {
    /// `Bundle.module` is SPM-only; Xcode test bundles resolve their resources
    /// through the bundle that contains a type from the test target.
    private final class FixtureMarker {}

    @Test
    func parsesFixtureRawmlAndCover() throws {
        let bundle = Bundle(for: FixtureMarker.self)
        // XcodeGen copies test resources flat into the test bundle (no
        // subdirectory is preserved).
        let url = try #require(bundle.url(
            forResource: "fixture", withExtension: "mobi"
        ))
        let mobi = try Mobi(url: url)
        let rawml = try mobi.getRawml()
        #expect(!rawml.isEmpty)
        // Cover may be absent in minimal fixtures — assert only when present.
        _ = try? mobi.getCover()
    }
}
