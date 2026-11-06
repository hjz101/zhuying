import Foundation
import CoreFoundation

/// A fixed schema diagnostic of rule input. It retains no input text, values,
/// lengths, hashes, dynamically supplied property names or response status.
struct LegadoRuleInputSummary: Codable, Equatable, Sendable {
    enum JSONType: String, Codable, Sendable {
        case missing, invalid, null, boolean, number, string, array, object
    }
    let root: JSONType
    let abstract: JSONType
    let data: JSONType
    let hasCode: Bool

    static func from(_ text: String) -> Self {
        guard text.utf8.count <= 2 * 1024 * 1024,
              let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) else {
            return .init(root: .invalid, abstract: .missing, data: .missing, hasCode: false)
        }
        let object = value as? [String: Any]
        return .init(root: type(value), abstract: type(object?["abstract"]), data: type(object?["data"]), hasCode: object?["code"] != nil)
    }

    private static func type(_ value: Any?) -> JSONType {
        guard let value else { return .missing }
        if value is NSNull { return .null }
        if value is String { return .string }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .boolean : .number
        }
        if value is [Any] { return .array }
        if value is [String: Any] { return .object }
        return .invalid
    }
}
