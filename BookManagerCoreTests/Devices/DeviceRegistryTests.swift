import Testing
@testable import BookManagerCore

@Suite
struct DeviceRegistryTests {
    @Test
    func resolvesAmazonVendorToPaperwhiteProfile() {
        let registry = DeviceRegistry()
        let info = DeviceInfo(name: "Kindle", vendorID: 0x1949, productID: 0x9023)
        let profile = registry.resolve(info)
        #expect(profile?.id == "kindle-paperwhite-12")
        #expect(profile?.supportedFormats == ["epub", "pdf", "azw3", "txt"])
        #expect(profile?.bookFolder == DeviceFolder(path: "Documents"))
    }

    @Test
    func unknownVendorIsNotResolved() {
        let registry = DeviceRegistry()
        let info = DeviceInfo(name: "Something Else", vendorID: 0x1234, productID: 0x0001)
        #expect(registry.resolve(info) == nil)
    }

    @Test
    func stubProfileResolvesAlongsideKindle() {
        // Modularity guard: a new device profile is a new file + registry entry.
        struct StubProfile: DeviceProfile {
            let id = "stub-device"
            let displayName = "Stub"
            let supportedFormats = ["epub"]
            let bookFolder = DeviceFolder(path: "Books")
            func matches(_ info: DeviceInfo) -> Bool { info.vendorID == 0xABCD }
        }
        let registry = DeviceRegistry(profiles: [KindlePaperwhite12Profile(), StubProfile()])
        let kindle = registry.resolve(DeviceInfo(name: "K", vendorID: 0x1949, productID: nil))
        let stub = registry.resolve(DeviceInfo(name: "S", vendorID: 0xABCD, productID: nil))
        #expect(kindle?.id == "kindle-paperwhite-12")
        #expect(stub?.id == "stub-device")
    }

    @Test
    func priorityGoesToFirstMatchingProfile() {
        struct CatchAll: DeviceProfile {
            let id = "catch-all"
            let displayName = "Catch"
            let supportedFormats = ["epub"]
            let bookFolder = DeviceFolder(path: "Books")
            func matches(_ info: DeviceInfo) -> Bool { true }
        }
        let registry = DeviceRegistry(profiles: [KindlePaperwhite12Profile(), CatchAll()])
        #expect(registry.resolve(DeviceInfo(name: "K", vendorID: 0x1949, productID: nil))?.id == "kindle-paperwhite-12")
    }
}
