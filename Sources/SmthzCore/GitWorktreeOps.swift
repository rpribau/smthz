import Foundation

public extension GitService {
    /// Synchronous bridge for the host's dedicated request/job threads.
    func worktreeGit(_ arguments: [String], at path: String, context: HostJobContext? = nil,
                     allowFailure: Bool = false) throws -> Output {
        try RepoRPC.runGit(self, arguments, at: path, mode: .userContext,
            control: context?.processControl ?? GitProcessControl(),
            stderr: { context?.event("log", $0) },
            progress: { context?.event("progress", $0.phase, done: $0.done, total: $0.total) },
            allowFailure: allowFailure)
    }
}
