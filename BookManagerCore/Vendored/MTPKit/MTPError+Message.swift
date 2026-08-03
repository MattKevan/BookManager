import Foundation

/// Localized lookup. Vendored into BookManagerCore, so the SwiftPM-only
/// `Bundle.module` is unavailable; `Bundle.main` falls back to the key itself,
/// i.e. English strings (the app is English-only).
func loc(_ key: String, _ args: CVarArg...) -> String {
    let fmt = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? fmt : String(format: fmt, arguments: args)
}

public extension MTPResponse {
    /// Friendly, user-facing explanation of a response code (localized).
    var localizedMessage: String {
        switch self {
        case .ok: return loc("mtp.ok")
        case .generalError: return loc("mtp.generalError")
        case .sessionNotOpen: return loc("mtp.sessionNotOpen")
        case .operationNotSupported: return loc("mtp.operationNotSupported")
        case .parameterNotSupported: return loc("mtp.parameterNotSupported")
        case .incompleteTransfer: return loc("mtp.incompleteTransfer")
        case .invalidStorageID: return loc("mtp.invalidStorageID")
        case .invalidObjectHandle: return loc("mtp.invalidObjectHandle")
        case .storeFull: return loc("mtp.storeFull")
        case .storeReadOnly: return loc("mtp.storeReadOnly")
        case .accessDenied: return loc("mtp.accessDenied")
        case .invalidParentObject: return loc("mtp.invalidParentObject")
        case .invalidParameter: return loc("mtp.invalidParameter")
        case .sessionAlreadyOpen: return loc("mtp.sessionAlreadyOpen")
        case .deviceBusy: return loc("mtp.deviceBusy")
        }
    }
}

extension MTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .truncated:
            return loc("err.truncated")
        case .unexpectedContainerType(let type):
            return loc("err.unexpectedContainerType", Int(type))
        case .operationFailed(let code):
            if let response = MTPResponse(rawValue: code) {
                return response.localizedMessage
            }
            return loc("err.operationFailed", Int(code))
        case .stringTooLong:
            return loc("err.stringTooLong")
        case .noDevice:
            return loc("err.noDevice")
        case .interfaceNotFound:
            return loc("err.interfaceNotFound")
        case .usb(let detail):
            // Low-level debug detail — surfaced as-is, not translated.
            return detail
        case .protocolError(let detail):
            return loc("err.protocolError", detail)
        case .deviceStalled:
            return loc("err.deviceStalled")
        }
    }
}

public extension Error {
    /// Best-effort friendly message for any error surfaced to the UI.
    var friendlyMessage: String {
        if let mtp = self as? MTPError { return mtp.errorDescription ?? loc("err.unknown") }
        if let transport = self as? TransportError { return transport.friendlyMessage }
        return localizedDescription
    }
}

public extension TransportError {
    var friendlyMessage: String {
        switch self {
        case .notConnected: return loc("transport.notConnected")
        case .notFound: return loc("transport.notFound")
        case .notADirectory: return loc("transport.notADirectory")
        case .operationFailed(let message): return message
        case .cancelled: return loc("transport.cancelled")
        }
    }
}
