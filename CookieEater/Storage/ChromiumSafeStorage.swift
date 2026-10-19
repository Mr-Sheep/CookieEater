import CommonCrypto
import Foundation
import Security

/// Decrypts Chromium cookie values.
///
/// On macOS, Chromium encrypts each value with AES-128-CBC (16 spaces as IV). The key is derived with PBKDF2-SHA1
/// (salt "saltysalt", 1003 rounds) from a random password the browser keeps in the login keychain, under the service
/// "<Browser> Safe Storage". Encrypted values start with "v10". Since database version 24, the plaintext starts with
/// the SHA-256 of the cookie's domain.
enum ChromiumSafeStorage {
    /// The browser's password. macOS asks the user before giving it to CookieEater.
    static func password(service: String) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            if let password = result as? Data { return password }
            throw CookieValueError("The keychain returned no password for “\(service)”.")
        case errSecItemNotFound:
            throw CookieValueError("“\(service)” isn't in your keychain, so the value can't be decrypted.")
        case errSecUserCanceled, errSecAuthFailed:
            throw CookieValueError("The value is encrypted with a password kept in your keychain as “\(service)”. Allow CookieEater to use it to copy the value.")
        default:
            throw CookieValueError(SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status).")
        }
    }

    static func decrypt(_ encrypted: Data, password: Data, domain: String) throws -> String {
        guard encrypted.starts(with: "v10".utf8) else {
            throw CookieValueError("The value is encrypted in a format CookieEater doesn't know.")
        }
        var plaintext = try aesDecrypt(encrypted.dropFirst(3), key: key(from: password))
        let digest = sha256(Data(domain.utf8))
        if plaintext.starts(with: digest) {
            plaintext.removeFirst(digest.count)
        }
        guard let value = String(data: plaintext, encoding: .utf8) else {
            throw CookieValueError("The value isn't text.")
        }
        return value
    }

    private static func key(from password: Data) throws -> Data {
        let salt = Array("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let status = key.withUnsafeMutableBytes { key in
            password.withUnsafeBytes { password in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.bindMemory(to: CChar.self).baseAddress, password.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                     key.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
            }
        }
        guard status == kCCSuccess else { throw CookieValueError("Couldn't derive the decryption key.") }
        return key
    }

    private static func aesDecrypt(_ data: Data, key: Data) throws -> Data {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var length = 0
        let status = output.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { data in
                key.withUnsafeBytes { key in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                            key.baseAddress, key.count, iv, data.baseAddress, data.count,
                            output.baseAddress, output.count, &length)
                }
            }
        }
        guard status == kCCSuccess else {
            throw CookieValueError("The value couldn't be decrypted with the password from your keychain.")
        }
        return output.prefix(length)
    }

    private static func sha256(_ data: Data) -> Data {
        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { digest in
            data.withUnsafeBytes { data in
                _ = CC_SHA256(data.baseAddress, CC_LONG(data.count), digest.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return digest
    }
}
