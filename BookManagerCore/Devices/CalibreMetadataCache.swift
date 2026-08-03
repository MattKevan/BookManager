import Foundation

/// One book's cached device metadata, as Calibre stores it in the device-side
/// `metadata.calibre` file (a JSON array of book objects). Only the fields the
/// app consumes are decoded; every other key is carried through verbatim by
/// `CalibreCache` for read-modify-write round-trips.
public struct CalibreCacheEntry: Sendable {
    /// Device-relative path, e.g. "documents/Book - Author.mobi". Calibre
    /// matches cache entries to device files by lowercased lpath + exact size.
    public let lpath: String
    /// File size in bytes — the cache-hit short-circuit key.
    public let size: Int64
    public let title: String
    public let authors: [String]
    public let mime: String?
    /// Calibre's page count; `-3` is its convention for "DRMed".
    public let pages: Int?

    public init(lpath: String, size: Int64, title: String, authors: [String], mime: String?, pages: Int?) {
        self.lpath = lpath
        self.size = size
        self.title = title
        self.authors = authors
        self.mime = mime
        self.pages = pages
    }

    /// Calibre marks DRMed books with a page count of -3.
    public var isDRM: Bool { pages == -3 }
}

/// The parsed `metadata.calibre` cache, with read-modify-write support that
/// preserves every field the app does not model (thumbnails, comments, user
/// metadata, …).
///
/// Not Sendable: it holds the original JSON objects for round-trip fidelity,
/// and is used within a single flow (the app's MainActor device store). Do not
/// pass it across isolation domains.
public struct CalibreCache {
    /// Decoded entries; books whose cache record is unusable are skipped.
    public let entries: [CalibreCacheEntry]
    /// The original JSON objects, kept so `mergedData` can patch in place
    /// without losing fields this type does not model.
    private let rawObjects: [[String: Any]]

    /// Tolerant parse: a malformed document yields an empty cache, never a
    /// throw (a missing/invalid `metadata.calibre` degrades to the filename
    /// listing path).
    public init(jsonData: Data) {
        let parsed = (try? JSONSerialization.jsonObject(with: jsonData)) as? [[String: Any]] ?? []
        self.rawObjects = parsed
        self.entries = parsed.compactMap { obj in
            guard let lpath = obj["lpath"] as? String else { return nil }
            let size = (obj["size"] as? NSNumber)?.int64Value ?? 0
            let title = (obj["title"] as? String) ?? ""
            let authors = (obj["authors"] as? [String]) ?? []
            let mime = obj["mime"] as? String
            let pages = (obj["pages"] as? NSNumber)?.intValue
            return CalibreCacheEntry(
                lpath: lpath, size: size, title: title, authors: authors,
                mime: mime, pages: pages
            )
        }
    }

    /// Cache hit: lowercase `lpath` equals the file's path AND the stored size
    /// equals the file's size. Size is the freshness key — a book whose file
    /// changed (or was re-synced) no longer matches and must be re-read.
    public func entry(matching file: DeviceFile) -> CalibreCacheEntry? {
        let path = file.path.lowercased()
        return entries.first { $0.lpath.lowercased() == path && $0.size == file.size }
    }

    /// Read-modify-write over the original JSON: patches matching entries in
    /// place (case-insensitive lpath match), appends entries that match
    /// nothing, and leaves every unknown field and untouched book object
    /// intact. Returns the serialized JSON array for the write-back upload.
    public func mergedData(
        updating updates: [CalibreCacheEntry],
        adding additions: [CalibreCacheEntry]
    ) -> Data {
        var objects = rawObjects

        func patch(_ entry: CalibreCacheEntry) {
            let key = entry.lpath.lowercased()
            if let index = objects.firstIndex(where: { ($0["lpath"] as? String)?.lowercased() == key }) {
                var obj = objects[index]
                obj["title"] = entry.title
                obj["authors"] = entry.authors
                obj["size"] = entry.size
                if let mime = entry.mime {
                    obj["mime"] = mime
                } else {
                    obj.removeValue(forKey: "mime")
                }
                if let pages = entry.pages {
                    obj["pages"] = pages
                } else {
                    obj.removeValue(forKey: "pages")
                }
                objects[index] = obj
            } else {
                var obj: [String: Any] = [
                    "lpath": entry.lpath,
                    "size": entry.size,
                    "title": entry.title,
                    "authors": entry.authors,
                ]
                if let mime = entry.mime { obj["mime"] = mime }
                if let pages = entry.pages { obj["pages"] = pages }
                objects.append(obj)
            }
        }

        for entry in updates { patch(entry) }
        for entry in additions { patch(entry) }

        // sortedKeys keeps the write deterministic across runs.
        return (try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]))
            ?? Data("[]".utf8)
    }
}
