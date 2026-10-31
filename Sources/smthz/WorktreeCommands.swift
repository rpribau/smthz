import SmthzCore

/// Filled by WP-M4-WORKTREE-HOST.
enum WorktreeCommands {
    static func run(flags: CLIFlags, client: HostClient) throws -> [String: HostJSON] {
        throw HostRPCError("unknownMethod")
    }
}
