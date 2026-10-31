import Foundation
import Testing
@testable import SmthzCore

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

@Test func pbkdf2SHA1MatchesRFC6070Vector() {
    let derived = ChromiumCookieCrypto.pbkdf2SHA1(password: Data("password".utf8), salt: Data("salt".utf8),
                                                  iterations: 2, length: 20)
    #expect(derived.map(hex) == "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957")
}

@Test func chromiumKeyDerivationIsSixteenBytesAndDeterministic() throws {
    let a = try #require(ChromiumCookieCrypto.deriveKey(password: "fixture-secret"))
    let b = try #require(ChromiumCookieCrypto.deriveKey(password: "fixture-secret"))
    #expect(a.count == 16)
    #expect(a == b)
    #expect(a != ChromiumCookieCrypto.deriveKey(password: "other"))
}

@Test func v10RoundTripWithoutHostHash() throws {
    let key = try #require(ChromiumCookieCrypto.deriveKey(password: "fixture-secret"))
    let blob = try #require(ChromiumCookieCrypto.encrypt(Data("session=abc".utf8), key: key))
    #expect(blob.prefix(3) == Data("v10".utf8))
    #expect((blob.count - 3) % 16 == 0)
    let plain = try #require(ChromiumCookieCrypto.decrypt(blob, key: key, hostKey: ".example.com"))
    #expect(String(decoding: plain, as: UTF8.self) == "session=abc")
}

@Test func v10RoundTripStripsHostKeyHash() throws {
    let key = try #require(ChromiumCookieCrypto.deriveKey(password: "fixture-secret"))
    let blob = try #require(ChromiumCookieCrypto.encrypt(Data("tok".utf8), key: key, hostKeyHashPrefix: ".example.com"))
    let plain = try #require(ChromiumCookieCrypto.decrypt(blob, key: key, hostKey: ".example.com"))
    #expect(String(decoding: plain, as: UTF8.self) == "tok")
}

@Test func hostKeyHashIsStrippedForEmptyValues() throws {
    let key = try #require(ChromiumCookieCrypto.deriveKey(password: "fixture-secret"))
    let blob = try #require(ChromiumCookieCrypto.encrypt(Data(), key: key, hostKeyHashPrefix: "example.com"))
    #expect(ChromiumCookieCrypto.decrypt(blob, key: key, hostKey: "example.com") == Data())
}

@Test func unknownBinaryPrefixIsStrippedByHeuristic() throws {
    let key = try #require(ChromiumCookieCrypto.deriveKey(password: "fixture-secret"))
    // A hash of some other host still looks like an HMAC prefix (mostly non-printable).
    let blob = try #require(ChromiumCookieCrypto.encrypt(Data("value".utf8), key: key, hostKeyHashPrefix: "other.test"))
    let plain = try #require(ChromiumCookieCrypto.decrypt(blob, key: key, hostKey: "example.com"))
    #expect(String(decoding: plain, as: UTF8.self) == "value")
}

@Test func printableLongValuesAreNotStripped() throws {
    let key = try #require(ChromiumCookieCrypto.deriveKey(password: "fixture-secret"))
    let value = String(repeating: "abcdefgh", count: 8)
    let blob = try #require(ChromiumCookieCrypto.encrypt(Data(value.utf8), key: key))
    let plain = try #require(ChromiumCookieCrypto.decrypt(blob, key: key, hostKey: "example.com"))
    #expect(String(decoding: plain, as: UTF8.self) == value)
}

@Test func decryptRejectsAppBoundUnknownAndEmptyBlobs() throws {
    let key = try #require(ChromiumCookieCrypto.deriveKey(password: "fixture-secret"))
    let v10 = try #require(ChromiumCookieCrypto.encrypt(Data("x".utf8), key: key))
    var v20 = v10
    v20.replaceSubrange(0..<3, with: Data("v20".utf8))
    #expect(ChromiumCookieCrypto.decrypt(v20, key: key, hostKey: "a.test") == nil)
    #expect(ChromiumCookieCrypto.decrypt(Data("v10".utf8), key: key, hostKey: "a.test") == nil)
    #expect(ChromiumCookieCrypto.decrypt(Data("plain".utf8), key: key, hostKey: "a.test") == nil)
    #expect(ChromiumCookieCrypto.decrypt(v10, key: Data(count: 5), hostKey: "a.test") == nil)
    #expect(ChromiumCookieCrypto.encryptionVersion(v20) == "v20")
    #expect(ChromiumCookieCrypto.encryptionVersion(Data("abc".utf8)) == nil)
}

@Test func wrongKeyNeverYieldsThePlaintext() throws {
    let key = try #require(ChromiumCookieCrypto.deriveKey(password: "fixture-secret"))
    let wrong = try #require(ChromiumCookieCrypto.deriveKey(password: "wrong"))
    let blob = try #require(ChromiumCookieCrypto.encrypt(Data("secret-value".utf8), key: key))
    #expect(ChromiumCookieCrypto.decrypt(blob, key: wrong, hostKey: "a.test") != Data("secret-value".utf8))
}

@Test func chromiumTimestampsConvertToUnix() {
    #expect(ChromiumCookieCrypto.unixTime(fromChromium: 0) == nil)
    #expect(ChromiumCookieCrypto.unixTime(fromChromium: (11_644_473_600 + 1_700_000_000) * 1_000_000) == 1_700_000_000)
}

@Test func fixedKeyProviderReturnsItsValue() throws {
    #expect(try FixedChromiumKeyProvider("pw").password(service: "S", account: "A") == "pw")
}
