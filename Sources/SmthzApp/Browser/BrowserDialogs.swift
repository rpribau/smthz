import SwiftUI

/// A page-initiated sheet (alert/confirm/prompt) or an HTTP auth challenge.
/// WebKit's async delegate waits until the sheet resumes it; closing the tab cancels.
enum BrowserDialogRequest {
    case alert(origin: String, message: String, resume: (Void?) -> Void)
    case confirm(origin: String, message: String, resume: (Bool?) -> Void)
    case prompt(origin: String, message: String, defaultText: String, resume: (String?) -> Void)
    case auth(origin: String, realm: String?, resume: ((String, String)?) -> Void)

    func cancel() {
        switch self {
        case .alert(_, _, let resume): resume(nil)
        case .confirm(_, _, let resume): resume(nil)
        case .prompt(_, _, _, let resume): resume(nil)
        case .auth(_, _, let resume): resume(nil)
        }
    }

    /// Shows one dialog at a time per tab; a second page dialog while one is open is dismissed.
    @MainActor static func present<T: Sendable>(on tab: BrowserTab,
                                      _ make: (@escaping (T?) -> Void) -> BrowserDialogRequest) async -> T? {
        guard tab.dialog == nil else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            var resumed = false
            tab.dialog = make { [weak tab] value in
                guard !resumed else { return }
                resumed = true
                tab?.dialog = nil
                continuation.resume(returning: value)
            }
        }
    }
}

/// Sheets for `BrowserTab.dialog`, styled like the shell's other dialogs.
struct BrowserDialogsModifier: ViewModifier {
    let tab: BrowserTab
    @State private var text = ""
    @State private var user = ""
    @State private var password = ""

    func body(content: Content) -> some View {
        content.smthzDialog(isPresented: presented, title: title, description: description, compact: true) {
            fields
        } footer: {
            buttons
        }
        .onChange(of: dialogKey, initial: true) { _, _ in
            if case .prompt(_, _, let defaultText, _) = tab.dialog { text = defaultText }
            if case .auth = tab.dialog { user = ""; password = "" }
        }
    }

    private var presented: Binding<Bool> {
        Binding(get: { tab.dialog != nil }, set: { if !$0 { tab.dialog?.cancel() } })
    }
    private var dialogKey: String {
        switch tab.dialog {
        case .alert(let origin, let message, _): "alert|\(origin)|\(message)"
        case .confirm(let origin, let message, _): "confirm|\(origin)|\(message)"
        case .prompt(let origin, let message, _, _): "prompt|\(origin)|\(message)"
        case .auth(let origin, let realm, _): "auth|\(origin)|\(realm ?? "")"
        case nil: ""
        }
    }
    private var title: String {
        switch tab.dialog {
        case .auth: "Sign in"
        case .alert(let origin, _, _), .confirm(let origin, _, _), .prompt(let origin, _, _, _):
            origin.isEmpty ? "This page says" : "\(origin) says"
        case nil: ""
        }
    }
    private var description: String? {
        switch tab.dialog {
        case .alert(_, let message, _), .confirm(_, let message, _), .prompt(_, let message, _, _): message
        case .auth(let origin, let realm, _):
            realm.map { "\(origin) requires a username and password. The site says: \u{201C}\($0)\u{201D}" }
                ?? "\(origin) requires a username and password."
        case nil: nil
        }
    }

    @ViewBuilder private var fields: some View {
        switch tab.dialog {
        case .prompt:
            TextField("", text: $text).textFieldStyle(.roundedBorder).onSubmit(accept)
                .accessibilityLabel("Prompt response")
        case .auth:
            VStack(spacing: 8) {
                TextField("Username", text: $user).textFieldStyle(.roundedBorder).textContentType(.username)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder).onSubmit(accept)
            }
        default: EmptyView()
        }
    }

    @ViewBuilder private var buttons: some View {
        switch tab.dialog {
        case .alert:
            Button("OK", action: accept).buttonStyle(SmthzButtonStyle()).keyboardShortcut(.defaultAction)
        case .confirm, .prompt, .auth:
            Button("Cancel") { tab.dialog?.cancel() }.buttonStyle(SmthzButtonStyle(.outline))
                .keyboardShortcut(.cancelAction)
            Button(isAuth ? "Sign In" : "OK", action: accept).buttonStyle(SmthzButtonStyle())
                .keyboardShortcut(.defaultAction)
        case nil: EmptyView()
        }
    }
    private var isAuth: Bool { if case .auth = tab.dialog { true } else { false } }

    private func accept() {
        switch tab.dialog {
        case .alert(_, _, let resume): resume(())
        case .confirm(_, _, let resume): resume(true)
        case .prompt(_, _, _, let resume): resume(text)
        case .auth(_, _, let resume): resume((user, password))
        case nil: break
        }
    }
}
