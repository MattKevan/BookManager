import Foundation

/// Pure parsers for `adb` text output. Kept free of any process/IO so they can be
/// unit-tested without a device. Two responsibilities:
///   • parse `ls -la` directory listings (Android's toybox `ls`)
///   • parse `adb push`/`adb pull` progress lines
public enum ADBOutputParser {

    /// One entry parsed from a directory listing.
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var isDirectory: Bool
        public var isSymlink: Bool
        public var size: Int64
        public var modifiedEpoch: Int64?   // seconds since 1970 when using --time-style=+%s
    }

    /// Parse the output of:  ls -la --full-time  <dir>/
    ///
    /// toybox `ls -l --full-time` line shape (whitespace-separated):
    ///   <perms> <links> <user> <group> <size> <date> <time[.frac]> [<tz>] <name...>
    /// e.g.  -rw-rw---- 1 root everybody 12345 2023-10-17 23:01:18.053370709 +0800 photo.jpg
    /// (Older toybox like Android's 0.8.x doesn't support --time-style=+%s, so we parse the
    /// human date/time and convert to an epoch ourselves.)
    /// Directories start with 'd', symlinks with 'l' (shown as "name -> target").
    /// Lines that aren't entries (e.g. "total 123", permission errors) are skipped.
    ///
    /// Time-column format is auto-detected per line, so this works across toybox/busybox
    /// versions regardless of which `ls` flags the device accepts:
    ///   • epoch (`--time-style=+%s`):    `… <size> 1700000000 name`
    ///   • full-time (`--full-time`):     `… <size> 2023-10-17 23:01:18.053 +0800 name`
    ///   • default `ls -la`:              `… <size> 2023-10-17 23:01 name`
    ///   • busybox month form:            `… <size> Oct 17 23:01 name`  /  `… Oct 17 2023 name`
    public static func parseListing(_ output: String) -> [Entry] {
        var result: [Entry] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("total ") { continue }
            guard let first = line.first, "dl-pcbs".contains(first) else { continue }

            // Fixed leading fields: perms links user group size. Then a variable-width time
            // section, then the name. Tokenise generously and locate the name start.
            let toks = tokenize(line)
            guard toks.count >= 7 else { continue }   // perms..size + ≥1 time tok + name

            let perms = toks[0]
            let size = Int64(toks[4]) ?? 0

            // Determine how many tokens the time section occupies, starting at index 5.
            let (timeTokenCount, epoch) = parseTimeSection(Array(toks[5...]))
            let nameStart = 5 + timeTokenCount
            guard nameStart < toks.count else { continue }
            var name = toks[nameStart...].joined(separator: " ")

            let isSymlink = perms.hasPrefix("l")
            if isSymlink, let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            if name == "." || name == ".." { continue }

            result.append(Entry(name: name, isDirectory: perms.hasPrefix("d"),
                                isSymlink: isSymlink, size: size, modifiedEpoch: epoch))
        }
        return result
    }

    private static let months = ["Jan":1,"Feb":2,"Mar":3,"Apr":4,"May":5,"Jun":6,
                                 "Jul":7,"Aug":8,"Sep":9,"Oct":10,"Nov":11,"Dec":12]

    /// Given the tokens after `size`, work out how many belong to the time/date section
    /// and the epoch they represent. Returns (tokenCount, epoch?).
    private static func parseTimeSection(_ t: [String]) -> (Int, Int64?) {
        guard let first = t.first else { return (0, nil) }

        // 1) epoch: a single all-digit token (10+ digits → seconds since 1970).
        if first.allSatisfy(\.isNumber), first.count >= 8 {
            return (1, Int64(first))
        }

        // 2) ISO date "YYYY-MM-DD": next token is the time, then an optional tz (+0800).
        if isISODate(first), t.count >= 2 {
            let epoch = epochFrom(date: first, time: t[1])
            // optional timezone token
            let hasTZ = t.count >= 3 && (t[2].hasPrefix("+") || t[2].hasPrefix("-")) && t[2].dropFirst().allSatisfy(\.isNumber)
            return (hasTZ ? 3 : 2, epoch)
        }

        // 3) busybox month form: "Oct 17 23:01" or "Oct 17 2023" (3 tokens).
        if months[first] != nil, t.count >= 3 {
            let epoch = epochFromMonth(mon: first, day: t[1], timeOrYear: t[2])
            return (3, epoch)
        }

        // Unknown: assume a single time token, no epoch.
        return (1, nil)
    }

    private static func isISODate(_ s: String) -> Bool {
        let p = s.split(separator: "-")
        return p.count == 3 && p.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    private static func epochFromMonth(mon: String, day: String, timeOrYear: String) -> Int64? {
        guard let m = months[mon], let d = Int(day) else { return nil }
        var comps = DateComponents()
        comps.month = m; comps.day = d
        if timeOrYear.contains(":") {           // "23:01" → current year
            let t = timeOrYear.split(separator: ":")
            comps.year = Calendar.current.component(.year, from: Date())
            comps.hour = Int(t.first ?? "0"); comps.minute = t.count > 1 ? Int(t[1]) : 0
        } else {                                 // "2023" → midnight
            comps.year = Int(timeOrYear); comps.hour = 0; comps.minute = 0
        }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        return cal.date(from: comps).map { Int64($0.timeIntervalSince1970) }
    }

    /// Convert "YYYY-MM-DD" + "HH:MM:SS[.frac]" (device-local time) to a Unix epoch.
    /// Uses the current local time zone (the device shows local time; close enough for
    /// display/sorting). Returns nil if unparseable.
    static func epochFrom(date: String, time: String) -> Int64? {
        let hms = time.split(separator: ".").first.map(String.init) ?? time
        var comps = DateComponents()
        let d = date.split(separator: "-")
        let t = hms.split(separator: ":")
        // Time may be HH:MM (default ls) or HH:MM:SS (--full-time); seconds optional.
        guard d.count == 3, t.count >= 2,
              let y = Int(d[0]), let mo = Int(d[1]), let da = Int(d[2]),
              let h = Int(t[0]), let mi = Int(t[1]) else { return nil }
        comps.year = y; comps.month = mo; comps.day = da
        comps.hour = h; comps.minute = mi; comps.second = t.count >= 3 ? Int(t[2]) : 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        guard let date = cal.date(from: comps) else { return nil }
        return Int64(date.timeIntervalSince1970)
    }

    /// Split a line on runs of whitespace into tokens. Filenames with single spaces are
    /// re-joined later by the caller (which knows where the name section starts).
    private static func tokenize(_ line: String) -> [String] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// Parse a transfer progress percentage from an `adb push`/`pull` line.
    /// Modern adb prints lines like:
    ///   "[ 45%] /sdcard/big.bin"
    ///   "[100%] /sdcard/big.bin"
    /// Returns the percentage 0...100, or nil if the line has none.
    public static func parseProgressPercent(_ line: String) -> Int? {
        guard let lb = line.firstIndex(of: "["), let pct = line.firstIndex(of: "%") else { return nil }
        let inner = line[line.index(after: lb)..<pct].trimmingCharacters(in: .whitespaces)
        guard let value = Int(inner), (0...100).contains(value) else { return nil }
        return value
    }

    /// Parse the summary line adb prints when a transfer finishes, e.g.:
    ///   "/sdcard/big.bin: 1 file pushed, 0 skipped. 35.2 MB/s (83886080 bytes in 2.270s)"
    /// Returns total bytes if present.
    public static func parseTransferredBytes(_ line: String) -> Int64? {
        guard let open = line.range(of: "("), let bytesWord = line.range(of: " bytes") else { return nil }
        let between = line[open.upperBound..<bytesWord.lowerBound]
        return Int64(between.trimmingCharacters(in: .whitespaces))
    }
}
