import Foundation
import Hummingbird

/// Optional basic-auth gate. When the server is configured with a username +
/// password, every route requires `Authorization: Basic …`; otherwise all
/// requests pass (anonymous on the LAN — the share toggle is the gate).
struct BasicAuthMiddleware: RouterMiddleware<BasicRequestContext> {
    let username: String?
    let password: String?

    func handle(
        _ request: Request,
        context: BasicRequestContext,
        next: (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        guard let username, let password else {
            return try await next(request, context)
        }
        if Self.isAuthorized(request, username: username, password: password) {
            return try await next(request, context)
        }
        var response = Response(status: .unauthorized)
        response.headers[.wwwAuthenticate] = "Basic realm=\"Book Manager\""
        return response
    }

    private static func isAuthorized(
        _ request: Request,
        username: String,
        password: String
    ) -> Bool {
        guard let header = request.headers[.authorization],
              header.lowercased().hasPrefix("basic ") else {
            return false
        }
        let encoded = String(header.dropFirst("basic ".count))
        guard let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8),
              let separator = decoded.firstIndex(of: ":") else {
            return false
        }
        let user = String(decoded[..<separator])
        let pass = String(decoded[decoded.index(after: separator)...])
        // Constant-time comparison so LAN timing can't leak the password.
        return constantTimeEquals(user, username) && constantTimeEquals(pass, password)
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.utf8.count == rhs.utf8.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs.utf8, rhs.utf8) {
            difference |= a ^ b
        }
        return difference == 0
    }
}
