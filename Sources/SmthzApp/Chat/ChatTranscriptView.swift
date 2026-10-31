import SmthzCore
import SwiftUI

// Transcript view over an agent's JSONL (WP CHAT0). Rows: user bubbles, assistant prose,
// reasoning, collapsible tool calls/results, quiet system status. The composer hands text to
// `onSend`; the integrating WP writes it into the agent's PTY (`session.write`).

/// Entry point for a tab or pane: tails `transcriptURL` while visible.
struct ChatTranscriptEntryView: View {
    @State private var model: ChatTranscriptModel
    var onSend: ((String) -> Void)?

    init(transcriptURL: URL, format: TranscriptFormat, onSend: ((String) -> Void)? = nil) {
        _model = State(initialValue: ChatTranscriptModel(transcriptURL: transcriptURL, format: format))
        self.onSend = onSend
    }

    init(model: ChatTranscriptModel, onSend: ((String) -> Void)? = nil) {
        _model = State(initialValue: model)
        self.onSend = onSend
    }

    var body: some View {
        ChatTranscriptView(model: model, onSend: onSend)
            .onAppear { model.start() }
            .onDisappear { model.stop() }
    }
}

struct ChatTranscriptView: View {
    let model: ChatTranscriptModel
    var onSend: ((String) -> Void)?
    @State private var draft = ""

    private static let bottomID = "chat-transcript-bottom"

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.messages.isEmpty {
                            emptyState
                        }
                        ForEach(model.messages) { message in
                            ChatMessageRow(message: message)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: model.revision) {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            if let error = model.lastError {
                Text(error)
                    .font(SmthzFont.meta)
                    .foregroundStyle(SmthzTheme.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
            if onSend != nil {
                Divider().overlay(SmthzTheme.border)
                composer
            }
        }
        .background(SmthzTheme.background)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            SmthzIcon.view("bot", size: 20).foregroundStyle(SmthzTheme.mutedForeground)
            Text("No messages yet")
                .font(SmthzFont.ui(size: 13, weight: .medium))
                .foregroundStyle(SmthzTheme.mutedForeground)
            if let url = model.transcriptURL {
                Text(url.lastPathComponent)
                    .font(SmthzFont.meta)
                    .foregroundStyle(SmthzTheme.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message the agent", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(SmthzFont.ui(size: 13))
                .lineLimit(1...8)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(SmthzTheme.input.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.border))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Send to the agent's terminal")
        }
        .padding(12)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let onSend else { return }
        onSend(text)
        draft = ""
    }
}

struct ChatMessageRow: View {
    let message: TranscriptMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                blocks
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(SmthzTheme.secondary))
            }
        case .assistant, .tool:
            blocks.frame(maxWidth: .infinity, alignment: .leading)
        case .reasoning:
            DisclosureGroup {
                blocks.padding(.top, 4)
            } label: {
                Text("Thinking")
                    .font(SmthzFont.ui(size: 12, weight: .medium))
                    .foregroundStyle(SmthzTheme.mutedForeground)
            }
            .foregroundStyle(SmthzTheme.mutedForeground)
        case .system:
            Text(message.plainText)
                .font(SmthzFont.meta)
                .foregroundStyle(SmthzTheme.mutedForeground)
                .frame(maxWidth: .infinity)
        }
    }

    private var blocks: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                ChatBlockView(block: block)
            }
        }
    }
}

struct ChatBlockView: View {
    let block: TranscriptBlock
    @State private var expanded = false

    static let previewLimit = 4000

    var body: some View {
        switch block {
        case .text(let text):
            Text(markdown(text))
                .font(SmthzFont.ui(size: 13))
                .foregroundStyle(SmthzTheme.foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .toolCall(let name, let input, _):
            toolCard(icon: "wrench", title: name, summary: input, detail: input, tint: SmthzTheme.foreground)
        case .toolResult(let output, _, let isError):
            toolCard(icon: isError ? "triangle-alert" : "square-terminal", title: isError ? "Error" : "Result",
                     summary: output, detail: output, tint: isError ? SmthzTheme.destructive : SmthzTheme.mutedForeground)
        case .imageRef(let url, let path):
            Label(path ?? url ?? "image", systemImage: "photo")
                .font(SmthzFont.meta)
                .foregroundStyle(SmthzTheme.mutedForeground)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func toolCard(icon: String, title: String, summary: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    SmthzIcon.view(expanded ? .chevronDown : .chevronRight, size: 12)
                    SmthzIcon.view(SmthzIcon.Name(rawValue: icon), size: 13)
                    Text(title).font(SmthzFont.ui(size: 12, weight: .medium))
                    Text(firstLine(summary))
                        .font(SmthzFont.mono(size: 11))
                        .foregroundStyle(SmthzTheme.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(tint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            if expanded, !detail.isEmpty {
                ScrollView(.horizontal) {
                    Text(clipped(detail))
                        .font(SmthzFont.mono(size: 11))
                        .foregroundStyle(SmthzTheme.foreground)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(8)
                }
                .frame(maxHeight: 280)
                .background(SmthzTheme.muted.opacity(0.5))
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(SmthzTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SmthzTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
    }

    private func clipped(_ text: String) -> String {
        guard text.count > Self.previewLimit else { return text }
        return String(text.prefix(Self.previewLimit)) + "\n… (\(text.count - Self.previewLimit) more characters)"
    }

    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Previews

extension ChatTranscriptModel {
    static var sample: ChatTranscriptModel {
        ChatTranscriptModel(preview: [
            TranscriptMessage(id: "1", role: .user, blocks: [.text("Why does the login test fail on CI?")]),
            TranscriptMessage(id: "2", role: .reasoning, blocks: [.text("Check the session fixture first.")]),
            TranscriptMessage(id: "3", role: .assistant, blocks: [
                .text("Let me look at the **session fixture**."),
                .toolCall(name: "Read", input: #"{"file_path":"Tests/LoginTests.swift"}"#, callID: "t1"),
            ]),
            TranscriptMessage(id: "4", role: .tool, blocks: [
                .toolResult(output: "import Testing\n@Test func login() { … }", callID: "t1", isError: false),
            ]),
            TranscriptMessage(id: "5", role: .assistant, blocks: [
                .toolCall(name: "Bash", input: #"{"command":"swift test --filter login"}"#, callID: "t2"),
            ]),
            TranscriptMessage(id: "6", role: .tool, blocks: [
                .toolResult(output: "error: session expired", callID: "t2", isError: true),
            ]),
            TranscriptMessage(id: "7", role: .system, blocks: [.text(TranscriptClaudeDecoder.interruptedText)]),
            TranscriptMessage(id: "8", role: .assistant, blocks: [.text("The fixture uses a fixed clock; `Date()` drifts on CI.")]),
        ])
    }
}

#Preview("Chat transcript • light") {
    ChatTranscriptEntryView(model: .sample, onSend: { _ in })
        .frame(width: 560, height: 640)
        .preferredColorScheme(.light)
}

#Preview("Chat transcript • dark, empty") {
    ChatTranscriptEntryView(model: ChatTranscriptModel(preview: []), onSend: { _ in })
        .frame(width: 560, height: 400)
        .preferredColorScheme(.dark)
}
