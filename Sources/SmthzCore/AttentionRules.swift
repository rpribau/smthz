/// Desktop delivery policy is independent of attention history and unread state.
public enum AttentionRules {
    public enum Event: String, Codable, Sendable { case done, blocked }

    public static func transition(from previous: String?, to current: String) -> Event? {
        guard previous == "working" else { return nil }
        return Event(rawValue: current)
    }

    public static func shouldNotify(enabled: Bool, agentTaskComplete: Bool,
                                    suppressWhenFocused: Bool, appIsFrontmost: Bool,
                                    tabIsVisible: Bool) -> Bool {
        enabled && agentTaskComplete && !(suppressWhenFocused && appIsFrontmost && tabIsVisible)
    }

    public static func badgeLabel(unreadCount: Int) -> String? {
        unreadCount <= 0 ? nil : unreadCount > 99 ? "99+" : String(unreadCount)
    }
}
