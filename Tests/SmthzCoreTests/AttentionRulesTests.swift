import Testing
@testable import SmthzCore

@Test func attentionWorkingTransitions() {
    #expect(AttentionRules.transition(from: "working", to: "done") == .done)
    #expect(AttentionRules.transition(from: "working", to: "blocked") == .blocked)
}

@Test func attentionIgnoresInitialRepeatedAndOtherStates() {
    for previous in [nil, "done", "blocked", "idle", "error"] as [String?] {
        for current in ["done", "blocked"] {
            #expect(AttentionRules.transition(from: previous, to: current) == nil)
        }
    }
    #expect(AttentionRules.transition(from: "working", to: "working") == nil)
    #expect(AttentionRules.transition(from: "working", to: "error") == nil)
}

@Test func attentionDeliveryGates() {
    // Master and agent switches each silence a background completion.
    #expect(!AttentionRules.shouldNotify(enabled: false, agentTaskComplete: true,
        suppressWhenFocused: true, appIsFrontmost: false, tabIsVisible: false))
    #expect(!AttentionRules.shouldNotify(enabled: true, agentTaskComplete: false,
        suppressWhenFocused: true, appIsFrontmost: false, tabIsVisible: false))
    // A frontmost app only suppresses the pane the user can actually see.
    #expect(!AttentionRules.shouldNotify(enabled: true, agentTaskComplete: true,
        suppressWhenFocused: true, appIsFrontmost: true, tabIsVisible: true))
    #expect(AttentionRules.shouldNotify(enabled: true, agentTaskComplete: true,
        suppressWhenFocused: true, appIsFrontmost: true, tabIsVisible: false))
    #expect(AttentionRules.shouldNotify(enabled: true, agentTaskComplete: true,
        suppressWhenFocused: true, appIsFrontmost: false, tabIsVisible: true))
    #expect(AttentionRules.shouldNotify(enabled: true, agentTaskComplete: true,
        suppressWhenFocused: false, appIsFrontmost: true, tabIsVisible: true))
}

@Test func attentionBadgeCount() {
    #expect(AttentionRules.badgeLabel(unreadCount: -1) == nil)
    #expect(AttentionRules.badgeLabel(unreadCount: 0) == nil)
    #expect(AttentionRules.badgeLabel(unreadCount: 1) == "1")
    #expect(AttentionRules.badgeLabel(unreadCount: 99) == "99")
    #expect(AttentionRules.badgeLabel(unreadCount: 100) == "99+")
}
