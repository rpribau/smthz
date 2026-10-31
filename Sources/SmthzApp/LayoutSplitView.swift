import AppKit
import SwiftUI
import SmthzCore

/// The cache owns emulators, not the recursive layout. A split, move, expansion,
/// or tab switch only changes frames; an existing PaneID retains its emulator.
@MainActor
final class TerminalPaneCache {
    private var controllers: [PaneID: TerminalSessionController] = [:]
    func controller(for pane: PaneRecord, model: ShellController) -> TerminalSessionController? {
        guard let session = pane.binding?.sessionID else { return nil }
        if let existing = controllers[pane.id], existing.sessionID == session { return existing }
        controllers.removeValue(forKey: pane.id)?.stop()
        let controller = TerminalSessionController(sessionID: session, socketPath: model.socketPath,
            fontSize: model.terminalFontSize, initialGrid: pane.lastGrid)
        controllers[pane.id] = controller
        return controller
    }
    func retain(_ panes: Set<PaneID>) {
        for id in Array(controllers.keys) where !panes.contains(id) {
            controllers.removeValue(forKey: id)?.stop()
        }
    }
    func pause() { for controller in controllers.values { controller.pause() } }
    deinit {
        let remaining = controllers
        Task { @MainActor in for controller in remaining.values { controller.stop() } }
    }
}

struct LayoutSplitView: View {
    let model: ShellController
    let close: (PaneID, TabID) -> Void
    @State private var cache = TerminalPaneCache()
    private let divider: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let groups = model.workspace.groupLayout
            let groupFrames = groups?.frames(in: bounds, divider: divider) ?? [:]
            let placements = paneFrames(groupFrames)
            ZStack(alignment: .topLeading) {
                ForEach(model.workspace.panes.values.sorted { $0.id.rawValue < $1.id.rawValue }, id: \.id) { pane in
                    if let tab = model.workspace.tabs.values.first(where: { $0.panes.contains(pane.id) }),
                       let controller = cache.controller(for: pane, model: model) {
                        let frame = placements[pane.id]
                        TerminalPaneHost(model: model, pane: pane, tab: tab, controller: controller,
                            visible: frame != nil, active: frame != nil && model.activeTab?.id == tab.id && tab.activePane == pane.id,
                            close: { close(pane.id, tab.id) })
                            .frame(width: max(1, frame?.width ?? 640), height: max(1, frame?.height ?? 400))
                            .position(x: frame?.midX ?? -1000, y: frame?.midY ?? -1000)
                            .opacity(frame == nil ? 0 : 1).allowsHitTesting(frame != nil)
                            .accessibilityHidden(frame == nil)
                    }
                }
                if let groups {
                    dividers(groups, bounds: bounds, prefix: "group") { path, ratio in
                        model.paneCommand(.setGroupRatio(.home, path: path, ratio: ratio))
                    } equalize: {
                        // Group equalization uses the same tested tree operation.
                        for item in groups.equalized().dividers(in: bounds, divider: divider) {
                            let location = CGPoint(x: item.frame.midX, y: item.frame.midY)
                            model.paneCommand(.setGroupRatio(.home, path: item.path,
                                ratio: groups.equalized().ratio(forDividerAt: item.path, dragLocation: location,
                                    in: bounds, divider: divider, minimum: .zero)))
                        }
                    }
                }
                ForEach(visibleTabs, id: \.id) { tab in
                    if tab.expandedPane == nil, let group = groupFor(tab.id), let frame = groupFrames[group] {
                        dividers(tab.panes, bounds: frame, prefix: tab.id.rawValue) { path, ratio in
                            model.paneCommand(.setPaneRatio(tab.id, path: path, ratio: ratio))
                        } equalize: { model.paneCommand(.equalizePanes(tab.id)) }
                    }
                }
            }
            .coordinateSpace(name: "pane-layout")
            .clipped()
        }
        .onChange(of: Set(model.workspace.panes.keys), initial: true) { _, ids in cache.retain(ids) }
        .onDisappear { cache.pause() }
        .background(PaneShortcutMonitor(model: model, close: close))
    }

    private var visibleTabs: [TerminalTabRecord] {
        model.workspace.groups.values.compactMap { $0.activeTab.flatMap { model.workspace.tabs[$0] } }
    }
    private func groupFor(_ tab: TabID) -> GroupID? {
        model.workspace.groups.values.first { $0.activeTab == tab }?.id
    }
    private func paneFrames(_ groups: [GroupID: CGRect]) -> [PaneID: CGRect] {
        var frames: [PaneID: CGRect] = [:]
        for tab in visibleTabs {
            guard let group = groupFor(tab.id), let frame = groups[group] else { continue }
            if let expanded = tab.expandedPane { frames[expanded] = frame }
            else { frames.merge(tab.panes.frames(in: frame, divider: divider)) { _, new in new } }
        }
        return frames
    }
    private func dividers<L>(_ tree: LayoutNode<L>, bounds: CGRect, prefix: String,
                            set: @escaping ([SplitBranch], Double) -> Void,
                            equalize: @escaping () -> Void) -> some View {
        ForEach(Array(tree.dividers(in: bounds, divider: divider).enumerated()), id: \.offset) { _, item in
            Rectangle().fill(SmthzTheme.border)
                .frame(width: item.frame.width, height: item.frame.height)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { (item.axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                    else { NSCursor.pop() }
                }
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("pane-layout"))
                    .onChanged { value in
                        set(item.path, tree.ratio(forDividerAt: item.path, dragLocation: value.location,
                            in: bounds, divider: divider, minimum: CGSize(width: 80, height: 48)))
                    }.onEnded { _ in model.flush() })
                .onTapGesture(count: 2, perform: equalize)
                .accessibilityElement()
                .accessibilityLabel("Resize panes")
                .accessibilityIdentifier("divider-" + prefix + "-" + item.path.map(\.rawValue).joined(separator: "-"))
                .accessibilityAdjustableAction { direction in
                    let delta = direction == .increment ? 20.0 : -20.0
                    let point = CGPoint(x: item.frame.midX + (item.axis == .horizontal ? delta : 0),
                                        y: item.frame.midY + (item.axis == .vertical ? delta : 0))
                    set(item.path, tree.ratio(forDividerAt: item.path, dragLocation: point,
                        in: bounds, divider: divider, minimum: CGSize(width: 80, height: 48)))
                }
                .position(x: item.frame.midX, y: item.frame.midY)
        }
    }
}

