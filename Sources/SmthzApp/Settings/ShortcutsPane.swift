import AppKit
import Observation
import SmthzCore
import SwiftUI

/// Settings › Shortcuts (Orca `ShortcutsPane`): edits `<state-dir>/keybindings.json` through
/// `KeybindingOverrideFile` and reloads `SmthzKeybindings.shared`, so menus, keycaps and the
/// registry monitor pick up every change immediately.
@MainActor @Observable
final class ShortcutsEditorModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", modified = "Modified", unassigned = "Unassigned", conflicts = "Conflicts"
        var id: String { rawValue }
    }

    struct Row: Identifiable {
        let definition: KeybindingDefinition
        let effective: [KeyChord]
        let modified: Bool
        let warnings: [String]
        var id: String { definition.action.rawValue }
    }

    struct Recording: Equatable {
        let action: KeybindingAction
        let index: Int
    }

    var query = ""
    var filter: Filter = .all
    var recording: Recording?
    private(set) var errors: [KeybindingAction: String] = [:]
    /// Bindings right before Disable, so Enable can restore them.
    private(set) var disableMemory: [KeybindingAction: [KeyChord]] = [:]
    private(set) var entries: [String: [String]] = [:]
    private(set) var fileError: String?
    let file: KeybindingOverrideFile

    init(file: KeybindingOverrideFile = KeybindingOverrideFile(url: SmthzKeybindings.shared.url)) {
        self.file = file
        refresh()
    }

    var registry: KeybindingRegistry { SmthzKeybindings.shared.registry }
    var diagnostics: [KeybindingDiagnostic] { SmthzKeybindings.shared.diagnostics }

    func refresh() {
        SmthzKeybindings.shared.reload()
        do { entries = try file.entries(); fileError = nil }
        catch { entries = [:]; fileError = "\(error)" }
    }

    var rows: [Row] {
        let registry = registry
        return KeybindingRegistry.definitions.map { definition in
            let action = definition.action
            let effective = registry.representativeChords(for: action)
            let warnings = registry.chords(for: action).flatMap { chord in
                let others = registry.conflictingActions(for: action, chord: chord)
                return others.isEmpty ? [] : ["\(Self.display(chord)) conflicts with \(others.map(\.definition.title).joined(separator: ", "))."]
            }
            return Row(definition: definition, effective: effective, modified: entries[action.rawValue] != nil,
                       warnings: Array(Set(warnings)).sorted())
        }
    }

    /// Rows matching the page-level settings search and the local query (title, id, group, keys).
    func searchedRows(settingsSearch: String) -> [Row] {
        let global = settingsSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let local = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = rows
        func text(_ row: Row) -> [String] {
            [row.definition.title, row.definition.action.rawValue, row.definition.group,
             row.effective.map(Self.display).joined(separator: " "), row.effective.map(\.formatted).joined(separator: " ")]
                .map { $0.lowercased() }
        }
        // A page found by title alone keeps every row (Orca buildShortcutGlobalSearchMatcher).
        let globalHits = global.isEmpty ? all : all.filter { text($0).contains { $0.contains(global) } }
        let base = globalHits.isEmpty ? all : globalHits
        return local.isEmpty ? base : base.filter { text($0).contains { $0.contains(local) } }
    }

    func matches(_ row: Row, _ filter: Filter) -> Bool {
        switch filter {
        case .all: true
        case .modified: row.modified
        case .unassigned: row.effective.isEmpty
        case .conflicts: !row.warnings.isEmpty
        }
    }

    // MARK: Edits

    func startRecording(_ action: KeybindingAction, at index: Int) {
        errors[action] = nil
        recording = Recording(action: action, index: index)
    }

    func cancelRecording() { recording = nil }

    func capture(_ chord: KeyChord) {
        guard let recording else { return }
        let action = recording.action
        switch KeybindingOverrideFile.validate(chord, for: action) {
        case .failure(let error): errors[action] = error.description; return
        case .success(let value):
            var current = registry.representativeChords(for: action)
            if recording.index >= current.count { if !current.contains(value) { current.append(value) } }
            else { current[recording.index] = value }
            if save(current, for: action) { self.recording = nil }
        }
    }

    func remove(_ action: KeybindingAction, at index: Int) {
        var current = registry.representativeChords(for: action)
        guard current.indices.contains(index) else { return }
        current.remove(at: index)
        if let recording, recording.action == action {
            self.recording = recording.index == index ? nil
                : Recording(action: action, index: recording.index > index ? recording.index - 1 : recording.index)
        }
        _ = save(current, for: action)
    }

    func disable(_ action: KeybindingAction) {
        disableMemory[action] = registry.representativeChords(for: action)
        if recording?.action == action { recording = nil }
        _ = save([], for: action)
    }

    func enable(_ action: KeybindingAction) {
        guard let remembered = disableMemory[action], !remembered.isEmpty else { return }
        if save(remembered, for: action) { disableMemory[action] = nil }
    }

    func reset(_ action: KeybindingAction) {
        if recording?.action == action { recording = nil }
        perform(action) { try file.reset(action) }
    }

    func resetAll() {
        recording = nil
        errors = [:]
        perform(nil) { try file.resetAll() }
    }

    /// Ensures the file exists (as `{}`) so external editors can open it.
    func ensureFile() -> URL? {
        if !FileManager.default.fileExists(atPath: file.url.path) {
            do { try file.resetAll() } catch { fileError = "\(error)"; return nil }
            refresh()
        }
        return file.url
    }

    @discardableResult
    private func save(_ chords: [KeyChord], for action: KeybindingAction) -> Bool {
        perform(action) { try file.setBindings(chords, for: action) }
    }

    @discardableResult
    private func perform(_ action: KeybindingAction?, _ body: () throws -> [KeybindingDiagnostic]) -> Bool {
        do {
            _ = try body()
            if let action { errors[action] = nil }
            refresh()
            return true
        } catch {
            if let action { errors[action] = "\(error)" } else { fileError = "\(error)" }
            return false
        }
    }

    static func display(_ chord: KeyChord) -> String { KeyCapView.symbols(for: chord).joined() }
}

