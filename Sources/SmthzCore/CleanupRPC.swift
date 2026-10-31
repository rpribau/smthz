import Foundation

/// Reserved for the corresponding M4 work package. Unregistered methods return
/// unknownMethod through HostService; registering placeholders would journal reads.
public enum CleanupRPC {
    public static func register(on router: HostRouter, store: WorkspaceStore) {}
}
