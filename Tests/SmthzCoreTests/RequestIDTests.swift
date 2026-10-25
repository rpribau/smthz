import Testing
import Foundation
@testable import SmthzCore

@Test
func generatedIDsAreUnique() {
    var ids = Set<RequestID>()
    for _ in 0..<100 {
        ids.insert(RequestID.generate())
    }
    #expect(ids.count == 100)
}

@Test
func generatedIDIsLowercaseUUID() {
    let id = RequestID.generate()
    #expect(UUID(uuidString: id.rawValue) != nil)
    #expect(id.rawValue == id.rawValue.lowercased())
    #expect(id.description == id.rawValue)
}

@Test
func encodesAsPlainString() throws {
    let data = try JSONEncoder().encode(RequestID(rawValue: "abc"))
    #expect(data == Data([0x22, 0x61, 0x62, 0x63, 0x22]))
    #expect(try JSONDecoder().decode(RequestID.self, from: data).rawValue == "abc")
}

@Test
func decodeRoundTrip() throws {
    let original = RequestID.generate()
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(RequestID.self, from: data)
    #expect(decoded == original)
}

@Test
func decodingNumberThrows() {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(RequestID.self, from: Data("123".utf8))
    }
}

@Test
func decodingObjectThrows() {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(RequestID.self, from: Data(#"{"rawValue":"abc"}"#.utf8))
    }
}
