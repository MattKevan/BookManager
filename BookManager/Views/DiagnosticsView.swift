import SwiftUI

/// Placeholder — real diagnostics sheet arrives in Task 8.
struct DiagnosticsView: View {
    var body: some View {
        VStack {
            Text("Diagnostics")
                .font(.headline)
            Text("Library diagnostics arrive in the next delivery slice.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 520, minHeight: 300)
    }
}
