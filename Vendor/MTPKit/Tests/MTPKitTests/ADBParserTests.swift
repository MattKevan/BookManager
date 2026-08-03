import Testing
import Foundation
@testable import MTPKit

@Suite struct ADBParserTests {

    // Lines in `ls -la --full-time` format (Android toybox 0.8.x).
    @Test func parsesTypicalListing() {
        let out = """
        total 81
        drwxrwx--- 4 root everybody 3488 2026-05-30 17:58:06.602198059 +0800 DCIM
        drwxrwx--- 2 root everybody 118784 2026-05-31 10:51:22.288254435 +0800 Download
        -rw-rw---- 1 root everybody 2097152 2023-10-17 23:01:18.053370709 +0800 photo.jpg
        -rw-rw---- 1 root everybody 33 2021-03-08 19:08:10.704877534 +0800 .tcookieid
        """
        let entries = ADBOutputParser.parseListing(out)
        #expect(entries.count == 4)

        let dcim = entries[0]
        #expect(dcim.name == "DCIM")
        #expect(dcim.isDirectory)
        #expect(dcim.modifiedEpoch != nil)

        let photo = entries[2]
        #expect(photo.name == "photo.jpg")
        #expect(!photo.isDirectory)
        #expect(photo.size == 2097152)
    }

    @Test func skipsTotalAndDotEntries() {
        let out = """
        total 16
        drwxrwx--x 5 root everybody 4096 2026-05-30 17:58:06.000000000 +0800 .
        drwxrwx--x 20 root root 4096 2026-05-30 17:00:00.000000000 +0800 ..
        -rw-rw---- 1 root everybody 100 2026-05-30 18:00:00.000000000 +0800 keep.txt
        """
        let entries = ADBOutputParser.parseListing(out)
        #expect(entries.count == 1)
        #expect(entries[0].name == "keep.txt")
    }

    @Test func handlesFilenamesWithSpaces() {
        let out = "-rw-rw---- 1 root everybody 500 2026-05-30 18:00:00.000000000 +0800 my holiday photo.jpg"
        let entries = ADBOutputParser.parseListing(out)
        #expect(entries.count == 1)
        #expect(entries[0].name == "my holiday photo.jpg")
        #expect(entries[0].size == 500)
    }

    @Test func parsesSymlinkAndKeepsLinkName() {
        let out = "lrw-r--r-- 1 root root 21 2009-01-01 08:00:00.000000000 +0800 sdcard -> /storage/self/primary"
        let entries = ADBOutputParser.parseListing(out)
        #expect(entries.count == 1)
        #expect(entries[0].name == "sdcard")
        #expect(entries[0].isSymlink)
    }

    @Test func skipsPermissionErrorLines() {
        let out = """
        ls: ./Android/data: Permission denied
        -rw-rw---- 1 root everybody 10 2026-05-30 18:00:00.000000000 +0800 ok.txt
        """
        let entries = ADBOutputParser.parseListing(out)
        #expect(entries.count == 1)
        #expect(entries[0].name == "ok.txt")
    }

    // Format auto-detection across toybox/busybox variants.
    @Test func parsesEpochTimeStyle() {
        // ls -la --time-style=+%s
        let out = "-rw-rw---- 1 root everybody 2097152 1700000000 photo.jpg"
        let e = ADBOutputParser.parseListing(out)
        #expect(e.count == 1)
        #expect(e[0].name == "photo.jpg")
        #expect(e[0].size == 2097152)
        #expect(e[0].modifiedEpoch == 1700000000)
    }

    @Test func parsesDefaultDateTime() {
        // default `ls -la` (no fractional seconds, no tz): "YYYY-MM-DD HH:MM"
        let out = "drwxrwx--- 4 root everybody 3488 2026-05-30 17:58 DCIM"
        let e = ADBOutputParser.parseListing(out)
        #expect(e.count == 1)
        #expect(e[0].name == "DCIM")
        #expect(e[0].isDirectory)
        #expect(e[0].modifiedEpoch != nil)
    }

    @Test func parsesBusyboxMonthForm() {
        // busybox: "Mon DD HH:MM" and "Mon DD YYYY"
        let out = """
        -rw-r--r-- 1 root root 100 Oct 17 23:01 recent.txt
        -rw-r--r-- 1 root root 200 Mar  8 2021 old.txt
        """
        let e = ADBOutputParser.parseListing(out)
        #expect(e.count == 2)
        #expect(e[0].name == "recent.txt")
        #expect(e[1].name == "old.txt")
        #expect(e[0].modifiedEpoch != nil)
        #expect(e[1].modifiedEpoch != nil)
    }

    @Test func epochConversionRoundTrips() {
        // 2023-10-17 23:01:18 local → a positive epoch that re-formats to the same Y-M-D.
        let epoch = ADBOutputParser.epochFrom(date: "2023-10-17", time: "23:01:18.053370709")
        #expect(epoch != nil)
        if let epoch {
            let date = Date(timeIntervalSince1970: TimeInterval(epoch))
            var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
            let c = cal.dateComponents([.year, .month, .day, .hour], from: date)
            #expect(c.year == 2023 && c.month == 10 && c.day == 17 && c.hour == 23)
        }
    }

    @Test func parsesProgressPercent() {
        #expect(ADBOutputParser.parseProgressPercent("[ 45%] /sdcard/big.bin") == 45)
        #expect(ADBOutputParser.parseProgressPercent("[100%] /sdcard/big.bin") == 100)
        #expect(ADBOutputParser.parseProgressPercent("[  0%] /sdcard/big.bin") == 0)
        #expect(ADBOutputParser.parseProgressPercent("no percent here") == nil)
    }

    @Test func parsesTransferredBytes() {
        let line = "/sdcard/big.bin: 1 file pushed, 0 skipped. 35.2 MB/s (83886080 bytes in 2.270s)"
        #expect(ADBOutputParser.parseTransferredBytes(line) == 83886080)
        #expect(ADBOutputParser.parseTransferredBytes("no bytes info") == nil)
    }
}
