import BookManagerCore
import SwiftUI

/// Placeholder — real import report arrives in Task 8.
struct ImportReportView: View {
    let report: ImportReport
    let onClose: () -> Void

    var body: some View {
        VStack {
            Text("Import Complete")
                .font(.headline)
            Text(report.summary)
                .foregroundStyle(.secondary)
            Button("Done", action: onClose)
                .buttonStyle(.borderedProminent)
                .padding()
        }
        .padding()
        .frame(minWidth: 480, minHeight: 300)
    }
}