struct ShortcutsPane: View {
    var settingsSearch = ""
    @State private var model = ShortcutsEditorModel()
    @State private var confirmResetAll = false

    var body: some View {
        let searched = model.searchedRows(settingsSearch: settingsSearch)
        let visible = searched.filter { model.matches($0, model.filter) }
        VStack(alignment: .leading, spacing: 24) {
            // VISUAL-ONLY: terminal-first dispatch needs the registry monitor to defer to the focused TUI.
            SmthzUnavailableSetting("Shortcuts in Terminal", detail: "Decide who first intercepts shortcuts", value: "smthz first")
            header
            diagnostics
            filterRail(searched: searched, visibleCount: visible.count)
            rowsList(visible)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .background(ShortcutCaptureMonitor(active: model.recording != nil,
                                           onCapture: { model.capture($0) },
                                           onCancel: { model.cancelRecording() },
                                           onUnsupported: { action in model.reportUnsupported(action) }))
        .confirmationDialog("Reset all shortcuts?", isPresented: $confirmResetAll) {
            Button("Reset All Shortcuts", role: .destructive) { model.resetAll() }
        } message: {
            Text("Every customized or disabled shortcut returns to its default. keybindings.json becomes empty.")
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) { headerText; Spacer(minLength: 8); fileActions }
            VStack(alignment: .leading, spacing: 12) { headerText; fileActions }
        }
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Keyboard Shortcuts").font(SmthzFont.ui(size: 14, weight: .medium)).accessibilityAddTraits(.isHeader)
            (Text("Customize shortcuts visually or edit ")
                + Text(abbreviatedPath).font(SmthzFont.mono(size: 11))
                + Text(" directly."))
                .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var abbreviatedPath: String {
        (model.file.url.path as NSString).abbreviatingWithTildeInPath
    }

    private var fileActions: some View {
        HStack(spacing: 0) {
            Button {
                if let url = model.ensureFile() { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 6) { SmthzIcon.view("file-text", size: 12); Text("Open with Default App") }
                    .font(SmthzFont.ui(size: 12)).padding(.horizontal, 8).frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            SmthzTheme.border.frame(width: 1, height: 24)
            Menu {
                ForEach(Self.editors, id: \.bundleID) { editor in
                    let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID)
                    Button("Open in \(editor.name)") {
                        guard let app, let url = model.ensureFile() else { return }
                        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                    }.disabled(app == nil)
                }
                Divider()
                Button("Reveal in Finder") {
                    if let url = model.ensureFile() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Reload from Disk") { model.refresh() }
                Divider()
                Button("Reset All Shortcuts…") { confirmResetAll = true }
                    .disabled(model.entries.isEmpty)
            } label: {
                SmthzIcon.view(.chevronDown, size: 12).frame(width: 24, height: 24)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Open keybindings file menu")
        }
        .foregroundStyle(SmthzTheme.foreground)
        .background(SmthzTheme.background, in: RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD))
        .overlay { RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD).strokeBorder(SmthzTheme.border, lineWidth: 1) }
        .fixedSize()
    }

    private static let editors: [(name: String, bundleID: String)] = [
        ("VS Code", "com.microsoft.VSCode"), ("Cursor", "com.todesktop.230313mzl4w4u92")]

    @ViewBuilder private var diagnostics: some View {
        let messages = (model.fileError.map { [KeybindingDiagnostic(severity: .error, message: $0)] } ?? []) + model.diagnostics
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, diagnostic in
                    Text(diagnostic.message).font(SmthzFont.ui(size: 12))
                        .foregroundStyle(diagnostic.severity == .error ? SmthzTheme.destructive : SmthzTheme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func filterRail(searched: [ShortcutsEditorModel.Row], visibleCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Find shortcuts").font(SmthzFont.ui(size: 12, weight: .medium))
                    Spacer()
                    Text("\(visibleCount)/\(model.rows.count)").font(SmthzFont.ui(size: 11)).monospacedDigit()
                        .foregroundStyle(SmthzTheme.mutedForeground)
                }
                HStack(spacing: 6) {
                    SmthzIcon.view(.search, size: 14).foregroundStyle(SmthzTheme.mutedForeground)
                    TextField("Search command or keys", text: $model.query).textFieldStyle(.plain)
                        .accessibilityLabel("Find shortcuts")
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { SmthzIcon.view(.x, size: 12) }
                            .buttonStyle(.plain).foregroundStyle(SmthzTheme.mutedForeground)
                            .accessibilityLabel("Clear shortcut search")
                    }
                }
                .font(SmthzFont.ui(size: 14))
                .padding(.horizontal, 10).frame(height: 32)
                .overlay { RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD).strokeBorder(SmthzTheme.input, lineWidth: 1) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("STATUS").font(SmthzFont.ui(size: 11, weight: .semibold)).tracking(11 * 0.05)
                    .foregroundStyle(SmthzTheme.mutedForeground)
                HStack(spacing: 4) {
                    ForEach(ShortcutsEditorModel.Filter.allCases) { option in
                        let selected = model.filter == option
                        Button { model.filter = option } label: {
                            HStack(spacing: 8) {
                                Text(option.rawValue)
                                Text("\(searched.filter { model.matches($0, option) }.count)")
                                    .font(SmthzFont.ui(size: 11)).monospacedDigit().opacity(0.8)
                            }
                            .font(SmthzFont.ui(size: 12, weight: selected ? .medium : .regular))
                            .foregroundStyle(selected ? SmthzTheme.accentForeground : SmthzTheme.mutedForeground)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(selected ? SmthzTheme.accent : .clear, in: RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Shortcut status filters")
        }
        .frame(maxWidth: 512, alignment: .leading)
    }

    @ViewBuilder private func rowsList(_ rows: [ShortcutsEditorModel.Row]) -> some View {
        if rows.isEmpty {
            Text("No shortcuts match those filters.")
                .font(SmthzFont.ui(size: 14)).foregroundStyle(SmthzTheme.mutedForeground)
                .frame(maxWidth: .infinity).padding(.vertical, 32)
                .overlay {
                    RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD)
                        .strokeBorder(SmthzTheme.border.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
        } else {
            VStack(alignment: .leading, spacing: 32) {
                ForEach(Self.grouped(rows), id: \.title) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(group.title).font(SmthzFont.ui(size: 14, weight: .medium))
                            .foregroundStyle(SmthzTheme.mutedForeground)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                            .overlay(alignment: .bottom) { SmthzTheme.border.opacity(0.5).frame(height: 1) }
                            .accessibilityAddTraits(.isHeader)
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(group.rows) { row in ShortcutCommandBlock(row: row, model: model) }
                        }
                    }
                }
            }
        }
    }

    private static func grouped(_ rows: [ShortcutsEditorModel.Row]) -> [(title: String, rows: [ShortcutsEditorModel.Row])] {
        var order: [String] = []
        var byGroup: [String: [ShortcutsEditorModel.Row]] = [:]
        for row in rows {
            if byGroup[row.definition.group] == nil { order.append(row.definition.group) }
            byGroup[row.definition.group, default: []].append(row)
        }
        return order.map { ($0, byGroup[$0]!) }
    }
}

extension ShortcutsEditorModel {
    func reportUnsupported(_ chord: KeyChord?) {
        guard let action = recording?.action else { return }
        errors[action] = "smthz cannot dispatch that key yet. Use a letter, digit, punctuation, arrow or function key."
    }
}

/// One action: title + badges, hover actions, first binding inline, extra bindings below (Orca `ShortcutCommandBlock`).
private struct ShortcutCommandBlock: View {
    let row: ShortcutsEditorModel.Row
    let model: ShortcutsEditorModel
    @State private var hovered = false

    private var action: KeybindingAction { row.definition.action }
    private var available: Bool { row.definition.available }
    private var hasBinding: Bool { !row.effective.isEmpty }
    private var isDisabled: Bool { row.modified && !hasBinding }
    private var recordingIndex: Int? { model.recording?.action == action ? model.recording?.index : nil }
    private var showAppendSlot: Bool { recordingIndex.map { $0 >= row.effective.count } ?? false }
    private var terminalPassThrough: Bool {
        available && hasBinding && row.definition.scope != .terminal
            && !row.effective.allSatisfy(KeybindingRegistry.allowedInTerminal)
    }

    private var helper: (text: String, error: Bool)? {
        if let error = model.errors[action] { return (error, true) }
        if recordingIndex != nil { return ("Press a shortcut. Esc cancels.", false) }
        if !row.warnings.isEmpty { return (row.warnings.joined(separator: " "), true) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text(row.definition.title).font(SmthzFont.ui(size: 14)).lineLimit(1)
                        .foregroundStyle(isDisabled || !available ? SmthzTheme.mutedForeground : SmthzTheme.foreground)
                    if row.modified { badge("Modified") }
                    if isDisabled { badge("Disabled") }
                    if !available { badge("Not available yet") }
                    if terminalPassThrough {
                        badge("Not from terminal", icon: "terminal")
                            .help("smthz only intercepts ⌘ chords and ⌃Tab, ⌃PgUp, ⌃PgDn, ⌃1–9 while a terminal has focus.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    HStack(spacing: 2) {
                        if hasBinding && !showAppendSlot && available {
                            iconButton("plus", label: "Add another shortcut for \(row.definition.title)", tip: "Add another shortcut") {
                                model.startRecording(action, at: row.effective.count)
                            }
                        }
                        if row.modified {
                            iconButton("rotate-ccw", label: "Reset \(row.definition.title) to default", tip: "Reset to default") {
                                model.reset(action)
                            }
                        }
                        if hasBinding && available {
                            iconButton("octagon-x", label: "Disable \(row.definition.title)", tip: "Disable shortcut", destructive: true) {
                                model.disable(action)
                            }
                        }
                        if row.effective.count >= 2 && available {
                            iconButton("x", label: "Remove \(row.definition.title) shortcut 1", tip: "Remove this binding") {
                                model.remove(action, at: 0)
                            }
                        }
                    }
                    .opacity(hovered || recordingIndex != nil ? 1 : 0)
                    if !hasBinding && !showAppendSlot && available {
                        if isDisabled && model.disableMemory[action]?.isEmpty == false {
                            Button("Enable") { model.enable(action) }
                                .buttonStyle(SmthzButtonStyle(.ghost, size: .xs))
                                .accessibilityLabel("Enable \(row.definition.title)")
                        } else {
                            iconButton("plus", label: "Add shortcut for \(row.definition.title)", tip: "Add shortcut") {
                                model.startRecording(action, at: 0)
                            }
                        }
                    }
                    if let first = row.effective.first { recorder(first, index: 0) }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4).frame(minHeight: 36)
            .background(hovered ? SmthzTheme.accent.opacity(0.4) : .clear, in: RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD))

            if let helper {
                Text(helper.text).font(SmthzFont.ui(size: 11)).lineSpacing(2)
                    .foregroundStyle(helper.error ? SmthzTheme.destructive : SmthzTheme.mutedForeground)
                    .padding(.horizontal, 8).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(row.effective.enumerated().dropFirst()), id: \.offset) { index, chord in
                subRow(chord, index: index)
            }
            if showAppendSlot { subRow(nil, index: row.effective.count) }
        }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
    }

    private func subRow(_ chord: KeyChord?, index: Int) -> some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if chord != nil && available {
                iconButton("x", label: "Remove \(row.definition.title) shortcut \(index + 1)", tip: "Remove this binding") {
                    model.remove(action, at: index)
                }
                .opacity(hovered ? 1 : 0)
            } else {
                Color.clear.frame(width: 24, height: 24)
            }
            recorder(chord, index: index)
        }
        .padding(.leading, 20).padding(.trailing, 8).padding(.vertical, 2).frame(minHeight: 32)
    }

    private func recorder(_ chord: KeyChord?, index: Int) -> some View {
        let recording = recordingIndex == index
        let count = max(row.effective.count, index + 1)
        let label = recording ? "Press shortcut keys for \(row.definition.title). Escape cancels."
            : chord == nil ? "Add shortcut for \(row.definition.title)"
            : count <= 1 ? "Change shortcut for \(row.definition.title)"
            : "Change shortcut \(index + 1) of \(count) for \(row.definition.title)"
        return Button {
            if !recording { model.startRecording(action, at: index) }
        } label: {
            Group {
                if recording || chord == nil {
                    Text("Press keys…").foregroundStyle(SmthzTheme.mutedForeground).padding(.horizontal, 4)
                } else if let chord {
                    KeyCapView.combo(keys(chord))
                }
            }
            .font(SmthzFont.ui(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(minWidth: 88, minHeight: 28, alignment: .trailing)
            .background(recording ? SmthzTheme.accent : hovered ? SmthzTheme.background : .clear,
                        in: RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD))
            .overlay {
                RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD)
                    .strokeBorder(recording ? SmthzTheme.ring : hovered ? SmthzTheme.border.opacity(0.7) : .clear,
                                  lineWidth: recording ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .help(recording ? "Listening for shortcut" : chord == nil ? "Add shortcut" : "Change shortcut")
        .accessibilityLabel(label)
        .accessibilityAddTraits(recording ? .isSelected : [])
    }

    /// Digit-index rows store ⌃1 but fire for 1–9.
    private func keys(_ chord: KeyChord) -> [String] {
        var keys = KeyCapView.symbols(for: chord)
        if KeybindingRegistry.isDigitIndex(action), keys.last == "1" { keys[keys.count - 1] = "1–9" }
        return keys
    }

    private func badge(_ text: String, icon: SmthzIcon.Name? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon { SmthzIcon.view(icon, size: 12) }
            Text(text)
        }
        .font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .overlay { Capsule().strokeBorder(SmthzTheme.border, lineWidth: 1) }
        .fixedSize()
    }

    private func iconButton(_ icon: SmthzIcon.Name, label: String, tip: String, destructive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { SmthzIcon.view(icon, size: 12).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .foregroundStyle(SmthzTheme.mutedForeground)
            .help(tip)
            .accessibilityLabel(label)
    }
}

/// While recording, a non-editable text view takes first responder (the registry monitor skips
/// `NSTextView` responders) and a window-local monitor consumes every key-down, so menu key
/// equivalents and shell shortcuts never fire mid-capture.
private struct ShortcutCaptureMonitor: NSViewRepresentable {
    let active: Bool
    let onCapture: (KeyChord) -> Void
    let onCancel: () -> Void
    let onUnsupported: (KeyChord?) -> Void

    func makeNSView(context: Context) -> CaptureView { CaptureView() }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onCapture = onCapture; view.onCancel = onCancel; view.onUnsupported = onUnsupported
        view.setActive(active)
    }

    static func dismantleNSView(_ view: CaptureView, coordinator: ()) { view.setActive(false) }

    final class CaptureView: NSView {
        var onCapture: (KeyChord) -> Void = { _ in }
        var onCancel: () -> Void = {}
        var onUnsupported: (KeyChord?) -> Void = { _ in }
        private var token: Any?
        private var previousResponder: NSResponder?
        private let sink: NSTextView = {
            let view = NSTextView(frame: .zero)
            view.isEditable = false; view.isSelectable = false; view.drawsBackground = false
            view.setAccessibilityElement(false)
            return view
        }()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if sink.superview == nil { addSubview(sink) }
            if window == nil { setActive(false) }
        }

        func setActive(_ active: Bool) {
            guard active != (token != nil) else { return }
            if active, let window {
                previousResponder = window.firstResponder
                window.makeFirstResponder(sink)
                token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    let handled = MainActor.assumeIsolated {
                        guard let self, event.window === self.window else { return false }
                        self.handle(event)
                        return true
                    }
                    return handled ? nil : event
                }
            } else {
                if let token { NSEvent.removeMonitor(token) }
                token = nil
                if let window, window.firstResponder === sink {
                    window.makeFirstResponder(previousResponder)
                }
                previousResponder = nil
            }
        }

        private func handle(_ event: NSEvent) {
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 53 && flags.isEmpty { onCancel(); return }
            // Only chords the dispatcher reproduces from NSEvent and the file parser accepts.
            guard let chord = SmthzKeybindings.chord(event),
                  let parsed = try? KeyChord.parse(chord.formatted), parsed == chord else {
                onUnsupported(SmthzKeybindings.chord(event)); return
            }
            onCapture(chord)
        }
    }
}
