import Foundation
import Testing
@testable import SmthzCore

private func withLookupJournal(_ body: (EventJournal) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try EventJournal(path: directory.appending(path: "journal.sqlite").path)
    try body(journal)
}

@Test func journalLookupFound() throws {
    try withLookupJournal { journal in
        let payload = Data([0, 1, 255, 0])
        let sequence = try journal.append(requestID: "wanted", kind: "response:ping", payload: payload)
        _ = try journal.append(requestID: "other", kind: "other", payload: Data([9]))
        let entry = try #require(try journal.entry(requestID: "wanted"))
        #expect(entry.sequence == sequence)
        #expect(entry.requestID == "wanted")
        #expect(entry.kind == "response:ping")
        #expect(entry.payload == payload)
    }
}

@Test func journalLookupNotFound() throws {
    try withLookupJournal { journal in
        #expect(try journal.entry(requestID: "missing") == nil)
        _ = try journal.append(requestID: "other", kind: "k", payload: Data([1]))
        #expect(try journal.entry(requestID: "missing") == nil)
        #expect(try journal.entry(requestID: "' OR 1=1 --") == nil)
    }
}

@Test func journalLookupEmptyPayload() throws {
    try withLookupJournal { journal in
        _ = try journal.append(requestID: "empty", kind: "k", payload: Data())
        let entry = try #require(try journal.entry(requestID: "empty"))
        #expect(entry.payload.isEmpty)
    }
}
