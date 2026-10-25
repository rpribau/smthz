// VISUAL-ONLY: stub data until host sessions populate DEBUG tab strip previews.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TabCreateAction: Identifiable {
    let id: String
    let title: String
    var icon: SmthzIcon.Name = .terminal
    var enabled = true
    var shortcut = ""
    var unavailableReason: String? = nil
    let perform: () -> Void
}

/// Value/closure boundary for M3. No dependency on ShellModel or a host connection.
struct TabStripView: View {
    let tabs: [ShellTabItem]
    let select: (String) -> Void
    let close: (String) -> Void
    let rename: (String, String) -> Void
    let togglePin: (String) -> Void
    var reorder: ((String, String, Bool) -> Void)? = nil
    var split: ((String) -> Void)? = nil
    var moveToPane: ((String) -> Void)? = nil
    var collapsePane: (() -> Void)? = nil
    var closeSplitPane: (() -> Void)? = nil
    var command: (() -> Void)? = nil
    var createActions: [TabCreateAction] = []
    var closeOthers: ((String) -> Void)? = nil
    var colourChange: ((String, Color?) -> Void)? = nil
    var copyResult: ((Bool) -> Void)? = nil
    var focused = true
    @State private var hovered = false
    @State private var plusHovered = false
    @State private var windowWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var draggedID: String?
    @State private var dropID: String?
    @State private var dropAfter = false

    var body: some View {
        GeometryReader { geometry in
            let tabWidth = windowWidth >= SmthzMetrics.tabWideWindowThreshold
                ? SmthzMetrics.tabWidthWide : SmthzMetrics.tabWidth
            HStack(spacing: 0) {
                scrollingTabs(tabWidth: tabWidth, showChevrons: geometry.size.width >= 260)
                    .frame(maxWidth: CGFloat(tabs.count) * tabWidth)
                SmthzTabCreateMenu(actions: createActions, tabs: tabs, select: select)
                .frame(width: 28, height: 28)
                .foregroundStyle(SmthzTheme.mutedForeground)
                .background(plusHovered ? SmthzTheme.accent.opacity(0.5) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .onHover { plusHovered = $0 }
                .padding(.leading, 8)
                .help("New tab")
                .accessibilityLabel("New tab")

                Spacer(minLength: 0)

                HStack(spacing: 2) {
                    Button { command?() } label: {
                        HStack(spacing: 4) {
                            SmthzIcon.view(.play, size: 14)
                            if geometry.size.width >= 480 {
                                Text("Command").font(SmthzFont.ui(size: 12, weight: .medium))
                            }
                        }.padding(.horizontal, 6).frame(height: 28)
                    }
                    .buttonStyle(TabChromeButtonStyle())
                    .disabled(command == nil)
                    .accessibilityLabel("Command")
                    .smthzTooltip("Save a quick command for this repo")
                    if let closeSplitPane {
                        Menu {
                            Button("Close split pane", role: .destructive, action: closeSplitPane)
                        } label: {
                            SmthzIcon.view(.ellipsis, size: 16).frame(width: 28, height: 28)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Pane Actions")
                    }
                }
                .foregroundStyle(SmthzTheme.mutedForeground)
                .opacity(focused || hovered ? 1 : 0.5)
                .padding(.leading, 6)
            }
            .padding(.trailing, 6)
            .frame(height: SmthzMetrics.tabStripHeight)
            .background(WindowDragRegion())
            .background(SmthzTheme.card.overlay(alignment: .bottom) {
                SmthzTheme.border.frame(height: 1).allowsHitTesting(false)
            })
            .background(TabWindowWidthReader { windowWidth = $0 })
            .onHover { hovered = $0 }
        }
        .frame(height: SmthzMetrics.tabStripHeight)
    }

    private func scrollingTabs(tabWidth: CGFloat, showChevrons: Bool) -> some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                if showChevrons && clippedLeading {
                    overflowButton(.chevronLeft, label: "Scroll tabs left") {
                        scroll(proxy, forward: false, tabWidth: tabWidth)
                    }
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(tabs) { tab in
                            ShellTabView(tab: tab, width: tabWidth,
                                select: { select(tab.id) }, close: { close(tab.id) },
                                rename: { rename(tab.id, $0) }, togglePin: { togglePin(tab.id) },
                                closeOthers: tabs.contains(where: { $0.id != tab.id && !$0.pinned })
                                    ? { closeOtherTabs(except: tab.id) } : nil,
                                split: split.map { action in { action(tab.id) } },
                                moveToPane: moveToPane.map { action in { action(tab.id) } },
                                collapsePane: collapsePane,
                                onColourChange: { colourChange?(tab.id, $0) }, onCopyResult: copyResult)
                                .id(tab.id)
                                .onDrag {
                                    draggedID = tab.id
                                    return NSItemProvider(object: tab.id as NSString)
                                }
                                .onDrop(of: [UTType.text], delegate: TabReorderDrop(
                                    target: tab.id, width: tabWidth, draggedID: $draggedID,
                                    dropID: $dropID, after: $dropAfter, reorder: reorder))
                                .overlay(alignment: dropAfter ? .trailing : .leading) {
                                    if dropID == tab.id {
                                        SmthzTheme.terminalPaneLocate.frame(width: 2)
                                            .allowsHitTesting(false)
                                    }
                                }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: TabScrollMetrics.self) { value in
                    TabScrollMetrics(offset: value.contentOffset.x,
                                     viewport: value.containerSize.width,
                                     content: value.contentSize.width)
                } action: { _, value in
                    scrollOffset = value.offset
                    viewportWidth = value.viewport
                    contentWidth = value.content
                }
                .mask {
                    HStack(spacing: 0) {
                        if clippedLeading {
                            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 24)
                        }
                        Rectangle().fill(.black)
                        if clippedTrailing {
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 24)
                        }
                    }
                }
                .onChange(of: tabs.first(where: \.active)?.id) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                if showChevrons && clippedTrailing {
                    overflowButton(.chevronRight, label: "Scroll tabs right") {
                        scroll(proxy, forward: true, tabWidth: tabWidth)
                    }
                }
            }
        }
    }

    private var clippedLeading: Bool { scrollOffset > 1 }
    private var clippedTrailing: Bool { contentWidth - viewportWidth - scrollOffset > 1 }

    private func overflowButton(_ icon: SmthzIcon.Name, label: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) { SmthzIcon.view(icon, size: 14).frame(width: 20, height: 24) }
            .buttonStyle(TabChromeButtonStyle())
            .help(label).accessibilityLabel(label)
    }

    private func scroll(_ proxy: ScrollViewProxy, forward: Bool, tabWidth: CGFloat) {
        guard !tabs.isEmpty else { return }
        let first = Int(max(0, scrollOffset) / tabWidth)
        let index = min(tabs.count - 1, max(0, first + (forward ? max(1, Int(viewportWidth / tabWidth)) : -1)))
        proxy.scrollTo(tabs[index].id, anchor: .leading)
    }

    private func closeOtherTabs(except id: String) {
        if let closeOthers { closeOthers(id); return }
        for tab in tabs where tab.id != id && !tab.pinned { close(tab.id) }
    }
}

