import Testing
import Foundation
@testable import SmthzCore

private func tempJournalPath() -> String {
    FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite").path
}

@Test
func appendIsIdempotent() throws {
    let j = try EventJournal(path: tempJournalPath())
    let a = try j.append(requestID: "r1", kind: "k", payload: Data([1, 2, 3]))
    let b = try j.append(requestID: "r1", kind: "k", payload: Data([9]))
    #expect(a == b)
    #expect(try j.read(after: 0, limit: 10).count == 1)
    #expect(try j.read(after: 0, limit: 10)[0].payload == Data([1, 2, 3]))
}

@Test
func entriesAreOrdered() throws {
    let j = try EventJournal(path: tempJournalPath())
    _ = try j.append(requestID: "r1", kind: "k", payload: Data([1]))
    _ = try j.append(requestID: "r2", kind: "k", payload: Data([2]))
    _ = try j.append(requestID: "r3", kind: "k", payload: Data([3]))
    #expect(try j.read(after: 0, limit: 10).map(\.requestID) == ["r1", "r2", "r3"])
    #expect(try j.read(after: 1, limit: 1).count == 1)
    #expect(try j.read(after: 1, limit: 1)[0].requestID == "r2")
}

@Test
func survivesReopen() throws {
    let path = tempJournalPath()
    var j: EventJournal? = try EventJournal(path: path)
    _ = try j?.append(requestID: "r1", kind: "k", payload: Data([1]))
    j = nil
    let j2 = try EventJournal(path: path)
    #expect(try j2.read(after: 0, limit: 10).count == 1)
}

@Test
func emptyPayloadRoundTrips() throws {
    let j = try EventJournal(path: tempJournalPath())
    _ = try j.append(requestID: "r1", kind: "k", payload: Data())
    #expect(try j.read(after: 0, limit: 10)[0].payload == Data())
}
