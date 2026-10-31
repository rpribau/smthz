import AppKit
import SwiftUI

/// A presentation value, deliberately independent of the future ShellController.
struct ShellTabItem: Identifiable {
    let id: String
    var title: String
    var colour: Color? = nil
    var pinned = false
    var active = false
    var unread = false
    var expanded = false
    var kind = "Terminal"
    var cwd: String? = nil
    var agent: String? = nil
    var hasSplitGroups = false
}

/// Session-only colour selection; the tab's stable SwiftUI identity retains it
/// through selection, resize and reorder. UI-29 may lift it through onColourChange.
private enum SmthzTabColour: String, CaseIterable {
    case none = "None", blue = "Blue", purple = "Purple", pink = "Pink", red = "Red"
    case orange = "Orange", yellow = "Yellow", green = "Green", teal = "Teal", gray = "Gray"

    var colour: Color? {
        switch self {
        case .none: nil
        case .blue: Color(red: 59.0 / 255, green: 130.0 / 255, blue: 246.0 / 255)
        case .purple: Color(red: 168.0 / 255, green: 85.0 / 255, blue: 247.0 / 255)
        case .pink: Color(red: 236.0 / 255, green: 72.0 / 255, blue: 153.0 / 255)
        case .red: Color(red: 239.0 / 255, green: 68.0 / 255, blue: 68.0 / 255)
        case .orange: Color(red: 249.0 / 255, green: 115.0 / 255, blue: 22.0 / 255)
        case .yellow: Color(red: 234.0 / 255, green: 179.0 / 255, blue: 8.0 / 255)
        case .green: Color(red: 34.0 / 255, green: 197.0 / 255, blue: 94.0 / 255)
        case .teal: Color(red: 20.0 / 255, green: 184.0 / 255, blue: 166.0 / 255)
        case .gray: Color(red: 156.0 / 255, green: 163.0 / 255, blue: 175.0 / 255)
        }
    }
}

