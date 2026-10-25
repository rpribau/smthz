import Foundation
import CoreGraphics
import Testing
@testable import SmthzCore

private struct StoreIDs: ShellIDSource {
    var n = 0
    mutating func next() -> String { n += 1; return "store-\(n)" }
}
private struct StoreFixture {
    let directory: URL
    var url: URL { directory.appendingPathComponent("shell-state.json") }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("smthz-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func write(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }
    func object(_ state: ShellState) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    }
}
private func storeState() throws -> ShellState {
    var state = ShellState.empty, ids = StoreIDs()
    for _ in 0..<3 {
        state = try state.applying(.createTab(.home, group: nil, cwd: "/tmp", title: nil),
                                   now: Date(timeIntervalSince1970: 100), ids: &ids).get().state
    }
    return state
}
/// Mutate one of the alternating key/value workspace records in Codable's dictionary representation.
private func mutateHome(_ object: inout [String: Any], _ edit: (inout [String: Any]) -> Void) throws {
    var pairs = try #require(object["workspaces"] as? [Any])
    let index = try #require(pairs.indices.first { pairs[$0] as? String == "home" })
    var workspace = try #require(pairs[index + 1] as? [String: Any])
    edit(&workspace)
    pairs[index + 1] = workspace
    object["workspaces"] = pairs
}

