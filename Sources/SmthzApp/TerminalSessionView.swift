import AppKit
import SwiftUI
import SwiftTerm
import SmthzCore

/// Serializes control RPC away from the UI actor. Output subscriptions own
/// separate sockets, so an idle stream never blocks keyboard input or resize.
/// Failed control calls drop their connection and reconnect on the next call.
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

    func subscribe(id: String, from cursor: UInt64) throws -> AsyncThrowingStream<HostReadResult, any Error> {
        try perform { $0.subscribe(id: id, fromCursor: cursor) }
    }

    /// The absolute end of the session log: a read past the end is clamped to it.
    func end(id: String) throws -> UInt64 {
        try perform { try $0.read(id: id, from: UInt64(Int64.max), maxBytes: 1).next }
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
    var onFocus: (() -> Void)?
    /// Set only while replayed log bytes are parsed (synchronously, on the main thread). The
    /// emulator then answers queries (DA, DSR, DECRQM) that a program asked long ago; those
    /// answers must not reach the shell, where they would show up as typed text.
    nonisolated(unsafe) var dropTerminalReplies = false
    private var shortcutMonitor: Any?

    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        if dropTerminalReplies { return }
        super.send(source: source, data: data)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor); self.shortcutMonitor = nil }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.window?.firstResponder === self else { return false }
                return self.handleShortcut(event)
            }
            return handled ? nil : event
        }
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        if SmthzKeybindings.shared.matches(event, action: .terminalSearch) { showFind?(); return true }
        if SmthzKeybindings.shared.matches(event, action: .terminalClear) { clearScreen?(); return true }
        return false
    }

    override func performTextFinderAction(_ sender: Any?) { showFind?() }

    override func rightMouseDown(with event: NSEvent) {
        // A TUI with mouse reporting retains its right-button events. Shift opens the menu.
        if allowMouseReporting && currentMouseMode != .off && !event.modifierFlags.contains(.shift) {
            super.rightMouseDown(with: event)
            return
        }
        onFocus?()
        window?.makeFirstResponder(self)
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
    var onFocus: () -> Void = {}
    var onGrid: (Int, Int) -> Void = { _, _ in }
    var onExit: (ProcessExitFacts) -> Void = { _ in }
    var onPaneAction: (SmthzTerminalContextMenu.Action) -> Void = { _ in }
    private var cursor: UInt64 = 0
    /// Log offset where history ends and live output begins for this emulator.
    private var replayEnd: UInt64 = 0
    /// Replayed frames whose deferred delegate callbacks (OSC 52) are still queued on main.
    private var replayCallbacksPending = 0
    private var inputWritten = false
    private var outputReceived = false
    private var spawnedFresh = false
    private var resumed = false
    var paneID: String?
    private var directory: String?
    private var grid = (rows: 24, cols: 80)
    private lazy var contextMenu = SmthzTerminalContextMenu { [weak self] in self?.perform($0) }
    private let transport: TerminalTransport
    private let commands: AsyncStream<TerminalCommand>
    private let commandSink: AsyncStream<TerminalCommand>.Continuation
    private var outputTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var inputSourceObserver: NSObjectProtocol?

    init(sessionID: String, socketPath: String, fontSize: CGFloat, initialGrid: PaneGrid? = nil) {
        self.sessionID = sessionID
        transport = TerminalTransport(socketPath: socketPath)
        (commands, commandSink) = AsyncStream.makeStream(of: TerminalCommand.self)
        view = FocusingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        super.init()
        view.font = TerminalTheme.font(size: fontSize)
        if let initialGrid {
            grid = (rows: initialGrid.rows, cols: initialGrid.cols)
            view.resize(cols: initialGrid.cols, rows: initialGrid.rows)
        }
        view.terminalDelegate = self
        view.optionAsMetaKey = TerminalOptionKey.sendsAlt()
        // "auto" follows the input source: switching to a composing layout or IME frees Option.
        inputSourceObserver = NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.view.optionAsMetaKey = TerminalOptionKey.sendsAlt() }
        }
        if let terminal = view as? FocusingTerminalView {
            terminal.onFocus = { [weak self] in self?.onFocus() }
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
        pause()
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
    }

    /// Pause the subscription only. The emulator, command stream and absolute cursor survive.
    func pause() { outputTask?.cancel(); outputTask = nil; resumed = false }
    func resume() {
        guard !resumed, exit == nil else { return }
        resumed = true
        let id = sessionID
        let transport = transport
        outputTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let cursor = self?.cursor else { return }
                    if cursor == 0 {
                        // A fresh emulator first replays history; note where it ends.
                        let end = (try? await transport.end(id: id)) ?? 0
                        self?.replayEnd = end
                    }
                    let stream = try await transport.subscribe(id: id, from: cursor)
                    for try await result in stream {
                        guard !Task.isCancelled, let self else { return }
                        if result.truncated {
                            // The host dropped output older than its window: what we drew is stale.
                            // Start the emulator over and continue from the returned cursor.
                            self.view.resetToInitialState()
                        }
                        if !result.data.isEmpty {
                            self.outputReceived = true
                            self.feed(result.data, replaying: self.cursor < self.replayEnd)
                        }
                        // Advance only after the emulator consumed this frame. A failed
                        // bounded stream resubscribes here without gaps or duplicates.
                        self.cursor = result.next
                        if let exit = result.exit {
                            self.exit = exit
                            self.onExit(ProcessExitFacts(code: exit.code, signal: exit.signal,
                                spawnedFresh: self.spawnedFresh, restored: !self.spawnedFresh,
                                inputWritten: self.inputWritten, outputReceived: self.outputReceived,
                                tabHadPaneAtConnect: true))
                            return
                        }
                    }
                    try await Task.sleep(for: .milliseconds(100))
                } catch is CancellationError {
                    return
                } catch {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
    }

    private func feed(_ data: Data, replaying: Bool) {
        guard replaying, let terminal = view as? FocusingTerminalView else {
            view.feed(byteArray: ArraySlice(data))
            return
        }
        terminal.dropTerminalReplies = true
        view.feed(byteArray: ArraySlice(data))
        terminal.dropTerminalReplies = false
        // SwiftTerm queues OSC 52 callbacks on the main queue during the feed; this block runs
        // after them, so the clipboard gate sees them as replayed.
        replayCallbacksPending += 1
        DispatchQueue.main.async { [weak self] in self?.replayCallbacksPending -= 1 }
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
        default: onPaneAction(action)
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
        pause()
        commandTask?.cancel()
        commandSink.finish()
        if let inputSourceObserver { NotificationCenter.default.removeObserver(inputSourceObserver) }
        inputSourceObserver = nil
        let transport = transport
        Task { await transport.close() }
    }

    // MARK: TerminalViewDelegate (SwiftTerm calls these on the main thread)

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        Task { @MainActor [weak self] in
            TerminalSizeHint.latest = (rows: newRows, cols: newCols)
            self?.grid = (rows: newRows, cols: newCols)
            self?.onGrid(newCols, newRows)
        }
        commandSink.yield(.resize(rows: newRows, cols: newCols))
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        Task { @MainActor [weak self] in self?.inputWritten = true }
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
        // Checked synchronously: a hop would run after the replay fence has drained.
        let allowed = MainActor.assumeIsolated {
            TerminalClipboardPolicy.allowsWrite(settingEnabled: TerminalClipboardPolicy.writesEnabled(),
                replaying: replayCallbacksPending > 0, byteCount: content.count)
        }
        guard allowed, let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// OSC 52 reads are never answered (see TerminalClipboardPolicy).
    nonisolated func clipboardRead(source: TerminalView) -> Data? { nil }
}

