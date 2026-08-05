import Foundation
import Testing
@testable import StacksCore

@Suite
struct LibraryOpenPolicyTests {
    private let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test
    func newLibraryRequestedAsHomeOpensNew() {
        let resolution = LibraryOpenPolicy.resolve(
            existing: [], manifestID: id, intent: .home
        )
        #expect(resolution == .openNew)
    }

    @Test
    func newLibraryRequestedAsPeerOpensNew() {
        let resolution = LibraryOpenPolicy.resolve(
            existing: [], manifestID: id, intent: .peer
        )
        #expect(resolution == .openNew)
    }

    @Test
    func libraryAlreadyHomeRequestedAsHomeSelectsExisting() {
        let resolution = LibraryOpenPolicy.resolve(
            existing: [ExistingLibrary(id: id, isHome: true)],
            manifestID: id,
            intent: .home
        )
        #expect(resolution == .selectExisting(id))
    }

    @Test
    func libraryAlreadyPeerRequestedAsPeerSelectsExisting() {
        let resolution = LibraryOpenPolicy.resolve(
            existing: [ExistingLibrary(id: id, isHome: false)],
            manifestID: id,
            intent: .peer
        )
        #expect(resolution == .selectExisting(id))
    }

    @Test
    func libraryAlreadyPeerRequestedAsHomeRoleSwaps() {
        let resolution = LibraryOpenPolicy.resolve(
            existing: [ExistingLibrary(id: id, isHome: false)],
            manifestID: id,
            intent: .home
        )
        #expect(resolution == .makeHomeExisting(id))
    }

    @Test
    func libraryAlreadyHomeRequestedAsPeerSelectsExisting() {
        let resolution = LibraryOpenPolicy.resolve(
            existing: [ExistingLibrary(id: id, isHome: true)],
            manifestID: id,
            intent: .peer
        )
        #expect(resolution == .selectExisting(id))
    }

    @Test
    func nonMatchingExistingLibrariesOpenNew() {
        let resolution = LibraryOpenPolicy.resolve(
            existing: [
                ExistingLibrary(id: otherID, isHome: true),
                ExistingLibrary(id: otherID, isHome: false)
            ],
            manifestID: id,
            intent: .home
        )
        #expect(resolution == .openNew)
    }
}
