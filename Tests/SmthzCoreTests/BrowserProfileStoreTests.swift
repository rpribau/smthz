import Foundation
import Testing
@testable import SmthzCore

private struct ProfileFixture {
    let directory: URL
    var file: URL { directory.appendingPathComponent(BrowserProfileStore.fileName) }
    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("smthz-bps-\(UUID().uuidString.prefix(8))")
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func store() -> BrowserProfileStore {
        BrowserProfileStore(stateDirectory: directory, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }
}

@Test func freshStoreHasBuiltInDefaultPersistedAs0600() throws {
    let fixture = ProfileFixture()
    defer { fixture.cleanup() }
    let store = fixture.store()
    #expect(store.profiles.map(\.id) == [BrowserProfileStore.builtInID])
    #expect(store.defaultProfile.scope == .default && store.defaultProfile.label == "Default")
    let mode = try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    // The built-in data store identifier is stable across launches.
    #expect(fixture.store().defaultProfile.dataStoreIdentifier == store.defaultProfile.dataStoreIdentifier)
}

@Test func createRenameSourceAndDefaultSurviveReload() throws {
    let fixture = ProfileFixture()
    defer { fixture.cleanup() }
    let store = fixture.store()
    let work = try store.create(label: "  Work  ")
    let imported = try store.create(label: "From Chrome", scope: .imported)
    #expect(work.label == "Work" && work.scope == .isolated)
    #expect(work.dataStoreIdentifier != imported.dataStoreIdentifier)
    try store.rename(id: work.id, label: "Client")
    let source = BrowserProfileSourceInfo(browser: .chrome, profileName: "Personal",
                                          importedAt: Date(timeIntervalSince1970: 1_800_000_100))
    try store.updateSource(id: imported.id, source: source)
    try store.setDefault(id: work.id)

    let reloaded = fixture.store()
    #expect(reloaded.loadReport.isEmpty)
    #expect(reloaded.profiles.map(\.label) == ["Default", "Client", "From Chrome"])
    #expect(reloaded.profile(id: imported.id)?.source == source)
    #expect(reloaded.defaultProfile.id == work.id)
    #expect(reloaded.profile(id: work.id)?.dataStoreIdentifier == work.dataStoreIdentifier)
    try reloaded.resetDefault()
    #expect(reloaded.defaultProfile.id == BrowserProfileStore.builtInID)
}

@Test func invalidInputsAreRejected() throws {
    let fixture = ProfileFixture()
    defer { fixture.cleanup() }
    let store = fixture.store()
    #expect(throws: BrowserProfileStoreError.invalidLabel) { try store.create(label: "   ") }
    #expect(throws: BrowserProfileStoreError.invalidScope) { try store.create(label: "x", scope: .default) }
    #expect(throws: BrowserProfileStoreError.notFound("nope")) { try store.setDefault(id: "nope") }
    #expect(throws: BrowserProfileStoreError.builtInProfile) { try store.delete(id: BrowserProfileStore.builtInID) }
    #expect(throws: BrowserProfileStoreError.notFound("nope")) { try store.attach(id: "nope") }
}

@Test func deleteWithoutViewsRemovesAndQueuesDataStore() throws {
    let fixture = ProfileFixture()
    defer { fixture.cleanup() }
    let store = fixture.store()
    let profile = try store.create(label: "Temp")
    try store.setDefault(id: profile.id)
    #expect(try store.delete(id: profile.id) == .removed(dataStoreIdentifier: profile.dataStoreIdentifier))
    #expect(store.profile(id: profile.id) == nil)
    #expect(store.defaultProfile.id == BrowserProfileStore.builtInID)
    #expect(store.pendingDataStoreRemovals == [profile.dataStoreIdentifier])
    // Unconfirmed removals survive a restart until the app confirms them.
    let reloaded = fixture.store()
    #expect(reloaded.pendingDataStoreRemovals == [profile.dataStoreIdentifier])
    try reloaded.markDataStoreRemoved(profile.dataStoreIdentifier)
    #expect(fixture.store().pendingDataStoreRemovals.isEmpty)
}

@Test func deleteIsDeferredUntilTheLastViewDetaches() throws {
    let fixture = ProfileFixture()
    defer { fixture.cleanup() }
    let store = fixture.store()
    let profile = try store.create(label: "Busy")
    _ = try store.attach(id: profile.id)
    _ = try store.attach(id: profile.id)
    #expect(store.attachedViewCount(id: profile.id) == 2)
    #expect(try store.delete(id: profile.id) == .deferred)
    #expect(store.profile(id: profile.id) == nil)
    #expect(store.profiles.map(\.id) == [BrowserProfileStore.builtInID])
    #expect(store.pendingDataStoreRemovals.isEmpty)
    #expect(throws: BrowserProfileStoreError.pendingDeletion(profile.id)) { try store.attach(id: profile.id) }
    #expect(throws: BrowserProfileStoreError.pendingDeletion(profile.id)) { try store.delete(id: profile.id) }
    #expect(try store.detach(id: profile.id) == nil)
    #expect(try store.detach(id: profile.id) == profile.dataStoreIdentifier)
    #expect(store.pendingDataStoreRemovals == [profile.dataStoreIdentifier])
    #expect(try store.detach(id: profile.id) == nil)
}

@Test func deferredDeletionIsFinalizedOnNextLaunch() throws {
    let fixture = ProfileFixture()
    defer { fixture.cleanup() }
    let store = fixture.store()
    let profile = try store.create(label: "Crash")
    _ = try store.attach(id: profile.id)
    #expect(try store.delete(id: profile.id) == .deferred)
    // The app quits (or crashes) with the view still open: a new process has no views.
    let reloaded = fixture.store()
    #expect(reloaded.profiles.map(\.id) == [BrowserProfileStore.builtInID])
    #expect(reloaded.pendingDataStoreRemovals == [profile.dataStoreIdentifier])
}

@Test func detachOfLiveProfileKeepsIt() throws {
    let fixture = ProfileFixture()
    defer { fixture.cleanup() }
    let store = fixture.store()
    let profile = try store.create(label: "Live")
    _ = try store.attach(id: profile.id)
    #expect(try store.detach(id: profile.id) == nil)
    #expect(store.profile(id: profile.id) != nil)
    #expect(store.attachedViewCount(id: profile.id) == 0)
}

@Test func corruptAndFutureFilesAreBackedUp() throws {
    let fixture = ProfileFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: fixture.file)
    let store = fixture.store()
    #expect(store.loadReport.count == 1 && store.loadReport[0].contains("corrupt"))
    #expect(store.profiles.count == 1)
    try Data(#"{"version": 99}"#.utf8).write(to: fixture.file)
    let future = fixture.store()
    #expect(future.loadReport.count == 1 && future.loadReport[0].contains("future"))
    let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
    #expect(names.filter { $0.contains(".corrupt-") }.count == 1)
    #expect(names.filter { $0.contains(".future-") }.count == 1)
}

@Test func missingDefaultReferenceFallsBackToBuiltIn() throws {
    let fixture = ProfileFixture()
    defer { fixture.cleanup() }
    _ = fixture.store()
    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file)) as! [String: Any]
    json["defaultProfileID"] = "gone"
    try JSONSerialization.data(withJSONObject: json).write(to: fixture.file)
    #expect(fixture.store().defaultProfile.id == BrowserProfileStore.builtInID)
}

@Test func concurrentCreatesAreAllPersisted() async throws {
    let fixture = ProfileFixture()
    defer { fixture.cleanup() }
    let store = fixture.store()
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<20 { group.addTask { _ = try? store.create(label: "P\(index)") } }
    }
    #expect(store.profiles.count == 21)
    #expect(fixture.store().profiles.count == 21)
}
