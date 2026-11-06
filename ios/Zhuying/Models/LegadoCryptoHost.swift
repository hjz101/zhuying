import Foundation
import CommonCrypto
import CoreFoundation

/// The explicitly supported subset of Legado's Android encoding/crypto host.
/// Inputs/outputs cross QuickJS as JSON byte arrays; no Java objects are exposed.
enum LegadoCryptoHost {
    static func evaluate(_ method: String, args: [Any]) throws -> Any {
        func value(_ i: Int) throws -> Any {
            guard args.indices.contains(i) else { throw LegadoRequestError.invalid("加密参数不足") }
            return args[i]
        }
        switch method {
        case "crypto.encrypt", "crypto.decrypt":
            guard let descriptor = try value(0) as? [String: Any], let algorithm = descriptor["algorithm"] as? String else {
                throw LegadoRequestError.invalid("加密配置")
            }
            let decrypting = method == "crypto.decrypt"
            let key = try bytes(descriptor["key"] ?? NSNull())
            let input = try decrypting ? ciphertext(value(1)) : bytes(value(1))
            return try aes(input, key: key, iv: descriptor["iv"], algorithm: algorithm, decrypting: decrypting).map(Int.init)
        case "crypto.decodeText":
            return try LegadoHTTPExecutor.decode(bytes(value(0)), charset: args.count > 1 ? args[1] as? String : "utf-8")
        case "android.base64Encode":
            let flags = (args.count > 1 ? args[1] as? NSNumber : nil)?.intValue ?? 0
            return try base64Encode(bytes(value(0)), flags: flags)
        case "android.base64Decode":
            let input = try value(0)
            let text = try (input as? String) ?? String(data: bytes(input), encoding: .utf8) ?? ""
            let flags = (args.count > 1 ? args[1] as? NSNumber : nil)?.intValue ?? 0
            return try base64Decode(text, flags: flags).map(Int.init)
        default: throw LegadoRequestError.unsupported(method)
        }
    }

    static func bytes(_ value: Any) throws -> Data {
        if let string = value as? String { return Data(string.utf8) }
        guard let numbers = value as? [NSNumber], numbers.count <= 2 * 1024 * 1024 else { throw LegadoRequestError.invalid("需要字符串或字节数组") }
        return try Data(numbers.map { number in
            let integer = number.intValue
            guard number.doubleValue == Double(integer), (-128...255).contains(integer), CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw LegadoRequestError.invalid("字节值越界")
            }
            return UInt8(truncatingIfNeeded: integer)
        })
    }
    private static func ciphertext(_ value: Any) throws -> Data {
        guard let string = value as? String else { return try bytes(value) }
        if !string.isEmpty, string.count.isMultiple(of: 2), string.allSatisfy(\.isHexDigit) { return try hex(string) }
        return try base64Decode(string, flags: 0)
    }
    static func hex(_ text: String) throws -> Data {
        guard text.count.isMultiple(of: 2), text.utf8.count <= 4 * 1024 * 1024 else { throw LegadoRequestError.invalid("Hex") }
        var result = Data(), index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { throw LegadoRequestError.invalid("Hex") }
            result.append(byte); index = next
        }
        return result
    }
    private static func aes(_ input: Data, key: Data, iv: Any?, algorithm: String, decrypting: Bool) throws -> Data {
        let parts = algorithm.uppercased().split(separator: "/").map(String.init)
        guard parts == ["AES"] || (parts.count == 3 && parts[0] == "AES") else { throw LegadoRequestError.unsupported("加密算法 \(algorithm)") }
        let mode = parts.count == 1 ? "ECB" : parts[1], padding = parts.count == 1 ? "PKCS5PADDING" : parts[2]
        guard ["ECB", "CBC"].contains(mode), ["PKCS5PADDING", "PKCS7PADDING", "NOPADDING"].contains(padding) else {
            throw LegadoRequestError.unsupported("加密模式 \(algorithm)")
        }
        guard [16, 24, 32].contains(key.count), input.count <= 2 * 1024 * 1024 else { throw LegadoRequestError.invalid("AES 密钥必须为 16、24 或 32 字节") }
        var ivData = Data()
        if mode == "CBC" {
            guard let iv, !(iv is NSNull) else { throw LegadoRequestError.unsupported("AES/CBC 必须明确设置 IV") }
            ivData = try bytes(iv)
            guard ivData.count == kCCBlockSizeAES128 else { throw LegadoRequestError.invalid("AES IV 必须为 16 字节") }
        }
        if (decrypting && (input.isEmpty || !input.count.isMultiple(of: kCCBlockSizeAES128))) || (padding == "NOPADDING" && !input.count.isMultiple(of: kCCBlockSizeAES128)) { throw LegadoRequestError.invalid("AES NoPadding 数据长度") }
        var options = CCOptions(mode == "ECB" ? kCCOptionECBMode : 0)
        if padding != "NOPADDING" { options |= CCOptions(kCCOptionPKCS7Padding) }
        var output = Data(count: input.count + kCCBlockSizeAES128), written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { data in
                key.withUnsafeBytes { keyBytes in
                    ivData.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(decrypting ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options,
                                keyBytes.baseAddress, key.count, mode == "ECB" ? nil : ivBytes.baseAddress,
                                data.baseAddress, input.count, out.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw LegadoRequestError.invalid("AES 数据或填充无效") }
        output.count = written; return output
    }
    static func base64Encode(_ data: Data, flags: Int) throws -> String {
        guard flags >= 0, flags & ~31 == 0 else { throw LegadoRequestError.unsupported("Base64 flags") }
        var result = data.base64EncodedString()
        if flags & 8 != 0 { result = result.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }
        if flags & 1 != 0 { result = result.replacingOccurrences(of: "=", with: "") }
        if flags & 2 == 0, !result.isEmpty {
            let newline = flags & 4 == 0 ? "\n" : "\r\n"
            var lines: [String] = [], start = result.startIndex
            while start < result.endIndex { let end = result.index(start, offsetBy: 76, limitedBy: result.endIndex) ?? result.endIndex; lines.append(String(result[start..<end])); start = end }
            result = lines.joined(separator: newline) + newline
        }
        return result
    }
    static func base64Decode(_ string: String, flags: Int) throws -> Data {
        guard string.utf8.count <= 4 * 1024 * 1024, flags >= 0, flags & ~31 == 0 else { throw LegadoRequestError.invalid("Base64") }
        var input = string.components(separatedBy: .whitespacesAndNewlines).joined()
        if flags & 8 != 0 { input = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") }
        guard input.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }), input.count % 4 != 1 else { throw LegadoRequestError.invalid("Base64") }
        input += String(repeating: "=", count: (4 - input.count % 4) % 4)
        guard let data = Data(base64Encoded: input) else { throw LegadoRequestError.invalid("Base64") }
        return data
    }
}
