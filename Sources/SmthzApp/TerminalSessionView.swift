import AppKit
import SwiftUI
import SwiftTerm
import SmthzCore

/// One persistent host connection per terminal. Reads and writes are serialized by the actor;
/// synchronous RPC never runs on the UI actor. A failed call drops the connection and the next
/// call reconnects, so a host restart only costs a retry.
private actor TerminalTransport {
    private let socketPath: String
    private var client: HostClient?

    init(socketPath: String) { self.socketPath = socketPath }

    private func connected() throws -> HostClient {
        if let client { return client }
        let created = try HostClient(socketPath: socketPath)
        client = created
        return created
    }

    private func perform<T>(_ body: (HostClient) throws -> T) throws -> T {
        do { return try body(try connected()) }
        catch {
            client?.disconnect()
            client = nil
            throw error
        }
    }

    func read(id: String, from cursor: UInt64) throws -> HostReadResult {
        try perform { try $0.read(id: id, from: cursor, maxBytes: 65_536) }
    }

    func write(id: String, data: Data) throws { try perform { _ = try $0.write(id: id, data: data) } }

    func resize(id: String, rows: Int, cols: Int) throws {
        try perform { _ = try $0.resize(id: id, rows: rows, cols: cols) }
    }

    func restart(id: String, directory: String?, rows: Int, cols: Int) throws -> SessionInfo {
        try perform { client in
            guard let original = try client.list().sessions.first(where: { $0.id == id }) else {
                throw HostClientError.hostError(code: "sessionNotFound")
            }
            return try client.createSession(executable: original.executable ?? "/bin/zsh",
                arguments: original.arguments ?? ["-l"], cwd: directory ?? original.cwd,
                rows: rows, cols: cols)
        }
    }

    func close() {
        client?.disconnect()
        client = nil
    }
}

private enum TerminalCommand: Sendable {
    case write(Data)
    case resize(rows: Int, cols: Int)
}

