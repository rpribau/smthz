import AppKit
import SwiftUI
import WebKit

/// Downloads from every browser tab land in ~/Downloads; the shelf lists them.
@MainActor @Observable final class BrowserDownloadCenter: NSObject {
    enum State: Equatable { case running, finished, failed(String), cancelled }

    @MainActor @Observable final class Item: Identifiable {
        let id = UUID()
        var filename: String
        var destination: URL?
        var fraction = 0.0
        var state = State.running
        @ObservationIgnored fileprivate weak var download: WKDownload?
        @ObservationIgnored fileprivate var progressObservation: NSKeyValueObservation?
        init(filename: String) { self.filename = filename }
    }

    private(set) var items: [Item] = []
    var directory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")

    func track(_ download: WKDownload) {
        let item = Item(filename: download.originalRequest?.url?.lastPathComponent ?? "download")
        item.download = download
        item.progressObservation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak item] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in item?.fraction = fraction }
        }
        items.insert(item, at: 0)
        download.delegate = self
    }

    func cancel(_ item: Item) {
        item.download?.cancel { _ in }
        item.state = .cancelled
        item.progressObservation = nil
    }

    func open(_ item: Item) { if let url = item.destination { NSWorkspace.shared.open(url) } }
    func reveal(_ item: Item) { if let url = item.destination { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func clearInactive() { items.removeAll { $0.state != .running } }

    private func item(for download: WKDownload) -> Item? { items.first { $0.download === download } }

    /// `name.ext`, `name (1).ext`, ... never overwriting an existing file.
    static func uniqueDestination(in directory: URL, filename: String) -> URL {
        let safe = filename.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
        var candidate = directory.appendingPathComponent(safe.isEmpty ? "download" : safe)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }
}

extension BrowserDownloadCenter: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let destination = Self.uniqueDestination(in: directory, filename: suggestedFilename)
        if let item = item(for: download) {
            item.filename = destination.lastPathComponent
            item.destination = destination
        }
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.fraction = 1
        item.state = .finished
        item.progressObservation = nil
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let item = item(for: download), item.state != .cancelled else { return }
        item.state = .failed(error.localizedDescription)
        item.progressObservation = nil
    }
}

struct BrowserDownloadsShelf: View {
    let center: BrowserDownloadCenter

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { ForEach(center.items) { DownloadChip(item: $0, center: center) } }
                    .padding(.horizontal, 8)
            }
            Button("Clear") { center.clearInactive() }
                .buttonStyle(SmthzButtonStyle(.ghost, size: .xs))
                .disabled(!center.items.contains { $0.state != .running })
                .padding(.trailing, 8)
        }
        .frame(height: 40)
        .background(SmthzTheme.card)
        .overlay(alignment: .top) { Rectangle().fill(SmthzTheme.border).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Downloads")
    }

    private struct DownloadChip: View {
        let item: BrowserDownloadCenter.Item
        let center: BrowserDownloadCenter

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.filename).font(SmthzFont.ui(size: 11)).lineLimit(1).truncationMode(.middle)
                    switch item.state {
                    case .running: ProgressView(value: item.fraction).controlSize(.mini).frame(width: 110)
                    case .finished: Text("Done").font(SmthzFont.meta).foregroundStyle(SmthzTheme.mutedForeground)
                    case .cancelled: Text("Cancelled").font(SmthzFont.meta).foregroundStyle(SmthzTheme.mutedForeground)
                    case .failed(let message): Text(message).font(SmthzFont.meta).foregroundStyle(SmthzTheme.destructive).lineLimit(1)
                    }
                }
                .frame(maxWidth: 160, alignment: .leading)
                if item.state == .running {
                    Button { center.cancel(item) } label: { SmthzIcon.view(.x, size: 11) }
                        .buttonStyle(SmthzButtonStyle(.ghost, size: .iconXS)).help("Cancel download")
                } else if item.state == .finished {
                    Button { center.open(item) } label: { Image(systemName: "arrow.up.forward.square").font(.system(size: 11)) }
                        .buttonStyle(SmthzButtonStyle(.ghost, size: .iconXS)).help("Open")
                    Button { center.reveal(item) } label: { SmthzIcon.view(.folderOpen, size: 11) }
                        .buttonStyle(SmthzButtonStyle(.ghost, size: .iconXS)).help("Show in Finder")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(SmthzTheme.background))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SmthzTheme.border))
            .contextMenu {
                if item.state == .running { Button("Cancel") { center.cancel(item) } }
                if item.state == .finished { Button("Open") { center.open(item) }; Button("Show in Finder") { center.reveal(item) } }
            }
            .accessibilityElement(children: .combine)
        }

        private var icon: String {
            switch item.state {
            case .running: "arrow.down.circle"
            case .finished: "checkmark.circle"
            case .cancelled: "xmark.circle"
            case .failed: "exclamationmark.triangle"
            }
        }
        private var tint: Color {
            switch item.state {
            case .finished: SmthzTheme.statusSuccess
            case .failed: SmthzTheme.destructive
            default: SmthzTheme.mutedForeground
            }
        }
    }
}
