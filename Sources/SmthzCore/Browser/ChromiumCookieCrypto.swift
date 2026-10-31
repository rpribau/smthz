import Foundation
import CommonCrypto
import Security

/// Chromium's macOS cookie encryption (Orca `browser-cookie-key.ts`, `browser-cookie-decryption.ts`):
/// the Keychain password goes through PBKDF2-SHA1 ("saltysalt", 1003 iterations, 16 bytes) and the
/// value is AES-128-CBC with an IV of 16 spaces behind a "v10"/"v11" prefix. CommonCrypto only.
public enum ChromiumCookieCrypto {
    public static let salt = Data("saltysalt".utf8)
    public static let macIterations: UInt32 = 1003
    public static let keyLength = 16
    /// Chromium 127+ (DB schema 24+) prepends SHA-256(host_key) to the plaintext.
    public static let hostHashLength = 32
    static let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

    /// Derives the AES key from a Keychain "Safe Storage" password.
    public static func deriveKey(password: String, iterations: UInt32 = macIterations) -> Data? {
        pbkdf2SHA1(password: Data(password.utf8), salt: salt, iterations: iterations, length: keyLength)
    }

    static func pbkdf2SHA1(password: Data, salt: Data, iterations: UInt32, length: Int) -> Data? {
        var derived = Data(count: length)
        let status = derived.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { pw in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), iterations,
                                         out.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    /// The 3-byte "vNN" prefix, or nil when the blob is not version-tagged.
    public static func encryptionVersion(_ blob: Data) -> String? {
        guard blob.count >= 3, let version = String(data: blob.prefix(3), encoding: .ascii),
              version.first == "v", version.dropFirst().allSatisfy(\.isASCIIDigit) else { return nil }
        return version
    }

    /// Decrypts a v10/v11 value and strips the host-hash prefix. Returns nil on any failure
    /// (unknown version such as app-bound v20, bad padding, empty ciphertext).
    public static func decrypt(_ blob: Data, key: Data, hostKey: String) -> Data? {
        guard let version = encryptionVersion(blob), version == "v10" || version == "v11" else { return nil }
        let ciphertext = Data(blob.dropFirst(3))
        guard !ciphertext.isEmpty, let plain = aes128CBC(CCOperation(kCCDecrypt), ciphertext, key: key) else {
            return nil
        }
        return stripHostHash(plain, hostKey: hostKey)
    }

    /// Produces a Chromium-format blob; used to build fixtures and to round-trip in tests.
    public static func encrypt(_ plaintext: Data, key: Data, version: String = "v10",
                               hostKeyHashPrefix hostKey: String? = nil) -> Data? {
        var payload = Data()
        if let hostKey { payload.append(sha256(Data(hostKey.utf8))) }
        payload.append(plaintext)
        guard let cipher = aes128CBC(CCOperation(kCCEncrypt), payload, key: key) else { return nil }
        return Data(version.utf8) + cipher
    }

    static func stripHostHash(_ plain: Data, hostKey: String) -> Data {
        let plain = Data(plain)
        if plain.count >= hostHashLength, plain.prefix(hostHashLength) == sha256(Data(hostKey.utf8)) {
            return Data(plain.dropFirst(hostHashLength))
        }
        // Why (Orca): an HMAC prefix of unknown input is about half non-printable; 8 of 32 flags it.
        if plain.count > hostHashLength,
           plain.prefix(hostHashLength).filter({ $0 < 0x20 || $0 > 0x7e }).count >= 8 {
            return Data(plain.dropFirst(hostHashLength))
        }
        return plain
    }

    static func sha256(_ data: Data) -> Data {
        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                _ = CC_SHA256(input.baseAddress, CC_LONG(data.count), out.baseAddress?.assumingMemoryBound(to: UInt8.self))
            }
        }
        return digest
    }

    static func aes128CBC(_ operation: CCOperation, _ input: Data, key: Data) -> Data? {
        guard key.count == kCCKeySizeAES128 else { return nil }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, input.count, out.baseAddress, outputCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(moved)
    }

    /// Chromium stores microseconds since 1601-01-01; 0 means a session cookie.
    public static func unixTime(fromChromium microseconds: Int64) -> TimeInterval? {
        guard microseconds > 0 else { return nil }
        let seconds = microseconds / 1_000_000 - 11_644_473_600
        return seconds > 0 ? TimeInterval(seconds) : nil
    }
}

/// Supplies the "Safe Storage" password. Tests inject a fixed one; nothing in tests touches the Keychain.
public protocol ChromiumKeyProvider: Sendable {
    func password(service: String, account: String) throws -> String
}

public struct FixedChromiumKeyProvider: ChromiumKeyProvider {
    public let value: String
    public init(_ value: String) { self.value = value }
    public func password(service: String, account: String) throws -> String { value }
}

/// Reads the generic-password item; macOS shows its own access prompt to the user.
public struct KeychainChromiumKeyProvider: ChromiumKeyProvider {
    public init() {}
    public func password(service: String, account: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw BrowserCookieImportError.keyUnavailable(service: service, status: status)
        }
        return password
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