struct ShellTabView: View {
    let tab: ShellTabItem
    let width: CGFloat
    let select: () -> Void
    let close: () -> Void
    let rename: (String) -> Void
    let togglePin: () -> Void
    var closeOthers: (() -> Void)? = nil
    var split: ((Bool) -> Void)? = nil
    var moveToPane: ((String) -> Void)? = nil
    var equalize: (() -> Void)? = nil
    var collapsePane: (() -> Void)? = nil
    var closeSplitPane: (() -> Void)? = nil
    var onColourChange: ((Color?) -> Void)? = nil
    var onCopyResult: ((Bool) -> Void)? = nil
    @State private var selectedColour: SmthzTabColour? = nil
    @State private var hoverCardVisible = false
    @State private var hovered = false
    @State private var closeHovered = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var renameFocused: Bool
    @FocusState private var tabFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if tab.unread {
                Image(systemName: "bell.fill")
                    .resizable().scaledToFit().frame(width: 12, height: 12)
                    .foregroundStyle(SmthzTheme.statusWarning)
                    .accessibilityLabel("Unread agent completion")
            } else {
                ShellTileIcon().opacity(tab.active ? 1 : 0.7)
            }
            if let colour = displayedColour {
                Circle().fill(colour).frame(width: 5, height: 5).accessibilityHidden(true)
            }
            if tab.pinned { SmthzIcon.view(.pin, size: 12) }
            if editing {
                TextField("Rename tab \(tab.title)", text: $draft)
                    .textFieldStyle(.plain)
                    .frame(height: 20)
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { editing = false }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused && editing { commitRename() }
                    }
            } else {
                Text(tab.title).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if tab.expanded, let collapsePane {
                Button(action: collapsePane) {
                    SmthzIcon.view(.minimize2, size: 12).frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse pane")
            }
            if !tab.pinned {
                Button(action: close) {
                    SmthzIcon.view(.x, size: 12)
                        .frame(width: 16, height: 16)
                        .background(closeHovered ? SmthzTheme.muted : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .foregroundStyle(closeHovered ? SmthzTheme.foreground : SmthzTheme.mutedForeground)
                .opacity(hovered || tab.active ? 1 : 0)
                .onHover { closeHovered = $0 }
                .accessibilityLabel("Close tab \(tab.title)")
                .help("Close tab")
            }
        }
        .font(SmthzFont.ui(size: 12))
        .padding(.horizontal, 6)
        .frame(width: max(SmthzMetrics.tabWidthMin, width), height: SmthzMetrics.tabStripHeight)
        .foregroundStyle(tab.active || hovered ? SmthzTheme.foreground : SmthzTheme.mutedForeground)
        .background(tab.active ? SmthzTheme.activeTabFill : SmthzTheme.card)
        .overlay { if tab.unread { SmthzTheme.statusWarning.opacity(0.1).allowsHitTesting(false) } }
        .overlay(alignment: .top) { SmthzTheme.border.frame(height: 1).allowsHitTesting(false) }
        .overlay(alignment: .trailing) { SmthzTheme.border.frame(width: 1).allowsHitTesting(false) }
        .overlay(alignment: .bottom) {
            if tab.active { SmthzTheme.foreground.frame(height: 2).allowsHitTesting(false) }
        }
        .contentShape(Rectangle())
        .focusable(!editing)
        .focused($tabFocused)
        .focusEffectDisabled()
        .overlay {
            if tabFocused && !editing {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(SmthzTheme.ring.opacity(0.5), lineWidth: 3)
                    .padding(2).allowsHitTesting(false)
            }
        }
        .onKeyPress(.return) { select(); return .handled }
        .onKeyPress(.space) { select(); return .handled }
        .onTapGesture { if !editing { select() } }
        .onHover { hovered = $0 }
        .task(id: hovered && !editing) {
            hoverCardVisible = false
            guard hovered && !editing else { return }
            do {
                try await Task.sleep(for: .milliseconds(600))
                try Task.checkCancellation()
                hoverCardVisible = true
            } catch { }
        }
        .popover(isPresented: $hoverCardVisible, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tab.title).font(SmthzFont.ui(size: 12, weight: .medium))
                if let cwd = tab.cwd, !cwd.isEmpty {
                    Text(cwd).font(SmthzFont.ui(size: 11))
                        .foregroundStyle(SmthzTheme.mutedForeground)
                }
                HStack(spacing: 8) {
                    ShellTileIcon(size: 16)
                    Text(tab.agent ?? tab.kind).font(SmthzFont.ui(size: 11))
                        .foregroundStyle(SmthzTheme.mutedForeground)
                }
            }
            .textSelection(.enabled).padding(12).frame(maxWidth: 320, alignment: .leading)
            .foregroundStyle(SmthzTheme.foreground).background(SmthzTheme.popover)
        }
        .background(SmthzTabRenameShortcut(enabled: tab.active && !editing, rename: beginRename))
        .overlay {
            if !editing {
                SmthzTabMouseEvents(middleClick: { if !tab.pinned { close() } },
                               doubleClick: beginRename, menu: contextMenu)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(tab.active ? .isSelected : [])
        .accessibilityAction(named: "Select", select)
        .accessibilityAction(named: "Rename", beginRename)
    }

    private var displayedColour: Color? {
        if let selectedColour { return selectedColour.colour }
        return tab.colour
    }

    private func beginRename() {
        hoverCardVisible = false
        draft = tab.title
        editing = true
        renameFocused = true
    }

    private func commitRename() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { rename(title) }
        editing = false
    }

    private func contextMenu() -> NSMenu {
        hoverCardVisible = false
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.font = SmthzFont.nsUI(size: 12, wght: 450)
        menu.addAction("Split terminal right", icon: "panel-right-close", key: "d", enabled: split != nil) { split?(false) }
        menu.addAction("Split terminal down", icon: "panel-bottom-close", key: "d",
                       modifiers: [.command, .shift], enabled: split != nil) { split?(true) }
        let move = menu.addAction("Move Tab to Split", icon: "columns-2", enabled: moveToPane != nil) {}
        let directions = NSMenu()
        directions.autoenablesItems = false
        for (title, icon, side) in [("Right", "arrow-right", "right"), ("Left", "arrow-left", "left"),
                                    ("Down", "arrow-down", "bottom"), ("Up", "arrow-up", "top")] {
            directions.addAction(title, icon: icon, enabled: moveToPane != nil) { moveToPane?(side) }
        }
        move.submenu = directions
        menu.addAction("Equalize Pane Sizes", icon: "panels-top-left", enabled: equalize != nil) { equalize?() }
        menu.addAction(tab.expanded ? "Collapse Pane" : "Expand Pane", icon: "minimize-2",
                       enabled: collapsePane != nil) { collapsePane?() }
        menu.addItem(.separator())
        menu.addAction(tab.pinned ? "Unpin Tab" : "Pin Tab", icon: tab.pinned ? "pin-off" : "pin", togglePin)
        menu.addAction("Copy Tab ID", icon: "copy") {
            NSPasteboard.general.clearContents()
            let copied = NSPasteboard.general.setString(tab.id, forType: .string)
            onCopyResult?(copied)
        }
        menu.addItem(.separator())
        menu.addAction("Close", icon: "x", key: "w", enabled: !tab.pinned, close)
        menu.addAction("Close Others", icon: "list-x", enabled: closeOthers != nil) { closeOthers?() }
        if closeSplitPane != nil {
            menu.addAction("Close split pane", icon: "x", enabled: closeSplitPane != nil) { closeSplitPane?() }
        }
        menu.addItem(.separator())
        menu.addAction("Change Title", icon: "pencil", key: "r", beginRename)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Tab Color"))
        let swatches = NSMenuItem()
        let picker = NSHostingView(rootView: SmthzTabColourPicker(selected: selectedColour,
            originalColour: tab.colour) { [weak menu] swatch in
                selectedColour = swatch
                onColourChange?(swatch.colour)
                menu?.cancelTracking()
            })
        picker.frame = NSRect(x: 0, y: 0, width: 250, height: 34)
        swatches.view = picker
        menu.addItem(swatches)
        return menu
    }
}

