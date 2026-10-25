import SwiftUI

enum SmthzBulkCloseKind {
    case otherTabs, tabsToRight, tabsToLeft, allEditorTabs

    var title: String {
        switch self {
        case .otherTabs: "Close other tabs?"
        case .tabsToRight: "Close tabs to the right?"
        case .tabsToLeft: "Close tabs to the left?"
        case .allEditorTabs: "Close all editor tabs?"
        }
    }
}

struct SmthzBulkCloseDialog: View {
    var kind: SmthzBulkCloseKind = .otherTabs
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        SmthzDialog(title: kind.title,
                    description: "The selected tabs will be closed. Pinned tabs will stay open.",
                    compact: true, onDismiss: onCancel) {
            EmptyView()
        } footer: {
            Button("Cancel", action: onCancel)
                .buttonStyle(SmthzButtonStyle(.outline, size: .small))
                .keyboardShortcut(.cancelAction)
            Button("Close tabs", role: .destructive, action: onConfirm)
                .buttonStyle(SmthzDestructiveDialogButtonStyle())
        }
    }
}

#Preview("Bulk close") {
    SmthzBulkCloseDialog(onCancel: {}, onConfirm: {})
        .padding(40).frame(width: 600, height: 320).background(SmthzTheme.background)
}