private struct TabScrollMetrics: Equatable {
    let offset: CGFloat
    let viewport: CGFloat
    let content: CGFloat
}

private struct TabReorderDrop: DropDelegate {
    let target: String
    let width: CGFloat
    @Binding var draggedID: String?
    @Binding var dropID: String?
    @Binding var after: Bool
    let reorder: ((String, String, Bool) -> Void)?

    func validateDrop(info: DropInfo) -> Bool { draggedID != nil && reorder != nil }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { if dropID == target { dropID = nil } }
    func performDrop(info: DropInfo) -> Bool {
        guard let source = draggedID, source != target, let reorder else {
            dropID = nil; draggedID = nil
            return false
        }
        reorder(source, target, info.location.x > width / 2)
        dropID = nil
        draggedID = nil
        return true
    }
    private func update(_ info: DropInfo) {
        guard draggedID != nil, draggedID != target, reorder != nil else { return }
        dropID = target
        after = info.location.x > width / 2
    }
}

private struct TabChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChromeButton(configuration: configuration)
    }
    private struct ChromeButton: View {
        let configuration: Configuration
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .background(hovered || configuration.isPressed ? SmthzTheme.accent.opacity(0.5) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: 8).stroke(SmthzTheme.ring.opacity(0.5), lineWidth: 3)
                    }
                }
                .opacity(enabled ? 1 : 0.5)
                .onHover { hovered = $0 }
        }
    }
}

