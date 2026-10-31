import SwiftUI
import SmthzCore

/// One stable leaf. Its cached controller keeps the native SwiftTerm view and
/// scrollback alive when another pane is split or this pane is hidden.
struct TerminalPaneHost: View {
    let model: ShellController
    let pane: PaneRecord
    let tab: TerminalTabRecord
    let controller: TerminalSessionController
    let visible: Bool
    let active: Bool
    let close: () -> Void
    @State private var renaming = false
    @State private var title = ""

    var body: some View {
        TerminalSessionView(sessionID: controller.sessionID, socketPath: model.socketPath,
            fontSize: model.terminalFontSize, isActive: active, paneID: pane.id.rawValue,
            onTitleChange: { model.oscTitle(controller.sessionID, title: $0) },
            onDirectoryChange: { model.paneDirectory(pane.id, path: $0) },
            restartSession: { await model.restart(controller.sessionID) }, onClose: close,
            cachedController: controller, visible: visible,
            onFocus: { model.focus(pane.id, tab: tab.id) },
            onGrid: { cols, rows in model.paneCommand(.setPaneGrid(pane.id, cols: cols, rows: rows)) },
            onExit: { facts in
                // A6 owns automatic retirement/cold restore. Keep UI-29's restart
                // overlay available for every positively observed exit in A2.
                if exitVerdict(facts, paneCount: tab.panes.leaves.count) == .keep {
                    model.paneCommand(.processExited(pane.id, facts))
                }
            },
            onPaneAction: perform)
            .overlay {
                Rectangle().strokeBorder(active ? SmthzTheme.ring : .clear, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pane-" + pane.id.rawValue)
            .accessibilityLabel(pane.title ?? "Terminal pane")
            .accessibilityAction(named: "Focus pane") { model.focus(pane.id, tab: tab.id) }
            .accessibilityAction(named: "Split right") { perform(.splitRight) }
            .accessibilityAction(named: "Split down") { perform(.splitDown) }
            .accessibilityAction(named: "Equalize panes") { perform(.equalize) }
            .accessibilityAction(named: "Expand or collapse pane") { perform(.expand) }
            .accessibilityAction(named: "Close pane", close)
            .smthzDialog(isPresented: $renaming, title: "Set Pane Title", compact: true) {
                TextField("Pane title", text: $title).textFieldStyle(.roundedBorder).onSubmit(commitTitle)
            } footer: {
                Button("Cancel") { renaming = false }.buttonStyle(SmthzButtonStyle(.outline))
                Button("Set Title", action: commitTitle).buttonStyle(SmthzButtonStyle())
            }
    }
    private func commitTitle() { model.paneCommand(.renamePane(pane.id, title)); renaming = false }
    private func perform(_ action: SmthzTerminalContextMenu.Action) {
        model.focus(pane.id, tab: tab.id)
        switch action {
        case .splitRight: Task { await model.split(tab.id, pane: pane.id, side: .right) }
        case .splitDown: Task { await model.split(tab.id, pane: pane.id, side: .bottom) }
        case .equalize: model.paneCommand(.equalizePanes(tab.id))
        case .expand: model.paneCommand(.toggleExpandPane(tab.id, pane.id))
        case .setTitle: title = pane.title ?? ""; renaming = true
        default: break
        }
    }
}
