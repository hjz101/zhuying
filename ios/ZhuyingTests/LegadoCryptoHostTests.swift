import XCTest
@testable import Zhuying

final class LegadoCryptoHostTests: XCTestCase {
    private func bytes(_ hex: String) throws -> [Int] { try LegadoCryptoHost.hex(hex).map(Int.init) }
    private func crypt(_ operation: String, algorithm: String, key: [Int], iv: [Int]? = nil, input: Any) throws -> Data {
        var descriptor: [String: Any] = ["algorithm": algorithm, "key": key]
        if let iv { descriptor["iv"] = iv }
        let value = try LegadoCryptoHost.evaluate("crypto." + operation, args: [descriptor,input])
        let result = try XCTUnwrap(value as? [Int])
        return Data(result.map(UInt8.init))
    }

    /// FIPS 197 (2001), Appendix C.1/C.2/C.3: one block, all three AES key sizes.
    /// https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.197.pdf
    func testFIPS197KnownAnswerVectorsEncryptAndDecryptWithoutPadding() throws {
        let plain = try bytes("00112233445566778899aabbccddeeff")
        let vectors = [
            ("000102030405060708090a0b0c0d0e0f", "69c4e0d86a7b0430d8cdb78070b4c55a"),
            ("000102030405060708090a0b0c0d0e0f1011121314151617", "dda97ca4864cdfe06eaf70a0ec0d7191"),
            ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", "8ea2b7ca516745bfeafc49904b496089")
        ]
        for (key, cipher) in vectors {
            let encrypted = try crypt("encrypt", algorithm: "AES/ECB/NoPadding", key: bytes(key), input: plain)
            XCTAssertEqual(encrypted, try LegadoCryptoHost.hex(cipher))
            let decrypted = try crypt("decrypt", algorithm: "AES/ECB/NoPadding", key: bytes(key), input: bytes(cipher))
            XCTAssertEqual(decrypted, Data(plain.map(UInt8.init)))
        }
    }

    /// NIST SP 800-38A F.2.1/F.2.2, including chaining between all four blocks.
    /// https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38a.pdf
    func testNISTCBC128FourBlockKnownAnswerVectorInBothDirections() throws {
        let key = try bytes("2b7e151628aed2a6abf7158809cf4f3c"), iv = try bytes("000102030405060708090a0b0c0d0e0f")
        let plain = "6bc1bee22e409f96e93d7e117393172a" + "ae2d8a571e03ac9c9eb76fac45af8e51" +
            "30c81c46a35ce411e5fbc1191a0a52ef" + "f69f2445df4f9b17ad2b417be66c3710"
        let cipher = "7649abac8119b246cee98e9b12e9197d" + "5086cb9b507219ee95db113a917678b2" +
            "73bed6b8e3c1743b7116e69e22229516" + "3ff1caa1681fac09120eca307586e1a7"
        XCTAssertEqual(try crypt("encrypt", algorithm: "AES/CBC/NoPadding", key: key, iv: iv, input: bytes(plain)), try LegadoCryptoHost.hex(cipher))
        XCTAssertEqual(try crypt("decrypt", algorithm: "AES/CBC/NoPadding", key: key, iv: iv, input: bytes(cipher)), try LegadoCryptoHost.hex(plain))
    }

    func testDefaultAESPaddingUnicodeAndCiphertextHexOrBase64InputsUseRealNativeCrypto() throws {
        let key = Array("0123456789abcdef".utf8).map(Int.init), message = "登录👩🏽‍🚀\n竹影正文"
        let encrypted = try crypt("encrypt", algorithm: "AES", key: key, input: message)
        XCTAssertTrue(encrypted.count.isMultiple(of: 16)); XCTAssertFalse(encrypted.isEmpty)
        let base64 = encrypted.base64EncodedString(), hex = encrypted.map { String(format: "%02x", $0) }.joined()
        for input in [base64,hex] {
            let decrypted = try crypt("decrypt", algorithm: "AES", key: key, input: input)
            XCTAssertEqual(String(data: decrypted, encoding: .utf8), message)
        }
        XCTAssertEqual(encrypted, try crypt("encrypt", algorithm: "AES/ECB/PKCS5Padding", key: key, input: message))
        XCTAssertEqual(encrypted, try crypt("encrypt", algorithm: "AES/ECB/PKCS7Padding", key: key, input: message))
    }