@Test func storeRoundTripTwoHundredSeededCommands() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    var state = ShellState.empty, ids = StoreIDs(), seed: UInt64 = 12345
    for step in 0..<200 {
        seed = seed &* 6364136223846793005 &+ 1
        let tabs = state.workspaces[.home]!.tabs.keys.sorted { $0.rawValue < $1.rawValue }
        let tab = tabs.isEmpty ? nil : tabs[Int(seed % UInt64(tabs.count))]
        let command: ShellCommand
        switch (seed >> 32) % 7 {
        case 0: command = .createTab(.home, group: nil, cwd: "/tmp/\(step)", title: nil)
        case 1: command = tab.map { .renameTab($0, "Title \(step)") } ?? .nextTab(.home)
        case 2: command = tab.map { .setTabColor($0, .purple) } ?? .nextTab(.home)
        case 3: command = tab.map { .setPinned($0, true) } ?? .previousTab(.home)
        case 4: command = tab.map { .activateTab($0) } ?? .previousTab(.home)
        case 5: command = tab.map { .closeTab($0, force: true) } ?? .nextTab(.home)
        default: command = .reopenClosedTab(.home)
        }
        if case .success(let applied) = state.applying(command, now: Date(timeIntervalSince1970: Double(step)), ids: &ids) {
            state = applied.state
        }
    }
    state.windows = [.init(id: .init(rawValue: "window"), workspace: .home,
                           frame: .init(x: 50, y: 50, width: 900, height: 600))]
    #expect(state.violations().isEmpty)
    try ShellStateStore.save(state, to: fixture.url)
    let (loaded, report) = ShellStateStore.load(from: fixture.url)
    #expect(loaded == state)
    #expect(report == ShellLoadReport())
}
@Test func storePrivatePermissionsAndAtomicReplacement() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    try Data("old".utf8).write(to: fixture.url)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.url.path)
    try ShellStateStore.save(try storeState(), to: fixture.url)
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["shell-state.json"])
}
@Test func storePartialTemporaryFileCannotReplaceCommittedState() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    let state = try storeState()
    try ShellStateStore.save(state, to: fixture.url)
    let partial = fixture.directory.appendingPathComponent(".shell-state.json.tmp-crash")
    try Data("{\"version\":".utf8).write(to: partial)
    #expect(ShellStateStore.load(from: fixture.url).0 == state)
    try ShellStateStore.save(.empty, to: fixture.url)
    #expect(ShellStateStore.load(from: fixture.url).0 == .empty)
    #expect(FileManager.default.fileExists(atPath: partial.path))
}
@Test func storeCorruptJSONIsBackedUpVerbatim() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    let bytes = Data("{broken".utf8)
    try bytes.write(to: fixture.url)
    let (loaded, report) = ShellStateStore.load(from: fixture.url)
    #expect(loaded == .empty)
    let path = try #require(report.backupPath)
    #expect(path.contains("shell-state.json.corrupt-"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
    #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
}
@Test func storeFutureVersionBackedUpBeforeRecordDecoding() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    try fixture.write(["version": ShellStateStore.currentVersion + 1, "unknown": "future schema"])
    let bytes = try Data(contentsOf: fixture.url)
    let (loaded, report) = ShellStateStore.load(from: fixture.url)
    #expect(loaded == .empty)
    let path = try #require(report.backupPath)
    #expect(path.contains(".future-"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
}
@Test func storeSalvagesMalformedTabAndKeepsSiblings() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    var object = try fixture.object(try storeState()), dropped = ""
    try mutateHome(&object) { workspace in
        var tabs = workspace["tabs"] as! [Any]
        dropped = tabs[0] as! String
        tabs[1] = ["id": dropped, "kind": "unsupported"]
        workspace["tabs"] = tabs
    }
    try fixture.write(object)
    let (loaded, report) = ShellStateStore.load(from: fixture.url)
    #expect(loaded.workspaces[.home]?.tabs.count == 2)
    #expect(loaded.workspaces[.home]?.tabs[TabID(rawValue: dropped)] == nil)
    #expect(loaded.violations().isEmpty)
    #expect(report.salvaged.contains { $0.contains(dropped) })
    #expect(report.backupPath == nil)
}
@Test func storeRepairsDanglingActiveTab() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    var state = try storeState()
    let group = try #require(state.workspaces[.home]?.activeGroup)
    state.workspaces[.home]!.groups[group]!.activeTab = TabID(rawValue: "missing")
    try ShellStateStore.save(state, to: fixture.url)
    let (loaded, report) = ShellStateStore.load(from: fixture.url)
    #expect(loaded.violations().isEmpty)
    #expect(loaded.workspaces[.home]?.groups[group]?.activeTab != TabID(rawValue: "missing"))
    #expect(report.salvaged.contains { $0.contains("dangling active tab") })
}
@Test func storeBadPaneAndWorkspaceAreDroppedIndividually() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    var object = try fixture.object(try storeState())
    try mutateHome(&object) { workspace in
        var panes = workspace["panes"] as! [Any]
        panes[1] = "bad pane"
        workspace["panes"] = panes
    }
    var workspaces = object["workspaces"] as! [Any]
    workspaces += ["folder:/broken", ["key": "folder:/broken", "displayName": 42]]
    object["workspaces"] = workspaces
    try fixture.write(object)
    let (loaded, report) = ShellStateStore.load(from: fixture.url)
    #expect(loaded.workspaces.count == 1)
    #expect(loaded.workspaces[.home]?.tabs.count == 2)
    #expect(loaded.violations().isEmpty)
    #expect(report.salvaged.contains { $0.contains("folder:/broken") })
    #expect(report.salvaged.contains { $0.contains("panes") })
}
@Test func storeMissingFileAndEmptyRoundTrip() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    #expect(ShellStateStore.load(from: fixture.url).0 == .empty)
    #expect(ShellStateStore.load(from: fixture.url).1 == ShellLoadReport())
    try ShellStateStore.save(.empty, to: fixture.url)
    #expect(ShellStateStore.load(from: fixture.url).0 == .empty)
    #expect(ShellStateStore.load(from: fixture.url).1 == ShellLoadReport())
}
@Test func storePersistsBindingAndPendingRequestWithoutStartingShell() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    var state = try storeState()
    let pane = try #require(state.workspaces[.home]?.panes.keys.first)
    let host = ProcessIdentity(pid: 123, startSeconds: 456, startMicroseconds: 7)
    state.workspaces[.home]!.panes[pane]!.pendingCreateRequestID = RequestID.generate()
    state.workspaces[.home]!.panes[pane]!.binding = .init(hostIncarnation: host, sessionID: "same-session", process: host)
    state.workspaces[.home]!.panes[pane]!.state = .live
    try ShellStateStore.save(state, to: fixture.url)
    #expect(ShellStateStore.load(from: fixture.url).0 == state)
}
@Test func storeFailedSaveKeepsOldStateAndCleansTemporaryFile() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    let state = try storeState()
    try ShellStateStore.save(state, to: fixture.url)
    var invalid = state
    invalid.windows = [.init(id: .init(rawValue: "bad"), workspace: .home, sidebarWidth: .nan)]
    #expect(throws: (any Error).self) { try ShellStateStore.save(invalid, to: fixture.url) }
    #expect(ShellStateStore.load(from: fixture.url).0 == state)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["shell-state.json"])
}
@Test func storeFrameValidationVisibleAndDisconnectedScreens() {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    let frame = CGRect(x: 1600, y: 100, width: 800, height: 600)
    #expect(FrameValidation.isUsable(frame, screens: [main, secondary]))
    #expect(!FrameValidation.isUsable(frame, screens: [main]))
    #expect(!FrameValidation.isUsable(main, screens: []))
    #expect(FrameValidation.isUsable(CGRect(x: -700, y: -550, width: 800, height: 600), screens: [main]))
    #expect(!FrameValidation.isUsable(CGRect(x: -701, y: -550, width: 800, height: 600), screens: [main]))
    #expect(!FrameValidation.isUsable(CGRect(x: -700, y: -551, width: 800, height: 600), screens: [main]))
}
@Test func storeFrameValidationRejectsInvalidGeometryAndHonorsCustomMinimum() {
    let screen = CGRect(x: -1440, y: -900, width: 1440, height: 900)
    #expect(FrameValidation.isUsable(CGRect(x: -500, y: -500, width: 400, height: 300), screens: [screen]))
    for frame in [CGRect.null, .infinite, .zero, CGRect(x: 0, y: 0, width: -10, height: 100),
                  CGRect(x: Double.nan, y: 0, width: 100, height: 100)] {
        #expect(!FrameValidation.isUsable(frame, screens: [screen]))
    }
    #expect(!FrameValidation.isUsable(screen, screens: [screen], minimumVisible: .init(width: 1500, height: 50)))
    #expect(!FrameValidation.isUsable(screen, screens: [screen], minimumVisible: .zero))
}

