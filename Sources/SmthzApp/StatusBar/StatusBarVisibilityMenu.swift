import SwiftUI

/// Which optional status bar segments are shown (UI-DETAIL §6 right-click menu).
/// Persisted in `UserDefaults`; the host segment is always visible (D-STATUS).
@MainActor @Observable
final class StatusBarVisibility {
    private enum Key {
        static let resourceManager = "statusBar.showResourceManager"
        static let ports = "statusBar.showPorts"
        static let remoteHosts = "statusBar.showRemoteHosts"
    }

    private let defaults: UserDefaults

    var showResourceManager: Bool { didSet { defaults.set(showResourceManager, forKey: Key.resourceManager) } }
    var showPorts: Bool { didSet { defaults.set(showPorts, forKey: Key.ports) } }
    var showRemoteHosts: Bool { didSet { defaults.set(showRemoteHosts, forKey: Key.remoteHosts) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Resource Manager defaults on; Ports and Remote Hosts are VISUAL-ONLY and default off.
        showResourceManager = defaults.object(forKey: Key.resourceManager) as? Bool ?? true
        showPorts = defaults.object(forKey: Key.ports) as? Bool ?? false
        showRemoteHosts = defaults.object(forKey: Key.remoteHosts) as? Bool ?? false
    }
}

/// Context-menu content with the checkbox rows Orca shows that smthz can honour.
/// Provider usage rows are omitted: there is no accounts backend (UI-GAP2 "decide" list).
struct StatusBarVisibilityMenu: View {
    @Bindable var visibility: StatusBarVisibility

    var body: some View {
        Toggle("Remote Hosts", isOn: $visibility.showRemoteHosts)
        Toggle("Resource Manager", isOn: $visibility.showResourceManager)
        Toggle("Ports", isOn: $visibility.showPorts)
    }
}