private struct TabWindowWidthReader: NSViewRepresentable {
    let changed: (CGFloat) -> Void
    func makeNSView(context: Context) -> WidthView { WidthView() }
    func updateNSView(_ view: WidthView, context: Context) { view.changed = changed }
    final class WidthView: NSView {
        var changed: (CGFloat) -> Void = { _ in }
        override func layout() {
            super.layout()
            let width = window?.frame.width ?? 0
            // Report after layout to avoid mutating SwiftUI state during its update.
            Task { @MainActor [weak self] in self?.changed(width) }
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Search stays local to the current open tabs; creation actions are supplied by the host adapter.
private struct SmthzTabCreateMenu: View {
    let actions: [TabCreateAction]
    let tabs: [ShellTabItem]
    let select: (String) -> Void
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            SmthzIcon.view(.plus, size: 14).frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            SmthzTabCreateContent(actions: actions, tabs: tabs, select: select,
                                  dismiss: { presented = false })
                .presentationCompactAdaptation(.none)
        }
    }
}

private struct SmthzTabCreateContent: View {
    let actions: [TabCreateAction]
    let tabs: [ShellTabItem]
    let select: (String) -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @State private var selectedID: String?
    @FocusState private var searchFocused: Bool

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var matches: [ShellTabItem] {
        tabs.filter { $0.title.localizedStandardContains(query.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    private var navigableIDs: [String] {
        searching ? matches.map(\.id) : actions.filter(\.enabled).map(\.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search open tabs, history, files, URLs, agents…", text: $query)
                .textFieldStyle(.plain)
                .font(SmthzFont.ui(size: 12))
                .padding(.horizontal, 8)
                .frame(height: 36)
                .focused($searchFocused)
                .onSubmit(activateSelection)
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .accessibilityLabel("Search open tabs, history, files, URLs, agents…")
            SmthzTheme.border.opacity(0.8).frame(height: 1).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 1) {
                    if searching {
                        if matches.isEmpty {
                            Text("No matching open tabs")
                                .foregroundStyle(SmthzTheme.mutedForeground)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        ForEach(matches) { tab in
                            row(id: tab.id, title: tab.title, icon: "square-terminal",
                                detail: "Switch to tab", shortcut: "", enabled: true) {
                                dismiss(); select(tab.id)
                            }
                        }
                    } else {
                        ForEach(actions) { action in
                            row(id: action.id, title: action.title, icon: action.icon.rawValue,
                                detail: nil, shortcut: action.shortcut, enabled: action.enabled) {
                                dismiss(); action.perform()
                            }
                            .help(action.unavailableReason ?? action.title)
                            .smthzTooltip(action.unavailableReason ?? action.title)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: resultHeight)
            if !searching {
                Text("Choose an action.")
                    .foregroundStyle(SmthzTheme.mutedForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 6)
            }
        }
        .font(SmthzFont.menuItem)
        .foregroundStyle(SmthzTheme.foreground)
        .padding(4)
        .frame(width: 288)
        .background(SmthzTheme.popover, in: RoundedRectangle(cornerRadius: 11))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(SmthzTheme.border.opacity(0.8)) }
        .onAppear { searchFocused = true; selectedID = navigableIDs.first }
        .onChange(of: query) { _, _ in selectedID = navigableIDs.first }
        .onChange(of: navigableIDs) { _, ids in
            if !ids.contains(selectedID ?? "") { selectedID = ids.first }
        }
        .onExitCommand(perform: dismiss)
    }

    private var resultHeight: CGFloat {
        searching ? min(320, CGFloat(max(1, matches.count)) * 44) : min(320, CGFloat(actions.count) * 29)
    }

    private func row(id: String, title: String, icon: String, detail: String?,
                     shortcut: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SmthzIcon.image(icon).resizable().scaledToFit().frame(width: 16, height: 16)
                    .foregroundStyle(SmthzTheme.mutedForeground)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    if let detail {
                        Text(detail).font(SmthzFont.ui(size: 10)).foregroundStyle(SmthzTheme.mutedForeground)
                    }
                }
                Spacer(minLength: 4)
                Text(shortcut).foregroundStyle(SmthzTheme.mutedForeground)
            }
            .padding(.horizontal, 8)
            .frame(height: detail == nil ? 28 : 43)
            .contentShape(Rectangle())
            .background(selectedID == id && enabled ? SmthzTheme.accent : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { if $0 && enabled { selectedID = id } }
        .accessibilityHint(detail ?? "")
    }

    private func moveSelection(_ delta: Int) {
        let ids = navigableIDs
        guard !ids.isEmpty else { return }
        let index = ids.firstIndex(of: selectedID ?? "") ?? (delta > 0 ? -1 : 0)
        selectedID = ids[(index + delta + ids.count) % ids.count]
    }

    private func activateSelection() {
        guard let id = selectedID ?? navigableIDs.first else { return }
        if searching, matches.contains(where: { $0.id == id }) {
            dismiss(); select(id)
        } else if let action = actions.first(where: { $0.id == id && $0.enabled }) {
            dismiss(); action.perform()
        }
    }
}

#if DEBUG
// VISUAL-ONLY: stub data until host sessions populate the tab strip preview.
#Preview("Tab counts — light") {
    VStack(spacing: 12) {
        ForEach([1, 3, 20], id: \.self) { count in
            TabStripView(tabs: (1...count).map { ShellTabItem(id: "\($0)", title: "Terminal \($0)", active: $0 == 1) },
                         select: { _ in }, close: { _ in }, rename: { _, _ in }, togglePin: { _ in }, command: {})
        }
    }.frame(width: 900).padding().background(SmthzTheme.background).preferredColorScheme(.light)
}

#Preview("Create menu — dark") {
    SmthzTabCreateContent(actions: [
        TabCreateAction(id: "shell", title: "New Terminal", icon: .squareTerminal, shortcut: "⌘T", perform: {}),
        TabCreateAction(id: "browser", title: "New Browser Tab", icon: .globe, enabled: false, shortcut: "⌘⇧B", unavailableReason: "Not available yet", perform: {}),
        TabCreateAction(id: "markdown", title: "New Markdown", icon: "file-plus", enabled: false, shortcut: "⌘⇧M", unavailableReason: "Not available yet", perform: {})
    ], tabs: [], select: { _ in }, dismiss: {})
        .preferredColorScheme(.dark)
}
#endif
