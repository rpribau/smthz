import AppKit

/// Native terminal and pane actions, routed to the owning pane.
@MainActor
final class SmthzTerminalContextMenu: NSObject {
    enum Action: Int { case quickCommands, copy, selectAll, paste, copyTerminalID, copyPaneID, clear, reset, splitRight, splitDown, equalize, expand, setTitle, copyContext }
    var perform: (Action) -> Void
    var runQuickCommand: (String) -> Void = { _ in }

    init(perform: @escaping (Action) -> Void) { self.perform = perform }

    func make(canCopy: Bool, canPaste: Bool, paneID: String?, quickCommands: [SmthzQuickCommand] = []) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        add("Copy", icon: "copy", action: .copy, key: "c", enabled: canCopy, to: menu)
        add("Copy Context", icon: "copy", action: .copyContext, to: menu)
        add("Select All", icon: "text-select", action: .selectAll, key: "a", to: menu)
        add("Paste", icon: "clipboard", action: .paste, key: "v", enabled: canPaste, to: menu)
        let quick = NSMenuItem(title: "Quick Commands", action: nil, keyEquivalent: "")
        quick.image = icon("play")
        let submenu = NSMenu()
        if quickCommands.isEmpty {
            let empty = NSMenuItem(title: "No quick commands", action: nil, keyEquivalent: "")
            empty.isEnabled = false; submenu.addItem(empty)
        }
        for command in quickCommands {
            let item = NSMenuItem(title: command.label, action: #selector(runQuick(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = command.terminalInput; submenu.addItem(item)
        }
        submenu.addItem(.separator())
        add("Add Quick Command…", icon: "plus", action: .quickCommands, to: submenu)
        quick.submenu = submenu; menu.addItem(quick)
        menu.addItem(.separator())
        add("Split Terminal Right", icon: "panel-right-close", action: .splitRight, key: "d", enabled: paneID != nil, to: menu)
        add("Split Terminal Down", icon: "panel-bottom-close", action: .splitDown, key: "d", modifiers: [.command, .shift], enabled: paneID != nil, to: menu)
        add("Equalize Pane Sizes", icon: "panels-top-left", action: .equalize, enabled: paneID != nil, to: menu)
        add("Expand Pane", icon: "minimize-2", action: .expand, key: "\r", modifiers: [.command, .shift], enabled: paneID != nil, to: menu)
        menu.addItem(.separator())
        add("Set Title…", icon: "pencil", action: .setTitle, enabled: paneID != nil, to: menu)
        add("Copy Terminal ID", icon: "copy", action: .copyTerminalID, to: menu)
        add("Copy Pane ID", icon: "copy", action: .copyPaneID, enabled: paneID != nil, to: menu)
        menu.addItem(.separator())
        add("Clear Screen", icon: "eraser", action: .clear, key: "k", to: menu)
        add("Reset Terminal", icon: "rotate-ccw", action: .reset, to: menu)
        return menu
    }

    private func icon(_ name: String) -> NSImage? {
        guard let source = SmthzIcon.nsImage(.init(rawValue: name)) else { return nil }
        let copy = source.copy() as! NSImage
        copy.size = NSSize(width: 14, height: 14)
        return copy
    }

    private func add(_ title: String, icon name: String, action: Action? = nil, key: String = "",
                     modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action == nil ? nil : #selector(invoke(_:)), keyEquivalent: key)
        item.target = self
        item.tag = action?.rawValue ?? -1
        item.keyEquivalentModifierMask = modifiers
        item.image = icon(name)
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func runQuick(_ sender: NSMenuItem) {
        if let input = sender.representedObject as? String { runQuickCommand(input) }
    }
    @objc private func invoke(_ sender: NSMenuItem) {
        guard let action = Action(rawValue: sender.tag) else { return }
        perform(action)
    }
}