@Test func storeRoundTripSplitGroupsAndPaneMetadata() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    var state = try storeState(), ids = StoreIDs(n: 1000)
    let tab = try #require(state.workspaces[.home]?.tabs.keys.sorted { $0.rawValue < $1.rawValue }.first)
    let pane = try #require(state.workspaces[.home]?.tabs[tab]?.activePane)
    for command: ShellCommand in [.splitPane(tab, pane: pane, side: .right),
                                 .renamePane(pane, "Build"), .setPaneGrid(pane, cols: 132, rows: 48),
                                 .setPaneRatio(tab, path: [], ratio: 0.3),
                                 .toggleExpandPane(tab, pane), .moveTabToSplit(tab, side: .bottom)] {
        state = try state.applying(command, ids: &ids).get().state
    }
    state.lastVisited[.home] = Date(timeIntervalSince1970: 12345)
    state.windows = [.init(id: .init(rawValue: "one"), workspace: .home, sidebarVisible: false,
                           sidebarWidth: 280, destination: .activity),
                     .init(id: .init(rawValue: "two"), workspace: .home)]
    try ShellStateStore.save(state, to: fixture.url)
    let (loaded, report) = ShellStateStore.load(from: fixture.url)
    #expect(loaded == state)
    #expect(report == ShellLoadReport())
}
@Test func storeRenameFailureRemovesItsTemporaryFile() throws {
    let fixture = try StoreFixture(); defer { fixture.cleanup() }
    try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try ShellStateStore.save(.empty, to: fixture.url) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["shell-state.json"])
}
