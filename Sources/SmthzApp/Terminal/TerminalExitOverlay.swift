import SwiftUI
import SmthzCore

struct SmthzTerminalExitOverlay: View {
    let exit: HostSessionExit
    let restarting: Bool
    let error: String?
    let close: (() -> Void)?
    let restart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Terminal exited").font(SmthzFont.ui(size: 14, weight: .semibold))
            Text(message).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
            if let error {
                Text(error).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.destructive)
            }
            HStack(spacing: 8) {
                Spacer()
                Button { close?() } label: {
                    Label { Text("Close") } icon: { SmthzIcon.image("x").frame(width: 14, height: 14) }
                }
                .buttonStyle(SmthzButtonStyle(.secondary, size: .xs))
                .disabled(close == nil || restarting)
                Button(action: restart) {
                    Label { Text(restarting ? "Restarting…" : "Restart") } icon: {
                        SmthzIcon.image("rotate-cw").frame(width: 14, height: 14)
                    }
                }
                .buttonStyle(SmthzButtonStyle(.primary, size: .xs))
                .disabled(restarting)
            }
        }
        .foregroundStyle(SmthzTheme.foreground)
        .padding(16)
        .frame(maxWidth: 390)
        .background(SmthzTheme.popover, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(SmthzTheme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
        .padding(24)
    }

    private var message: String {
        if let code = exit.code {
            return "The shell process ended with exit code \(code). Its output is preserved."
        }
        if let signal = exit.signal {
            return "The shell process ended with signal \(signal). Its output is preserved."
        }
        return "The shell process ended. Its output is preserved."
    }
}
