import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct LibraryRootCapabilitiesTests {
    @Test
    func localRootReportsNoCloudFlags() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let caps = LibraryRootCapabilities.probe(dir)
        #expect(!caps.isUbiquitous)
        #expect(!caps.isNetworkMount)
        #expect(!caps.isICloudDrive)
    }

    @Test
    func iCloudDrivePathHeuristicDetectsCloudDocs() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        let caps = LibraryRootCapabilities.probe(url)
        #expect(caps.isICloudDrive)
    }
}
