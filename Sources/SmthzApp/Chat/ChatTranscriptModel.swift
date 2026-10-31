import Foundation
import Observation
import SmthzCore

// Chat-over-PTY transcript state (WP CHAT0, docs/BROWSER-AGENTS-EXPERIMENT.md B.5). Standalone
// this wave: nothing in ShellView or the tab strip creates it yet (see docs/UI-WIRING.md).

/// Owns a `TranscriptReader` off the main actor so file reads never block the UI.
private actor TranscriptTailWorker {
    private let reader: TranscriptReader

    init(url: URL, format: TranscriptFormat) {
        reader = TranscriptReader(url: url, format: format)
    }

    func read() -> Result<TranscriptReadResult, Error> {
        Result { try reader.readAvailable() }
    }
}

@MainActor @Observable
final class ChatTranscriptModel {
    static let pollInterval: Duration = .milliseconds(400)

    let transcriptURL: URL?
    let format: TranscriptFormat
    private(set) var log = TranscriptLog()
    private(set) var lastError: String?
    /// Bumped whenever rows change, so the view can follow the tail.
    private(set) var revision = 0

    @ObservationIgnored private var worker: TranscriptTailWorker?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var messages: [TranscriptMessage] { log.messages }

    init(transcriptURL: URL, format: TranscriptFormat) {
        self.transcriptURL = transcriptURL
        self.format = format
        worker = TranscriptTailWorker(url: transcriptURL, format: format)
    }

    /// Fixed rows, no file: previews and empty states.
    init(preview messages: [TranscriptMessage], format: TranscriptFormat = .claude) {
        transcriptURL = nil
        self.format = format
        log = TranscriptLog(messages)
    }

    /// Starts tailing; reads only bytes appended since the previous poll.
    func start() {
        guard pollTask == nil, let worker else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let result = await worker.read()
                guard let self else { return }
                self.apply(result)
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func apply(_ result: Result<TranscriptReadResult, Error>) {
        switch result {
        case .success(let read):
            lastError = nil
            guard read.didReset || !read.messages.isEmpty else { return }
            log.apply(read)
            revision += 1
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }
}
