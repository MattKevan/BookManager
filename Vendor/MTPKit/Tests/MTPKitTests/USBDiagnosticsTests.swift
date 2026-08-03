import Testing
@testable import MTPKit

@Suite struct USBDiagnosticsTests {
    /// Smoke test: the IOKit enumeration must run and produce a non-empty report
    /// without crashing. (It cannot assert a specific device is attached.)
    @Test func scanRunsAndReports() {
        let report = USBDiagnostics.report()
        #expect(!report.isEmpty)
        print("\n=== USBDiagnostics.report() ===\n\(report)\n=== end ===\n")
    }
}
