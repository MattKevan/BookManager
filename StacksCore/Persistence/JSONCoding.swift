import Foundation

enum JSONCoding {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from string: String?) throws -> T? {
        guard let string, !string.isEmpty else { return nil }
        return try JSONDecoder().decode(type, from: Data(string.utf8))
    }
}
