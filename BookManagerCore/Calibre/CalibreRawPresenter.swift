import Foundation

/// One display row for the inspector's Calibre source-data section.
public struct CalibreRawRow: Identifiable, Equatable, Sendable {
    /// The stable rawMetadata key this row came from.
    public let id: String
    public let label: String
    public let value: String

    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

/// Renders the preserved `rawMetadata` payload (Plan 1) for display: custom
/// columns with friendly names resolved from `calibre.customColumns`, then the
/// fixed scalar keys. The payload is opaque and must never crash the UI — every
/// decode failure degrades to a row carrying the raw value.
public enum CalibreRawPresenter {
    private static let customPrefix = "calibre.custom."

    /// Scalar keys in fixed display order: (key, label).
    private static let scalarKeys: [(key: String, label: String)] = [
        ("calibre.uuid", "Calibre UUID"),
        ("calibre.titleSort", "Title Sort"),
        ("calibre.authorSort", "Author Sort"),
        ("calibre.sourcePath", "Source Path"),
        ("calibre.lastModified", "Source Modified"),
        ("calibre.pages", "Pages"),
        ("calibre.conversionOptions", "Conversion Options"),
        ("calibre.originalFormats", "Original Formats"),
    ]

    public static func rows(from rawMetadata: [String: String]) -> [CalibreRawRow] {
        let definitions = parseDefinitions(rawMetadata["calibre.customColumns"])
        var rows: [CalibreRawRow] = []

        let customKeys = rawMetadata.keys
            .filter { $0.hasPrefix(customPrefix) && !$0.hasSuffix(".extra") }
            .sorted()
        for key in customKeys {
            let label = String(key.dropFirst(customPrefix.count))
            let definition = definitions[label]
            var value = valueString(rawMetadata[key], multiple: definition?.isMultiple ?? false)
            let extraKey = "\(key).extra"
            if let extra = rawMetadata[extraKey], let extras = decodeStringArray(extra), !extras.isEmpty {
                let nonEmpty = extras.filter { !$0.isEmpty }
                if !nonEmpty.isEmpty {
                    value += " (extras: \(nonEmpty.joined(separator: ", ")))"
                }
            }
            rows.append(CalibreRawRow(id: key, label: definition?.name ?? label, value: value))
        }

        for (key, label) in scalarKeys {
            guard let value = rawMetadata[key] else { continue }
            rows.append(CalibreRawRow(id: key, label: label, value: summarize(key: key, value: value)))
        }
        return rows
    }

    private static func parseDefinitions(_ json: String?) -> [String: CalibreColumnDefinition] {
        guard let json, let data = json.data(using: .utf8),
              let defs = try? JSONDecoder().decode([String: CalibreColumnDefinition].self, from: data) else {
            return [:]
        }
        return defs
    }

    private static func decodeStringArray(_ json: String) -> [String]? {
        guard let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return array
    }

    private static func valueString(_ value: String?, multiple: Bool) -> String {
        guard let value, !value.isEmpty else { return "" }
        if multiple, let array = decodeStringArray(value) {
            return array.joined(separator: ", ")
        }
        return value
    }

    private static func summarize(key: String, value: String) -> String {
        switch key {
        case "calibre.pages":
            return value == "0" ? "Unknown" : value
        case "calibre.conversionOptions":
            guard let data = value.data(using: .utf8),
                  let options = try? JSONDecoder().decode([[String: String]].self, from: data) else {
                return value
            }
            let formats = options.compactMap { $0["format"] }
            return formats.isEmpty ? value : "\(formats.count) format\(formats.count == 1 ? "" : "s")"
        case "calibre.originalFormats":
            guard let data = value.data(using: .utf8),
                  let formats = try? JSONDecoder().decode([[String: String]].self, from: data) else {
                return value
            }
            let names = formats.compactMap { $0["format"] }
            return names.isEmpty ? value : names.joined(separator: ", ")
        default:
            return value
        }
    }
}
