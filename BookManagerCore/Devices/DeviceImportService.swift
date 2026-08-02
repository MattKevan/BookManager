import Foundation

public struct DeviceImportService: Sendable {
    private let transport: any DeviceTransport

    public init(transport: any DeviceTransport) {
        self.transport = transport
    }

    public func download(_ files: [DeviceFile], to directory: URL) async throws -> [URL] {
        var urls: [URL] = []
        for file in files {
            let destination = directory.appending(path: file.name)
            try await transport.download(file, to: destination)
            urls.append(destination)
        }
        return urls
    }
}
