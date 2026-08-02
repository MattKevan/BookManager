import Foundation

public struct DeviceBookRecord: Sendable, Equatable, Identifiable {
    public let file: DeviceFile
    public let title: String
    public let authors: [String]
    public let format: String
    public let isDRM: Bool

    public init(file: DeviceFile, title: String, authors: [String], format: String, isDRM: Bool) {
        self.file = file
        self.title = title
        self.authors = authors
        self.format = format
        self.isDRM = isDRM
    }

    public var id: String { file.id }
}

public struct DeviceBookScanner: Sendable {
    private static let bookExtensions: Set<String> = ["mobi", "azw", "azw3", "epub", "pdf", "kfx", "prc", "txt"]

    private let transport: any DeviceTransport

    public init(transport: any DeviceTransport) {
        self.transport = transport
    }

    public func scan(in folder: DeviceFolder) async throws -> [DeviceBookRecord] {
        let files = try await transport.listFiles(in: folder)
            .filter { !$0.name.hasPrefix(".") && Self.isBookFile($0) }

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var records: [DeviceBookRecord] = []
        for file in files {
            let ext = URL(fileURLWithPath: file.name).pathExtension.lowercased()
            let localURL = scratch.appending(path: file.name)
            switch ext {
            case "mobi", "azw", "azw3":
                try? await transport.download(file, to: localURL)
                do {
                    let content = try MobiReader(url: localURL).extract()
                    records.append(DeviceBookRecord(
                        file: file,
                        title: content.title.isEmpty ? stem(of: file.name) : content.title,
                        authors: content.authors,
                        format: ext.uppercased(),
                        isDRM: false
                    ))
                } catch MobiReaderError.drmProtected {
                    records.append(DeviceBookRecord(
                        file: file, title: stem(of: file.name), authors: [],
                        format: ext.uppercased(), isDRM: true
                    ))
                } catch {
                    records.append(DeviceBookRecord(
                        file: file, title: stem(of: file.name), authors: [],
                        format: ext.uppercased(), isDRM: false
                    ))
                }
            case "epub", "pdf":
                try? await transport.download(file, to: localURL)
                let kind = MetadataExtractor.kind(for: localURL)
                let extracted = kind.flatMap { try? MetadataExtractor.extract(from: localURL, kind: $0) }
                records.append(DeviceBookRecord(
                    file: file,
                    title: (extracted.map { $0.title.isEmpty ? stem(of: file.name) : $0.title }) ?? stem(of: file.name),
                    authors: extracted?.authors ?? [],
                    format: ext.uppercased(),
                    isDRM: false
                ))
            default: // kfx, prc, txt — filename-only listing (KFX shown as unsupported by the UI)
                records.append(DeviceBookRecord(
                    file: file, title: stem(of: file.name), authors: [],
                    format: ext.uppercased(), isDRM: false
                ))
            }
        }
        return records
    }

    private static func isBookFile(_ file: DeviceFile) -> Bool {
        bookExtensions.contains(URL(fileURLWithPath: file.name).pathExtension.lowercased())
    }

    private func stem(of name: String) -> String {
        URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    }
}
