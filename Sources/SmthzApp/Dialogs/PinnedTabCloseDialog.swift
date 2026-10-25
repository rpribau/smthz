import SwiftUI

struct SmthzPinnedTabCloseDialog: View {
    var tabLabel: String? = nil
    let onCancel: () -> Void
    let onConfirm: (Bool) -> Void
    @State private var dontAskAgain = false

    var body: some View {
        SmthzDialog(title: "Close pinned tab?",
                    description: "This tab is pinned. Are you sure you want to close it?",
                    compact: true, onDismiss: onCancel) {
            SmthzCloseTabLabel(label: tabLabel)
            SmthzConfirmationCheckbox(title: "Don't ask again for pinned tabs", isOn: $dontAskAgain)
        } footer: {
            Button("Cancel", action: onCancel)
                .buttonStyle(SmthzButtonStyle(.outline, size: .small))
                .keyboardShortcut(.cancelAction)
            Button("Close", role: .destructive) { onConfirm(dontAskAgain) }
                .buttonStyle(SmthzDestructiveDialogButtonStyle())
        }
    }
}

#Preview("Pinned tab") {
    SmthzPinnedTabCloseDialog(tabLabel: "Shell 1", onCancel: {}, onConfirm: { _ in })
        .padding(40).frame(width: 600, height: 360).background(SmthzTheme.background)
}
