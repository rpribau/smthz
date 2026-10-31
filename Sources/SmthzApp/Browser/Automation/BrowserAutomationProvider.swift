import Foundation
import SmthzCore

/// Registers the app with smthzd as the browser provider (A.6) and keeps it registered while the app runs:
/// a dedicated thread blocks on the host's command stream, every command runs concurrently on the main
/// actor (so `dialog accept` can answer while an `eval` waits on an alert), and replies are serialized.
final class BrowserAutomationProvider: @unchecked Sendable {
    static let shared = BrowserAutomationProvider()
    private let replies = DispatchQueue(label: "dev.smthz.browser-provider.replies")
    private var started = false

    @MainActor func start() {
        guard !started else { return }
        started = true
        let socketPath = HostController.socketPath
        let thread = Thread { [self] in serve(socketPath: socketPath) }
        thread.name = "smthz browser provider"
        thread.start()
    }

    private func serve(socketPath: String) {
        while true {
            // Host down, restarting, or another provider registered: retry quietly.
            let client = try? HostClient(socketPath: socketPath)
            let registered = try? client?.registerBrowserProvider()
            client?.disconnect()
            guard let registered else {
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            // Replies are serialized on `replies`; receive stays on this thread (HostBrowserProvider contract).
            nonisolated(unsafe) let provider = registered
            while let command = try? provider.receive() {
                Task { @MainActor in
                    let outcome: Result<BrowserResult, HostRPCError>
                    do { outcome = .success(try await BrowserAutomation.shared.run(command.request)) }
                    catch let error as HostRPCError { outcome = .failure(error) }
                    catch { outcome = .failure(HostRPCError("browserError", detail: "\(error)")) }
                    self.replies.async {
                        switch outcome {
                        case .success(let result): try? provider.reply(to: command, result: result)
                        case .failure(let error): try? provider.reply(to: command, error: error)
                        }
                    }
                }
            }
            provider.disconnect()
            Thread.sleep(forTimeInterval: 1)
        }
    }
}