    func testInvalidKeyIVAlgorithmAndPaddingNeverFallBackToPlaintextOrDifferentMode() throws {
        let key = Array("0123456789abcdef".utf8).map(Int.init), block = [Int](repeating: 0, count: 16)
        XCTAssertThrowsError(try crypt("encrypt", algorithm: "AES", key: [1,2,3], input: "text"))
        XCTAssertThrowsError(try crypt("encrypt", algorithm: "AES/CBC/PKCS5Padding", key: key, input: "text"))
        XCTAssertThrowsError(try crypt("encrypt", algorithm: "AES/CBC/PKCS5Padding", key: key, iv: [1,2], input: "text"))
        XCTAssertThrowsError(try crypt("encrypt", algorithm: "AES/GCM/NoPadding", key: key, input: block))
        XCTAssertThrowsError(try crypt("encrypt", algorithm: "DES", key: key, input: block))
        XCTAssertThrowsError(try crypt("encrypt", algorithm: "AES/ECB/NoPadding", key: key, input: "short"))
        XCTAssertThrowsError(try crypt("decrypt", algorithm: "AES", key: key, input: [0]))
        XCTAssertThrowsError(try LegadoCryptoHost.bytes([true]))
        XCTAssertThrowsError(try LegadoCryptoHost.bytes([1.5]))
        XCTAssertThrowsError(try LegadoCryptoHost.bytes([256]))
        XCTAssertThrowsError(try LegadoCryptoHost.bytes([-129]))
        XCTAssertEqual(try LegadoCryptoHost.bytes([-1,-128,0,127,255]), Data([255,128,0,127,255]))
    }

    func testAndroidBase64WrappingPaddingURLSafeAndStrictMalformedInputs() throws {
        let binary = Data([251,255])
        XCTAssertEqual(try LegadoCryptoHost.base64Encode(binary, flags: 0), "+/8=\n")
        XCTAssertEqual(try LegadoCryptoHost.base64Encode(binary, flags: 2), "+/8=")
        XCTAssertEqual(try LegadoCryptoHost.base64Encode(binary, flags: 3), "+/8")
        XCTAssertEqual(try LegadoCryptoHost.base64Encode(binary, flags: 11), "-_8")
        XCTAssertEqual(try LegadoCryptoHost.base64Encode(binary, flags: 4), "+/8=\r\n")
        XCTAssertEqual(try LegadoCryptoHost.base64Decode("-_8", flags: 8), binary)
        XCTAssertEqual(try LegadoCryptoHost.base64Decode(" +/8=\r\n", flags: 0), binary)
        let long = Data(repeating: 65, count: 60)
        XCTAssertEqual(try LegadoCryptoHost.base64Encode(long, flags: 0), String(repeating: "QUFB", count: 19) + "\nQUFB\n")
        XCTAssertEqual(try LegadoCryptoHost.base64Encode(Data(), flags: 0), "")
        for malformed in ["a", "%%%%", "a===", "=AA=", "中文"] { XCTAssertThrowsError(try LegadoCryptoHost.base64Decode(malformed, flags: 0)) }
        XCTAssertThrowsError(try LegadoCryptoHost.base64Encode(binary, flags: 32))
        XCTAssertThrowsError(try LegadoCryptoHost.base64Decode("+/8=", flags: -1))
    }

    func testRealQuickJSAndroidCryptoChainRoundTripsDefaultAndCBCWithTypedByteArrays() async throws {
        let value = try await Task.detached {
            try QuickJSScriptSession().evaluate(#"""
                const input='原创登录👩🏽‍🚀';
                const key='0123456789abcdef';
                const cipher=java.createSymmetricCrypto('AES',key);
                const encoded=Packages.android.util.Base64.encodeToString(cipher.encrypt(input),2);
                const cbc=java.createSymmetricCrypto('AES/CBC/PKCS5Padding',new Uint8Array(Array.from(key,c=>c.charCodeAt(0))),new Uint8Array(16));
                [cipher.decryptStr(encoded),cipher.decryptStr(cipher.encryptHex(input)),cbc.decryptStr(cbc.encryptBase64(input)),
                 Packages.android.util.Base64.decode(encoded,2).length,encoded.includes('\n')];
                """#, bindings: [:]) { method,args in try LegadoCryptoHost.evaluate(method, args: args) }
        }.value as? [Any]
        XCTAssertEqual(value?[0] as? String, "原创登录👩🏽‍🚀")
        XCTAssertEqual(value?[1] as? String, "原创登录👩🏽‍🚀")
        XCTAssertEqual(value?[2] as? String, "原创登录👩🏽‍🚀")
        XCTAssertTrue(((value?[3] as? Int) ?? 0).isMultiple(of: 16))
        XCTAssertEqual(value?[4] as? Bool, false)
    }
}
