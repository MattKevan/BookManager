import StacksCore
import SwiftUI

/// Result sheet for a send-to-device run: what was copied, what had no
/// compatible format on the device, and what failed. Mirrors ImportReportView.
struct SendReportView: View {
    let report: SendReport
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Send to Device")
                .font(.headline)
                .padding()
            List {
                Text(report.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Section("Sent") {
                    ForEach(report.sent, id: \.id) { item in
                        row(item, icon: "checkmark.circle", color: .green)
                    }
                }
                if !report.noCompatible.isEmpty {
                    Section("No compatible format") {
                        ForEach(report.noCompatible, id: \.id) { item in
                            row(item, icon: "exclamationmark.circle", color: .orange)
                        }
                    }
                }
                if !report.failed.isEmpty {
                    Section("Failed") {
                        ForEach(report.failed, id: \.id) { item in
                            row(item, icon: "xmark.circle", color: .red)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { onDone() }
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private func row(_ item: SendItem, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color)
            Text(item.title)
            Spacer()
            if case .sent(let format) = item.status {
                Text(format.uppercased()).font(.caption).foregroundStyle(.secondary)
            } else if case .failed(let message) = item.status {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
