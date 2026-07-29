import Testing
@testable import BookManagerCore

@Test
func exposesLibraryFormatVersion() {
    #expect(BookManagerCoreVersion.libraryFormat == 1)
}