/// Hosts the terminal inset by the theme padding on a theme-coloured background, and follows the
/// system appearance.
final class TerminalContainerView: NSView {
    let terminal: TerminalView
    var wasActive = false
    /// Focus asked for before the view reached a window (a tab's first pane); granted on arrival.
    var wantsFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsFocus, let window else { return }
        wantsFocus = false
        window.makeFirstResponder(terminal)
    }

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
    var cachedController: TerminalSessionController? = nil
    var visible = true
    var onFocus: () -> Void = {}
    var onGrid: (Int, Int) -> Void = { _, _ in }
    var onExit: (ProcessExitFacts) -> Void = { _ in }
    var onPaneAction: (SmthzTerminalContextMenu.Action) -> Void = { _ in }
    @State private var replacementID: String?

    var body: some View {
        SmthzTerminalPane(sessionID: replacementID ?? sessionID, socketPath: socketPath,
            fontSize: fontSize, isActive: isActive, paneID: paneID,
            onTitleChange: onTitleChange, onDirectoryChange: onDirectoryChange,
            onRestart: { session in replacementID = session.id; onSessionRestart(session) }, onClose: onClose, restartSession: restartSession,
            cachedController: cachedController, visible: visible, onFocus: onFocus, onGrid: onGrid,
            onExit: onExit, onPaneAction: onPaneAction)
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
    let visible: Bool
    let onFocus: () -> Void
    let onGrid: (Int, Int) -> Void
    let onExit: (ProcessExitFacts) -> Void
    let onPaneAction: (SmthzTerminalContextMenu.Action) -> Void

    init(sessionID: String, socketPath: String, fontSize: Double, isActive: Bool, paneID: String?,
         onTitleChange: @escaping (String) -> Void, onDirectoryChange: @escaping (String?) -> Void,
         onRestart: @escaping (SessionInfo) -> Void, onClose: (() -> Void)?, restartSession: (() async -> Void)?,
         cachedController: TerminalSessionController?, visible: Bool, onFocus: @escaping () -> Void,
         onGrid: @escaping (Int, Int) -> Void, onExit: @escaping (ProcessExitFacts) -> Void,
         onPaneAction: @escaping (SmthzTerminalContextMenu.Action) -> Void) {
        _controller = StateObject(wrappedValue: cachedController ?? TerminalSessionController(sessionID: sessionID,
            socketPath: socketPath, fontSize: fontSize))
        self.fontSize = fontSize
        self.isActive = isActive
        self.paneID = paneID
        self.onTitleChange = onTitleChange
        self.onDirectoryChange = onDirectoryChange
        self.onRestart = onRestart
        self.onClose = onClose
        self.restartSession = restartSession
        self.visible = visible
        self.onFocus = onFocus
        self.onGrid = onGrid
        self.onExit = onExit
        self.onPaneAction = onPaneAction
    }

    var body: some View {
        SmthzTerminalSurface(controller: controller, fontSize: fontSize, isActive: isActive,
            paneID: paneID, onTitleChange: onTitleChange, onDirectoryChange: onDirectoryChange,
            visible: visible, onFocus: onFocus, onGrid: onGrid, onExit: onExit, onPaneAction: onPaneAction)
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

    let visible: Bool
    let onFocus: () -> Void
    let onGrid: (Int, Int) -> Void
    let onExit: (ProcessExitFacts) -> Void
    let onPaneAction: (SmthzTerminalContextMenu.Action) -> Void

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
        if visible { controller.resume() } else { controller.pause() }
        if visible && isActive && !container.wasActive {
            DispatchQueue.main.async { [weak container] in
                guard let container else { return }
                guard let window = container.window else { container.wantsFocus = true; return }
                window.makeFirstResponder(container.terminal)
            }
        }
        container.wasActive = visible && isActive
    }

    private func updateCallbacks() {
        controller.onFocus = onFocus
        controller.onGrid = onGrid
        controller.onExit = onExit
        controller.onPaneAction = onPaneAction
        controller.paneID = paneID
        controller.onTitleChange = onTitleChange
        controller.onDirectoryChange = onDirectoryChange
    }

    static func dismantleNSView(_ view: TerminalContainerView, coordinator: TerminalSessionController) {
        coordinator.pause()
    }
}
