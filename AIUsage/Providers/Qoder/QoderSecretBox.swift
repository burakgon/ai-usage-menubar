import CommonCrypto
import Foundation

enum QoderSecretBox {
    static func decrypt(payload: Data, password: String) -> Data? {
        guard let raw = ciphertext(from: payload),
              raw.starts(with: Data("v10".utf8)),
              raw.count > 3 else {
            return nil
        }

        let cipher = raw.dropFirst(3)
        guard !cipher.isEmpty, cipher.count.isMultiple(of: kCCBlockSizeAES128) else {
            return nil
        }
        guard let key = derivedKey(password: password) else { return nil }

        var output = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var written = 0
        let status = cipher.withUnsafeBytes { cipherBytes in
            key.withUnsafeBytes { keyBytes in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress,
                    kCCKeySizeAES128,
                    [UInt8](repeating: 0x20, count: kCCBlockSizeAES128),
                    cipherBytes.baseAddress,
                    cipher.count,
                    &output,
                    output.count,
                    &written
                )
            }
        }
        guard status == kCCSuccess, written > 0 else { return nil }
        return Data(output.prefix(written))
    }

    private static func ciphertext(from payload: Data) -> Data? {
        if payload.starts(with: Data("v10".utf8)) {
            return payload
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let numbers = envelope["data"] as? [Int] else {
            return nil
        }
        let raw = Data(numbers.compactMap { value in
            guard (0...255).contains(value) else { return nil }
            return UInt8(value)
        })
        guard raw.count == numbers.count else { return nil }
        return raw
    }

    private static func derivedKey(password: String) -> Data? {
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let status = password.withCString { passwordBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes,
                strlen(passwordBytes),
                salt,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003,
                &key,
                key.count
            )
        }
        guard status == kCCSuccess else { return nil }
        return Data(key)
    }
}
