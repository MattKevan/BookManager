import Foundation

public struct SendRequest: Sendable {
    public let title: String
    public let sourceURL: URL
    public let format: String // lowercase extension

    public init(title: String, sourceURL: URL, format: String) {
        self.title = title
        self.sourceURL = sourceURL
        self.format = format
    }
}

public struct DeviceSendService: Sendable {
    private let transport: any DeviceTransport

    public init(transport: any DeviceTransport) {
        self.transport = transport
    }

    public func send(
        _ requests: [SendRequest],
        profile: any DeviceProfile,
        converter: any FormatConverter
    ) async -> [SendItem] {
        var items: [SendItem] = []
        for request in requests {
            do {
                let format = request.format.lowercased()
                if profile.supportedFormats.contains(format) {
                    try await transport.upload(
                        request.sourceURL,
                        to: profile.bookFolder,
                        as: Self.filename(for: request, format: format)
                    )
                    items.append(SendItem(title: request.title, status: .sent(format: format)))
                } else if let target = profile.supportedFormats.first(where: {
                    converter.canConvert(from: format, to: $0)
                }) {
                    let converted = try await converter.convert(request.sourceURL, from: format, to: target)
                    try await transport.upload(
                        converted,
                        to: profile.bookFolder,
                        as: Self.filename(for: request, format: target)
                    )
                    items.append(SendItem(title: request.title, status: .converted(from: format, to: target)))
                } else {
                    items.append(SendItem(title: request.title, status: .noCompatibleFormat))
                }
            } catch {
                items.append(SendItem(title: request.title, status: .failed(error.localizedDescription)))
            }
        }
        return items
    }

    /// Builds the on-device filename from a request title. Device file systems
    /// reject path separators and control characters in names, so every
    /// reserved character is replaced with a space before the extension.
    static func filename(for request: SendRequest, format: String) -> String {
        var illegal = CharacterSet(charactersIn: "/:\\")
        illegal.formUnion(.controlCharacters)
        let base = request.title
            .components(separatedBy: illegal)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        // Keep the extension even for empty titles: an extension-less upload
        // would be unrecognizable as a book on the device.
        return base.isEmpty ? "book.\(format)" : "\(base).\(format)"
    }
}
