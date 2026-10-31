import SwiftUI

/// Confirmation before `git.discard`. Untracked files are deleted, which cannot be undone,
/// so the dialog says so and the confirm label changes to "Delete".
struct SmthzDiscardChangesDialog: View {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let paths: [String]
        let untracked: Bool
    }

    let request: Request
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var title: String {
        let what = request.paths.count == 1 ? (request.paths[0] as NSString).lastPathComponent : "\(request.paths.count) files"
        return request.untracked ? "Delete \(what)?" : "Discard changes in \(what)?"
    }

    var body: some View {
        SmthzDialog(title: title,
                    description: request.untracked
                        ? "These untracked files will be permanently deleted. This cannot be undone."
                        : "Your changes will be discarded and the files restored to their staged or committed version.",
                    compact: true, onDismiss: onCancel) {
            if request.paths.count > 1 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(request.paths, id: \.self) { path in
                            Text(path).font(SmthzFont.mono(size: 11)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .background(SmthzTheme.muted, in: RoundedRectangle(cornerRadius: 6))
            }
        } footer: {
            Button("Cancel", action: onCancel)
                .buttonStyle(SmthzButtonStyle(.outline, size: .small))
                .keyboardShortcut(.cancelAction)
                .fixedSize()
            Button(request.untracked ? "Delete" : "Discard", role: .destructive, action: onConfirm)
                .buttonStyle(SmthzDestructiveDialogButtonStyle())
                .fixedSize()
        }
    }
}

#Preview("Discard untracked") {
    SmthzDiscardChangesDialog(request: .init(paths: ["a.txt", "dir/b.txt"], untracked: true), onCancel: {}, onConfirm: {})
        .padding(40).frame(width: 520, height: 320).background(SmthzTheme.background)
}
