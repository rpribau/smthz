import Foundation
import Observation

struct SmthzQuickCommand: Identifiable, Codable, Equatable {
    enum Scope: String, Codable, CaseIterable {
        case global = "Global"
        case project = "Project"
    }

    var id = UUID()
    var label = ""
    var command = ""
    var appendEnter = true
    var scope: Scope = .global
    // Project scope is the Default workspace until the M4 project model exists.
    var projectID = "Default workspace"

    var terminalInput: String { command + (appendEnter ? "\r" : "") }
    var isValid: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Shared by the menu and the window-level `.smthzQuickCommandDialogs(store:)`.
/// Inject an isolated UserDefaults suite for previews/checks; production uses standard defaults.
@MainActor @Observable
final class SmthzQuickCommandStore {
    static let shared = SmthzQuickCommandStore()
    private(set) var commands: [SmthzQuickCommand]
    var editor: SmthzQuickCommand?
    var pendingDeletion: SmthzQuickCommand?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "quickCommands.saved.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        commands = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([SmthzQuickCommand].self, from: $0) } ?? []
    }

    func save(_ command: SmthzQuickCommand) {
        guard command.isValid else { return }
        var saved = command
        saved.label = saved.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = commands.firstIndex(where: { $0.id == saved.id }) {
            commands[index] = saved
        } else {
            commands.append(saved)
        }
        persist()
        editor = nil
    }

    func delete(_ command: SmthzQuickCommand) {
        commands.removeAll { $0.id == command.id }
        persist()
        pendingDeletion = nil
    }

    func visibleCommands(projectID: String) -> [SmthzQuickCommand] {
        commands.filter { $0.scope == .global || $0.projectID == projectID }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        defaults.set(data, forKey: key)
    }
}