/// Pane chords are window scoped and run before ordinary terminal input.
private struct PaneShortcutMonitor: NSViewRepresentable {
    let model: ShellController
    let close: (PaneID, TabID) -> Void
    func makeNSView(context: Context) -> Monitor { Monitor() }
    func updateNSView(_ view: Monitor, context: Context) {
        view.perform = { event in
            guard let tab = model.activeTab else { return false }
            let bindings = SmthzKeybindings.shared
            if bindings.matches(event, action: .terminalSplitRight) { Task { await model.split(tab.id, pane: tab.activePane, side: .right) }; return true }
            if bindings.matches(event, action: .terminalSplitDown) { Task { await model.split(tab.id, pane: tab.activePane, side: .bottom) }; return true }
            if bindings.matches(event, action: .terminalFocusPreviousPane) { model.paneCommand(.focusPreviousPane(tab.id)); return true }
            if bindings.matches(event, action: .terminalFocusNextPane) { model.paneCommand(.focusNextPane(tab.id)); return true }
            if bindings.matches(event, action: .terminalClosePane) { close(tab.activePane, tab.id); return true }
            if bindings.matches(event, action: .terminalExpandPane) { model.paneCommand(.toggleExpandPane(tab.id, tab.activePane)); return true }
            return false
        }
    }
    static func dismantleNSView(_ view: Monitor, coordinator: ()) { view.stop() }
    final class Monitor: NSView {
        var perform: (NSEvent) -> Bool = { _ in false }
        private var token: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, event.window === self.window, self.window?.isKeyWindow == true else { return false }
                    // Text fields keep their editing chords while a dialog is open.
                    if self.window?.firstResponder is NSTextView { return false }
                    return self.perform(event)
                }
                return handled ? nil : event
            }
        }
        func stop() { if let token { NSEvent.removeMonitor(token) }; token = nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
