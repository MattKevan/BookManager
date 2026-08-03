import Foundation

/// MTP/PTP container types (the `type` field of the 12-byte header).
public enum MTPContainerType: UInt16, Sendable {
    case command = 1
    case data = 2
    case response = 3
    case event = 4
}

/// MTP operation codes (the ones this file manager needs).
public enum MTPOperation: UInt16, Sendable {
    case getDeviceInfo = 0x1001
    case openSession = 0x1002
    case closeSession = 0x1003
    case getStorageIDs = 0x1004
    case getStorageInfo = 0x1005
    case getNumObjects = 0x1006
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case getObject = 0x1009
    case getThumb = 0x100A
    case deleteObject = 0x100B
    case sendObjectInfo = 0x100C
    case sendObject = 0x100D
    case moveObject = 0x1019
    case copyObject = 0x101A
    case getPartialObject = 0x101B
    case getObjectPropsSupported = 0x9801
    case getObjectPropDesc = 0x9802
    case getObjectPropValue = 0x9803
    case setObjectPropValue = 0x9804
    case getObjectPropList = 0x9805
    /// Android (android.com) MTP extension: ranged read with a 64-bit offset, for files >4 GB.
    case getPartialObject64 = 0x95C1
}

/// MTP response codes (subset).
public enum MTPResponse: UInt16, Sendable {
    case ok = 0x2001
    case generalError = 0x2002
    case sessionNotOpen = 0x2003
    case operationNotSupported = 0x2005
    case parameterNotSupported = 0x2006
    case incompleteTransfer = 0x2007
    case invalidStorageID = 0x2008
    case invalidObjectHandle = 0x2009
    case storeFull = 0x200C
    case storeReadOnly = 0x200E
    case accessDenied = 0x200F
    case invalidParentObject = 0x201A
    case invalidParameter = 0x201D
    case sessionAlreadyOpen = 0x201E
    case deviceBusy = 0x2019
}

/// MTP asynchronous event codes (sent over the interrupt endpoint). These are the
/// foundation of live sync: the device pushes these when its contents change.
public enum MTPEventCode: UInt16, Sendable {
    case objectAdded = 0x4002
    case objectRemoved = 0x4003
    case storeAdded = 0x4004
    case storeRemoved = 0x4005
    case devicePropChanged = 0x4006
    case objectInfoChanged = 0x4007
    case storageInfoChanged = 0x400C
    case objectPropChanged = 0xC801
}

/// Object format codes. `association` marks a folder; everything else is a file.
public enum MTPObjectFormat {
    public static let association: UInt16 = 0x3001
    public static let undefined: UInt16 = 0x3000
}

/// MTP object property codes (used for fast listing / rename).
public enum MTPObjectProperty {
    public static let storageID: UInt16 = 0xDC01
    public static let objectFormat: UInt16 = 0xDC02
    public static let objectSize: UInt16 = 0xDC04
    public static let objectFileName: UInt16 = 0xDC07
    public static let dateModified: UInt16 = 0xDC09
    public static let parentObject: UInt16 = 0xDC0B
}

/// Special handle meaning "the root of the storage" for GetObjectHandles / SendObjectInfo.
public let mtpRootParentHandle: UInt32 = 0xFFFFFFFF
/// "All formats" wildcard for GetObjectHandles.
public let mtpAllFormats: UInt32 = 0x00000000
