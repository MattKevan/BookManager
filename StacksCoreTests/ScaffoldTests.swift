import Testing
@testable import StacksCore

@Test
func exposesLibraryFormatVersion() {
    #expect(StacksCoreVersion.libraryFormat == 1)
}
