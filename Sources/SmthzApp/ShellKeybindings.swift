import AppKit
import Observation
import SmthzCore
import SwiftUI
import SwiftTerm

/// One effective registry feeds menus, event monitors and displayed keycaps.
@MainActor @Observable
final class SmthzKeybindings {
    static let shared = SmthzKeybindings()
    private(set) var registry: KeybindingRegistry = .defaults
    private(set) var diagnostics: [KeybindingDiagnostic] = []
    private(set) var editingNativeText = false
    private var loadedData: Data?
    let url: URL

    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        let directory = arguments.firstIndex(of: "-SmthzStateDirectory").flatMap {
            arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1]) : nil
        } ?? ApplicationIdentity.applicationSupportDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
        url = directory.appendingPathComponent("keybindings.json")
        reload()
    }
    func reload() {
        let data = try? Data(contentsOf: url)
        guard data != loadedData || diagnostics.isEmpty else { return }
        loadedData = data
        (registry, diagnostics) = KeybindingRegistry.loading(from: url)
        for diagnostic in diagnostics { NSLog("Keybindings: %@", diagnostic.message) }
    }
    func updateFocus() {
        let editing = NSApp.keyWindow?.firstResponder is NSTextView
        if editing != editingNativeText { editingNativeText = editing }
    }
    func matches(_ event: NSEvent, action: KeybindingAction) -> Bool {
        guard action.available, let chord = Self.chord(event),
              KeybindingRegistry.allowedInTerminal(chord) else { return false }
        return registry.chords(for: action).contains(chord)
    }
    func shortcut(_ action: KeybindingAction, index: Int = 0) -> KeyboardShortcut? {
        let chords = registry.chords(for: action)
        guard chords.indices.contains(index) else { return nil }
        return shortcut(chords[index])
    }
    func shortcut(_ chord: KeyChord) -> KeyboardShortcut? {
        guard KeybindingRegistry.allowedInTerminal(chord), let key = Self.equivalent(chord.key) else { return nil }
        var flags: EventModifiers = []
        if chord.command { flags.insert(.command) }
        if chord.control { flags.insert(.control) }
        if chord.option { flags.insert(.option) }
        if chord.shift { flags.insert(.shift) }
        return KeyboardShortcut(key, modifiers: flags)
    }
    func label(_ action: KeybindingAction) -> String {
        registry.chords(for: action).first.map { KeyCapView.symbols(for: $0).joined() } ?? ""
    }
    static func equivalent(_ key: String) -> KeyEquivalent? {
        let special: [String: KeyEquivalent] = ["Tab": .tab, "Enter": .return, "Escape": .escape,
            "Space": .space, "Backspace": .delete, "Delete": .deleteForward,
            "ArrowUp": .upArrow, "ArrowDown": .downArrow, "ArrowLeft": .leftArrow,
            "ArrowRight": .rightArrow, "PageUp": .pageUp, "PageDown": .pageDown,
            "Home": .home, "End": .end]
        if let value = special[key] { return value }
        if key.hasPrefix("F"), let number = Int(key.dropFirst()), (1...24).contains(number),
           let scalar = UnicodeScalar(0xF703 + number) { return KeyEquivalent(Character(scalar)) }
        let symbols = ["BracketLeft": "[", "BracketRight": "]", "Equal": "=", "Minus": "-", "Plus": "+",
            "Comma": ",", "Period": ".", "Slash": "/", "Backslash": "\\", "Semicolon": ";", "Quote": "'", "Backquote": "`"]
        let text = symbols[key] ?? key.lowercased()
        return text.count == 1 ? KeyEquivalent(text.first!) : nil
    }
    static func chord(_ event: NSEvent) -> KeyChord? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Physical punctuation keeps Shift-[ / Shift-= stable across NSEvent's
        // transformed characters ("{" / "+"). Non-US letters use their text.
        let physical: [UInt16: String] = [48: "Tab", 36: "Enter", 53: "Escape", 49: "Space",
            51: "Backspace", 117: "Delete", 116: "PageUp", 121: "PageDown", 115: "Home", 119: "End",
            123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
            30: "BracketRight", 33: "BracketLeft", 24: "Equal", 27: "Minus", 69: "NumpadAdd", 78: "NumpadSubtract",
            41: "Semicolon", 39: "Quote", 42: "Backslash", 43: "Comma", 44: "Slash", 47: "Period", 50: "Backquote",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
        let key = event.keyCode == 24 && flags.contains(.shift) ? "Plus" : physical[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased()
        guard let key else { return nil }
        return KeyChord(key: key, command: flags.contains(.command), option: flags.contains(.option),
                        control: flags.contains(.control), shift: flags.contains(.shift))
    }
}

/// Required for Ctrl-Tab, numeric selectors, alternate chords and safe overrides.
/// Native fields retain editing commands; a modal surface disables dispatch.
struct SmthzRegistryShortcutMonitor: NSViewRepresentable {
    let actions: SmthzShellActions
    let enabled: Bool
    func makeNSView(context: Context) -> Monitor { Monitor() }
    func updateNSView(_ view: Monitor, context: Context) { view.actions = actions; view.enabled = enabled }
    static func dismantleNSView(_ view: Monitor, coordinator: ()) { view.stop() }
    final class Monitor: NSView {
        var actions = SmthzShellActions()
        var enabled = true
        private var token: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, self.enabled, self.window?.isKeyWindow == true,
                          event.window === self.window, !(self.window?.firstResponder is NSTextView),
                          let chord = SmthzKeybindings.chord(event) else { return false }
                    let terminal = self.window?.firstResponder is TerminalView
                    if terminal && !KeybindingRegistry.allowedInTerminal(chord) { return false }
                    let registry = SmthzKeybindings.shared.registry
                    let scopes: [KeybindingScope] = terminal ? [.terminal, .tabs, .window] : [.tabs, .window]
                    for scope in scopes {
                        guard let action = KeybindingAction.allCases.first(where: {
                            $0.scope == scope && $0.available && registry.chords(for: $0).contains(chord)
                                && self.actions.canPerform($0)
                        }) else { continue }
                        self.actions.perform(.keybinding(action, index: registry.digitIndex(for: chord, action: action)))
                        return true
                    }
                    return false
                }
                return handled ? nil : event
            }
        }
        func stop() { if let token { NSEvent.removeMonitor(token) }; token = nil }
    }
}
