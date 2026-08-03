import Foundation

/// Localized lookup against MTPKit's own bundle (en / zh-Hant).
func L(_ key: String, _ args: CVarArg...) -> String {
    let fmt = Bundle.module.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? fmt : String(format: fmt, arguments: args)
}

public extension MTPResponse {
    /// Friendly, user-facing explanation of a response code (localized).
    var localizedMessage: String {
        switch self {
        case .ok: return L("mtp.ok")
        case .generalError: return L("mtp.generalError")
        case .sessionNotOpen: return L("mtp.sessionNotOpen")
        case .operationNotSupported: return L("mtp.operationNotSupported")
        case .parameterNotSupported: return L("mtp.parameterNotSupported")
        case .incompleteTransfer: return L("mtp.incompleteTransfer")
        case .invalidStorageID: return L("mtp.invalidStorageID")
        case .invalidObjectHandle: return L("mtp.invalidObjectHandle")
        case .storeFull: return L("mtp.storeFull")
        case .storeReadOnly: return L("mtp.storeReadOnly")
        case .accessDenied: return L("mtp.accessDenied")
        case .invalidParentObject: return L("mtp.invalidParentObject")
        case .invalidParameter: return L("mtp.invalidParameter")
        case .sessionAlreadyOpen: return L("mtp.sessionAlreadyOpen")
        case .deviceBusy: return L("mtp.deviceBusy")
        }
    }
}

extension MTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .truncated:
            return L("err.truncated")
        case .unexpectedContainerType(let type):
            return L("err.unexpectedContainerType", Int(type))
        case .operationFailed(let code):
            if let response = MTPResponse(rawValue: code) {
                return response.localizedMessage
            }
            return L("err.operationFailed", Int(code))
        case .stringTooLong:
            return L("err.stringTooLong")
        case .noDevice:
            return L("err.noDevice")
        case .interfaceNotFound:
            return L("err.interfaceNotFound")
        case .usb(let detail):
            // Low-level debug detail — surfaced as-is, not translated.
            return detail
        case .protocolError(let detail):
            return L("err.protocolError", detail)
        case .deviceStalled:
            return L("err.deviceStalled")
        }
    }
}

public extension Error {
    /// Best-effort friendly message for any error surfaced to the UI.
    var friendlyMessage: String {
        if let mtp = self as? MTPError { return mtp.errorDescription ?? L("err.unknown") }
        if let transport = self as? TransportError { return transport.friendlyMessage }
        return localizedDescription
    }
}

public extension TransportError {
    var friendlyMessage: String {
        switch self {
        case .notConnected: return L("transport.notConnected")
        case .notFound: return L("transport.notFound")
        case .notADirectory: return L("transport.notADirectory")
        case .operationFailed(let message): return message
        case .cancelled: return L("transport.cancelled")
        }
    }
}
