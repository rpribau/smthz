import Foundation
import Testing
@testable import SmthzCore

struct TerminalLinkTests {
    @Test func pathsAndLocations() {
        let links = TerminalFileLink.detect(in: "error: src/main.swift:12:3 (/tmp/a.txt:8) ../lib/file.c ./x/y ~/docs/log.txt")
        #expect(links.map(\.path) == ["src/main.swift", "/tmp/a.txt", "../lib/file.c", "./x/y", "~/docs/log.txt"])
        #expect(links.first?.line == 12)
        #expect(links.first?.column == 3)
        #expect(links[1].line == 8)
        #expect(links[1].column == nil)
    }

    @Test func quotedPathsAndUnicodeRanges() {
        let text = "😀 \"src/my file.swift\":24:2 'other file.txt':9"
        let links = TerminalFileLink.detect(in: text)
        #expect(links.map(\.path) == ["src/my file.swift", "other file.txt"])
        #expect((text as NSString).substring(with: links[0].range) == "\"src/my file.swift\":24:2")
    }

    @Test func rejectsURLsCommandsAndMalformedLocations() {
        #expect(TerminalFileLink.detect(in: "https://example.com/a.swift:2 file:///tmp/a.txt ssh://host/a x.swift:0 x.swift:2:0 $(touch) plain").isEmpty)
    }

    @Test func resolvesOnlyLocalPathsWithKnownCwd() {
        let links = TerminalFileLink.detect(in: "../a.swift:2 /tmp/b.txt ~/c.txt")
        #expect(links[0].resolvedURL(cwd: "/repo/src", home: "/home/me")?.path == "/repo/a.swift")
        #expect(links[0].resolvedURL(cwd: nil, home: "/home/me") == nil)
        #expect(links[1].resolvedURL(cwd: nil, home: "/home/me")?.path == "/tmp/b.txt")
        #expect(links[2].resolvedURL(cwd: nil, home: "/home/me")?.path == "/home/me/c.txt")
    }

    @Test func contextIsPlainTextAndEmptyDoesNotReplaceClipboard() {
        #expect(TerminalContext.format(rows: ["  ", "hello\u{7}", "", "", "", "", "world  "]) == "hello\n\n\nworld")
        #expect(TerminalContext.format(rows: ["", "   "]) == nil)
        #expect(TerminalContext.format(rows: ["$ pwd", "/repo", "$ echo hi", "hi"]) == "$ pwd\n/repo\n$ echo hi\nhi")
    }

    @Test func contextKeepsNewestOutputWithReferenceMarker() {
        let result = TerminalContext.format(rows: [String(repeating: "a", count: 40_000) + "NEWEST"])!
        #expect(result.hasPrefix("\n\n[Earlier terminal output omitted: 4006 characters]\n\n"))
        #expect(result.utf16.count == 36_000)
        #expect(result.hasSuffix("NEWEST"))
    }
}
