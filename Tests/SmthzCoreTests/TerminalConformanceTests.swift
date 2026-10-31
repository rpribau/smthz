import Darwin
import Foundation
import Testing
@testable import SmthzCore

// Headless checks for docs/TERMINAL-BEHAVIOR.md C1-C15: an interactive zsh without user rc files on
// a real PTY with the environment the host gives every session. The UI half lives in
// docs/TERMINAL-CONFORMANCE.md.

private final class ConformanceOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return bytes.count }
    /// Text produced after `offset` bytes.
    func text(after offset: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes.dropFirst(offset), as: UTF8.self)
    }
}

private func conformanceEventually(timeout: TimeInterval = 5, _ predicate: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    repeat {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return predicate()
}

/// zsh -f -i: interactive (job control, line editor, bracketed paste) without the user's rc files.
private func interactiveZsh(rows: UInt16 = 24, cols: UInt16 = 80) throws -> (PTYSession, ConformanceOutput) {
    var environment = SessionEnvironment.build(base: ProcessInfo.processInfo.environment)
    environment["PS1"] = "READY%# "
    let child = try PTYSession(executable: "/bin/zsh", arguments: ["-f", "-i"], environment: environment,
                               workingDirectory: NSTemporaryDirectory(), size: PTYSize(rows: rows, cols: cols))
    let output = ConformanceOutput()
    child.setOutputHandler { output.append($0) }
    #expect(conformanceEventually { output.text.contains("READY") })
    return (child, output)
}

/// Writes `command` and waits until `marker` appears in the output produced after the write.
private func run(_ child: PTYSession, _ output: ConformanceOutput, _ command: String,
                 until marker: String) throws -> String {
    let start = output.count
    try child.write(Data(command.utf8))
    _ = conformanceEventually { output.text(after: start).contains(marker) }
    return output.text(after: start)
}

private func finish(_ child: PTYSession) {
    try? child.write(Data("exit\n".utf8))
    _ = child.waitForExit(timeout: 2)
    child.close()
}

@Suite(.serialized)
struct TerminalConformanceTests {
    /// C1-C4, C14: terminfo, colour and locale as an interactive shell sees them.
    @Test func shellSeesTerminfoColourAndUTF8Locale() throws {
        let (child, output) = try interactiveZsh()
        defer { finish(child) }
        let text = try run(child, output,
            "infocmp $TERM >/dev/null && echo TI=OK; echo T=$TERM C=$COLORTERM L=$LANG N=$(tput colors); echo END\n",
            until: "END\r\n")
        #expect(text.contains("TI=OK"))
        #expect(text.contains("T=xterm-256color C=truecolor"))
        #expect(text.contains("L=") && text.contains("UTF-8"))
        #expect(text.contains("N=256"))
        let red = try run(child, output, "tput setaf 1; echo; echo DONE\n", until: "DONE\r\n")
        #expect(red.contains("\u{1B}[31m"))
    }

    /// C5, C6: `clear` and zsh's Ctrl-L both erase the display.
    @Test func clearAndControlLEraseTheDisplay() throws {
        let (child, output) = try interactiveZsh()
        defer { finish(child) }
        let cleared = try run(child, output, "clear\n", until: "\u{1B}[?2004h")
        #expect(cleared.contains("\u{1B}[3J"))
        #expect(cleared.contains("\u{1B}[H"))
        #expect(cleared.contains("\u{1B}[2J"))
        let start = output.count
        try child.write(Data([0x0C]))
        #expect(conformanceEventually { output.text(after: start).contains("\u{1B}[2J") })
        #expect(conformanceEventually { output.text(after: start).contains("READY") })
    }

    /// C9: SIGWINCH reaches the foreground process group and `stty size` follows the PTY.
    @Test func sttySizeFollowsResize() throws {
        let (child, output) = try interactiveZsh(rows: 24, cols: 80)
        defer { finish(child) }
        #expect(try run(child, output, "stty size\n", until: "24 80").contains("24 80"))
        try child.resize(PTYSize(rows: 33, cols: 101))
        let resized = try run(child, output, "stty size; echo COLS=$COLUMNS\n", until: "COLS=101")
        #expect(resized.contains("33 101"))
        #expect(resized.contains("COLS=101"))
    }

    /// C10: zsh asks for bracketed paste at the prompt and drops it while a command runs.
    @Test func bracketedPasteIsRequestedAtThePromptOnly() throws {
        let (child, output) = try interactiveZsh()
        defer { finish(child) }
        #expect(conformanceEventually { output.text.contains("\u{1B}[?2004h") })
        let text = try run(child, output, "echo RUN\n", until: "RUN\r\n")
        #expect(text.contains("\u{1B}[?2004l"))
        // A bracketed paste reaches the line editor as text, not as typed keys.
        let pasted = try run(child, output, "\u{1B}[200~echo PASTED-OK\u{1B}[201~\n", until: "PASTED-OK\r\n")
        #expect(pasted.contains("PASTED-OK\r\n"))
    }

    /// C12: Ctrl-Z stops the foreground job, `fg` resumes it, Ctrl-C ends it and the shell lives on.
    @Test func controlZStopsAndFgResumesTheForegroundJob() throws {
        let (child, output) = try interactiveZsh()
        defer { finish(child) }
        let start = output.count
        try child.write(Data("sleep 30\n".utf8))
        Thread.sleep(forTimeInterval: 0.3)
        try child.write(Data([0x1A]))
        #expect(conformanceEventually { output.text(after: start).contains("suspended") })
        let resumed = try run(child, output, "fg\n", until: "continued")
        #expect(resumed.contains("continued"))
        Thread.sleep(forTimeInterval: 0.2)
        try child.write(Data([0x03]))
        let after = try run(child, output, "echo ALIVE-$((40+2))\n", until: "ALIVE-42")
        #expect(after.contains("ALIVE-42"))
        #expect(child.waitForExit(timeout: 0.05) == nil)
    }

    /// C4: wide and emoji characters leave the PTY as UTF-8.
    @Test func wideAndEmojiCharactersAreUTF8() throws {
        let (child, output) = try interactiveZsh()
        defer { finish(child) }
        let text = try run(child, output, "printf 'W:%s:\\n' 你好😀; echo END\n", until: "END\r\n")
        #expect(text.contains("W:你好😀:"))
    }
}