/// Takes keyboard focus as soon as it is in a window, so a fresh session accepts typing at once.
private final class FocusingTerminalView: TerminalView {
    var showFind: (() -> Void)?
    var clearScreen: (() -> Void)?
    var makeContextMenu: (() -> NSMenu)?
    private var shortcutMonitor: Any?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor); self.shortcutMonitor = nil }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.window?.firstResponder === self else { return false }
                return self.handleShortcut(event)
            }
            return handled ? nil : event
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": showFind?(); return true
        case "k": clearScreen?(); return true
        default: return false
        }
    }

    override func performTextFinderAction(_ sender: Any?) { showFind?() }

    override func rightMouseDown(with event: NSEvent) {
        // A TUI with mouse reporting retains its right-button events. Shift opens the menu.
        if allowMouseReporting && currentMouseMode != .off && !event.modifierFlags.contains(.shift) {
            super.rightMouseDown(with: event)
            return
        }
        guard let menu = makeContextMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// Connects a SwiftTerm view to one host session: host output is replayed from the start of the
/// session log into the emulator, keystrokes go to `session.write`, and the real cell grid goes to
/// `session.resize`.
@MainActor
final class TerminalSessionController: NSObject, ObservableObject, TerminalViewDelegate {
    let sessionID: String
    let view: TerminalView
    @Published var exit: HostSessionExit?
    @Published var showingFind = false
    @Published var query = ""
    @Published var caseSensitive = false
    @Published var regex = false
    @Published var searchResult = ""
    @Published var restarting = false
    @Published var restartError: String?
    var onTitleChange: (String) -> Void = { _ in }
    var onDirectoryChange: (String?) -> Void = { _ in }
    var paneID: String?
    private var directory: String?
    private var grid = (rows: 24, cols: 80)
    private lazy var contextMenu = SmthzTerminalContextMenu { [weak self] in self?.perform($0) }
    private let transport: TerminalTransport
    private let commands: AsyncStream<TerminalCommand>
    private let commandSink: AsyncStream<TerminalCommand>.Continuation
    private var outputTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?

    init(sessionID: String, socketPath: String, fontSize: CGFloat) {
        self.sessionID = sessionID
        transport = TerminalTransport(socketPath: socketPath)
        (commands, commandSink) = AsyncStream.makeStream(of: TerminalCommand.self)
        view = FocusingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        super.init()
        view.font = TerminalTheme.font(size: fontSize)
        view.terminalDelegate = self
        view.optionAsMetaKey = true
        if let terminal = view as? FocusingTerminalView {
            terminal.showFind = { [weak self] in self?.showingFind = true }
            terminal.clearScreen = { [weak self] in self?.clearScreen() }
            terminal.makeContextMenu = { [weak self] in
                guard let self else { return NSMenu() }
                self.contextMenu.runQuickCommand = { [weak self] text in
                    self?.commandSink.yield(.write(Data(text.utf8)))
                }
                return self.contextMenu.make(canCopy: self.view.getSelection() != nil,
                    canPaste: NSPasteboard.general.string(forType: .string) != nil, paneID: self.paneID,
                    quickCommands: SmthzQuickCommandStore.shared.visibleCommands(projectID: "Default workspace"))
            }
        }
        start()
    }

    private func start() {
        let id = sessionID
        let transport = transport
        let commands = commands
        // Ordered command pump: keystrokes and resizes reach the host in the order they happened.
        commandTask = Task.detached {
            for await command in commands {
                if Task.isCancelled { return }
                for attempt in 0..<3 {
                    do {
                        switch command {
                        case .write(let data): try await transport.write(id: id, data: data)
                        case .resize(let rows, let cols): try await transport.resize(id: id, rows: rows, cols: cols)
                        }
                        break
                    } catch {
                        if attempt == 2 || Task.isCancelled { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
        }
        outputTask = Task { [weak self] in
            var cursor: UInt64 = 0
            while !Task.isCancelled {
                do {
                    let result = try await transport.read(id: id, from: cursor)
                    guard !Task.isCancelled, let self else { return }
                    cursor = result.next
                    if result.truncated {
                        // The host dropped output older than its window: what we drew is stale.
                        // Start the emulator over and continue from the returned cursor.
                        self.view.resetToInitialState()
                    }
                    if !result.data.isEmpty {
                        self.view.feed(byteArray: ArraySlice(result.data))
                        continue // drain a backlog without sleeping
                    }
                    if let exit = result.exit {
                        self.exit = exit
                        return
                    }
                    try await Task.sleep(for: .milliseconds(25))
                } catch is CancellationError {
                    return
                } catch {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
    }

    func clearScreen() {
        // Local emulator operation: never inject a shell command into a running program.
        view.feed(text: "\u{1B}[3J\u{1B}[H\u{1B}[2J")
    }

    private func perform(_ action: SmthzTerminalContextMenu.Action) {
        switch action {
        case .quickCommands:
            NotificationCenter.default.post(name: .init("smthz.terminal.quickCommands"), object: sessionID)
        case .copy: view.copy(self)
        case .selectAll: view.selectAll(nil)
        case .paste: view.paste(self)
        case .copyTerminalID: copyID(sessionID)
        case .copyPaneID: if let paneID { copyID(paneID) }
        case .clear: clearScreen()
        case .reset: view.resetToInitialState()
        }
    }

    private func copyID(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func find(previous: Bool = false, reset: Bool = false) {
        if reset { view.clearSearch() }
        guard !query.isEmpty else { view.clearSearch(); searchResult = ""; return }
        let options = SearchOptions(caseSensitive: caseSensitive, regex: regex)
        if previous { view.findPrevious(query, options: options) }
        else { view.findNext(query, options: options) }
        let summary = view.searchMatchSummary(query, options: options)
        searchResult = summary.total == 0 ? "No results" : "\(summary.index)/\(summary.total)"
    }

    func closeFind() {
        showingFind = false
        view.clearSearch()
        view.window?.makeFirstResponder(view)
    }

    func restart() async -> SessionInfo? {
        guard !restarting else { return nil }
        restarting = true
        restartError = nil
        defer { restarting = false }
        do {
            return try await transport.restart(id: sessionID, directory: directory,
                rows: grid.rows, cols: grid.cols)
        } catch {
            restartError = String(describing: error)
            return nil
        }
    }

    func stop() {
        outputTask?.cancel()
        commandTask?.cancel()
        commandSink.finish()
        let transport = transport
        Task { await transport.close() }
    }

    // MARK: TerminalViewDelegate (SwiftTerm calls these on the main thread)

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        Task { @MainActor [weak self] in
            TerminalSizeHint.latest = (rows: newRows, cols: newCols)
            self?.grid = (rows: newRows, cols: newCols)
        }
        commandSink.yield(.resize(rows: newRows, cols: newCols))
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        commandSink.yield(.write(Data(data)))
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        Task { @MainActor [weak self] in self?.onTitleChange(title) }
    }
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        Task { @MainActor [weak self] in
            // OSC 7 may publish a file URL; the host session API expects a local path.
            let path = directory.flatMap { value in
                if let url = URL(string: value), url.isFileURL { return url.path }
                return value.hasPrefix("/") ? value : nil
            }
            self?.directory = path
            self?.onDirectoryChange(path)
        }
    }
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    nonisolated func bell(source: TerminalView) { NSSound.beep() }
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Hosts the terminal inset by the theme padding on a theme-coloured background, and follows the
/// system appearance.
final class TerminalContainerView: NSView {
    let terminal: TerminalView

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        let pad = TerminalTheme.padding
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        let theme = TerminalTheme.resolve(for: effectiveAppearance)
        layer?.backgroundColor = theme.background.cgColor
        theme.apply(to: terminal)
        terminal.needsDisplay = true
    }
}

/// Integration callbacks let UI-29 update the existing tab slot without owning shell state here.
struct TerminalSessionView: View {
    let sessionID: String
    let socketPath: String
    let fontSize: Double
    var isActive: Bool = true
    var paneID: String? = nil
    var onTitleChange: (String) -> Void = { _ in }
    var onDirectoryChange: (String?) -> Void = { _ in }
    var onSessionRestart: (SessionInfo) -> Void = { _ in }
    var restartSession: (() async -> Void)? = nil
    var onClose: (() -> Void)? = nil
    @State private var replacementID: String?

    var body: some View {
        SmthzTerminalPane(sessionID: replacementID ?? sessionID, socketPath: socketPath,
            fontSize: fontSize, isActive: isActive, paneID: paneID,
            onTitleChange: onTitleChange, onDirectoryChange: onDirectoryChange,
            onRestart: { session in replacementID = session.id; onSessionRestart(session) }, onClose: onClose, restartSession: restartSession)
            .id(replacementID ?? sessionID)
            .onChange(of: sessionID) { replacementID = nil }
    }
}

private struct SmthzTerminalPane: View {
    @StateObject private var controller: TerminalSessionController
    let fontSize: Double
    let isActive: Bool
    let paneID: String?
    let onTitleChange: (String) -> Void
    let onDirectoryChange: (String?) -> Void
    let onRestart: (SessionInfo) -> Void
    let onClose: (() -> Void)?
    let restartSession: (() async -> Void)?

    init(sessionID: String, socketPath: String, fontSize: Double, isActive: Bool, paneID: String?,
         onTitleChange: @escaping (String) -> Void, onDirectoryChange: @escaping (String?) -> Void,
         onRestart: @escaping (SessionInfo) -> Void, onClose: (() -> Void)?, restartSession: (() async -> Void)?) {
        _controller = StateObject(wrappedValue: TerminalSessionController(sessionID: sessionID,
            socketPath: socketPath, fontSize: fontSize))
        self.fontSize = fontSize
        self.isActive = isActive
        self.paneID = paneID
        self.onTitleChange = onTitleChange
        self.onDirectoryChange = onDirectoryChange
        self.onRestart = onRestart
        self.onClose = onClose
        self.restartSession = restartSession
    }

    var body: some View {
        SmthzTerminalSurface(controller: controller, fontSize: fontSize, isActive: isActive,
            paneID: paneID, onTitleChange: onTitleChange, onDirectoryChange: onDirectoryChange)
            .overlay(alignment: .topTrailing) {
                if controller.showingFind {
                    SmthzTerminalFindBar(query: $controller.query, caseSensitive: $controller.caseSensitive,
                        regex: $controller.regex, result: controller.searchResult,
                        previous: { controller.find(previous: true) }, next: { controller.find() },
                        close: { controller.closeFind() })
                        .padding(8)
                }
            }
            .overlay {
                if let exit = controller.exit {
                    SmthzTerminalExitOverlay(exit: exit, restarting: controller.restarting,
                        error: controller.restartError, close: onClose, restart: {
                            Task {
                                if let restartSession { await restartSession() }
                                else if let session = await controller.restart() { onRestart(session) }
                            }
                        })
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("smthz.terminal.clear"))) { note in
                if note.object as? String == controller.sessionID { controller.clearScreen() }
            }
            .onChange(of: controller.query) { controller.find(reset: true) }
            .onChange(of: controller.caseSensitive) { controller.find(reset: true) }
            .onChange(of: controller.regex) { controller.find(reset: true) }
    }
}

private struct SmthzTerminalSurface: NSViewRepresentable {
    let controller: TerminalSessionController
    let fontSize: Double
    let isActive: Bool
    let paneID: String?
    let onTitleChange: (String) -> Void
    let onDirectoryChange: (String?) -> Void

    func makeCoordinator() -> TerminalSessionController { controller }

    func makeNSView(context: Context) -> TerminalContainerView {
        updateCallbacks()
        return TerminalContainerView(terminal: controller.view)
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        updateCallbacks()
        if container.terminal.font.pointSize != fontSize {
            container.terminal.font = TerminalTheme.font(size: fontSize)
        }
        container.alphaValue = isActive ? 1 : TerminalTheme.inactiveOpacity
    }

    private func updateCallbacks() {
        controller.paneID = paneID
        controller.onTitleChange = onTitleChange
        controller.onDirectoryChange = onDirectoryChange
    }

    static func dismantleNSView(_ view: TerminalContainerView, coordinator: TerminalSessionController) {
        coordinator.stop()
    }
}