private struct SmthzTabColourPicker: View {
    let selected: SmthzTabColour?
    let originalColour: Color?
    let choose: (SmthzTabColour) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SmthzTabColour.allCases, id: \.self) { swatch in
                let isSelected = selected == swatch
                    || (selected == nil && swatch.colour == originalColour)
                Button { choose(swatch) } label: {
                    Circle().fill(swatch.colour ?? .clear)
                        .overlay {
                            if swatch == .none {
                                Circle().strokeBorder(SmthzTheme.mutedForeground.opacity(0.5))
                                Rectangle().fill(SmthzTheme.mutedForeground.opacity(0.8))
                                    .frame(width: 12, height: 1).rotationEffect(.degrees(-45))
                            }
                        }
                        .frame(width: 16, height: 16)
                        .overlay {
                            if isSelected {
                                Circle().strokeBorder(SmthzTheme.foreground.opacity(0.7), lineWidth: 1)
                                    .padding(-3)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help(swatch.rawValue)
                .accessibilityLabel(swatch.rawValue)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 9)
    }
}

/// A window-scoped monitor handles the active tab even while its terminal owns
/// first responder; removing the view also removes the monitor.
private struct SmthzTabRenameShortcut: NSViewRepresentable {
    var enabled: Bool
    let rename: () -> Void

    func makeNSView(context: Context) -> ShortcutView { ShortcutView() }
    func updateNSView(_ view: ShortcutView, context: Context) {
        view.enabled = enabled
        view.rename = rename
    }
    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) { view.stopMonitoring() }

    final class ShortcutView: NSView {
        var enabled = false
        var rename: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, self.enabled, self.window?.isKeyWindow == true,
                          event.window === self.window,
                          event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          event.charactersIgnoringModifiers?.lowercased() == "r" else { return false }
                    self.rename()
                    return true
                }
                return handled ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// Only special mouse events are intercepted; ordinary clicks, drag and the close
/// button continue through to SwiftUI. This also handles Control-click natively.
private struct SmthzTabMouseEvents: NSViewRepresentable {
    let middleClick: () -> Void
    let doubleClick: () -> Void
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> MouseView { MouseView() }
    func updateNSView(_ view: MouseView, context: Context) {
        view.middleClick = middleClick
        view.doubleClick = doubleClick
        view.makeMenu = menu
    }

    final class MouseView: NSView {
        var middleClick: () -> Void = {}
        var doubleClick: () -> Void = {}
        var makeMenu: () -> NSMenu = { NSMenu() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard super.hitTest(point) != nil, let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp: return self
            case .otherMouseDown, .otherMouseUp: return event.buttonNumber == 2 ? self : nil
            case .leftMouseDown:
                return event.clickCount == 2 || event.modifierFlags.contains(.control) ? self : nil
            default: return nil
            }
        }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                NSMenu.popUpContextMenu(makeMenu(), with: event, for: self)
            } else if event.clickCount == 2 { doubleClick() }
        }
        override func rightMouseDown(with event: NSEvent) {
            NSMenu.popUpContextMenu(makeMenu(), with: event, for: self)
        }
        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 { middleClick() }
        }
    }
}

private final class SmthzTabMenuAction: NSObject {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
    @objc func invoke(_ sender: Any?) { perform() }
}

private extension NSMenu {
    @discardableResult
    func addAction(_ title: String, icon: String? = nil, key: String = "",
                   modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true,
                   _ action: @escaping () -> Void) -> NSMenuItem {
        let target = SmthzTabMenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(SmthzTabMenuAction.invoke(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.isEnabled = enabled
        item.target = target
        item.representedObject = target // NSMenuItem.target is weak.
        if let icon {
            let image = SmthzIcon.nsImage(.init(rawValue: icon))?.copy() as? NSImage
                ?? NSImage(systemSymbolName: SmthzIcon.sfSymbolFallback[icon] ?? "rectangle.split.2x1", accessibilityDescription: nil)
            image?.size = NSSize(width: 14, height: 14)
            item.image = image
        }
        addItem(item)
        return item
    }
}
