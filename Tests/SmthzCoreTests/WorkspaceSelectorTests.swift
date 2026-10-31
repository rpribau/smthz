import Foundation
import Testing
@testable import SmthzCore

struct WorkspaceSelectorTests {
    @Test func exactNamesBranchesIDsAndAmbiguity() throws {
        let a = WorkspaceSelectorCandidate(id: "a", path: "/a", name: "Hello", branch: "main", repoID: "repo")
        let b = WorkspaceSelectorCandidate(id: "b", path: "/b", name: "HELLO", branch: "other", repoID: "repo")
        #expect(try WorkspaceSelectors.resolve("id:a", candidates: [a,b]) == a)
        #expect(try WorkspaceSelectors.resolve("branch:main", candidates: [a,b]) == a)
        #expect(try WorkspaceSelectors.resolve("name:hello", candidates: [a]) == a)
        do { _ = try WorkspaceSelectors.resolve("name:hello", candidates: [a,b]); Issue.record("expected ambiguity") }
        catch let error as HostRPCError { #expect(error.code == "badRequest"); #expect(error.detail?.contains("id:a") == true); #expect(error.detail?.contains("id:b") == true) }
        #expect(throws: HostRPCError("notFound")) { try WorkspaceSelectors.resolve("id:none", candidates: [a]) }
    }
    @Test func currentAndPathUseCanonicalLongestComponentPrefix() throws {
        let f = try HostCoreFixture(), nested = f.directory.appendingPathComponent("nested"), inner = nested.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let root = try WorkspaceStore.canonicalPath(f.directory.path), child = try WorkspaceStore.canonicalPath(nested.path)
        let a = WorkspaceSelectorCandidate(id: "a", path: root, name: "A", repoID: "r")
        let b = WorkspaceSelectorCandidate(id: "b", path: child, name: "B", repoID: "s")
        #expect(try WorkspaceSelectors.resolve("current", candidates: [a,b], cwd: inner.path) == b)
        #expect(try WorkspaceSelectors.resolve("active", candidates: [a,b], cwd: inner.path) == b)
        #expect(try WorkspaceSelectors.resolve("path:" + inner.path, candidates: [a,b]) == b)
        #expect(try WorkspaceSelectors.defaultRepository(cwd: inner.path, worktrees: [a,b]) == "s")
        #expect(!WorkspaceSelectors.contains(root: child, path: child + "-other"))
    }
    @Test func repoSelectorRejectsBranchAndCurrent() throws {
        let a = WorkspaceSelectorCandidate(id: "a", path: "/a", name: "A", branch: "main", repoID: "r")
        #expect(throws: (any Error).self) { try WorkspaceSelectors.resolve("branch:main", candidates: [a], repository: true) }
        #expect(throws: (any Error).self) { try WorkspaceSelectors.resolve("current", candidates: [a], cwd: "/a", repository: true) }
        #expect(throws: (any Error).self) { try WorkspaceSelectors.resolve("issue:1", candidates: [a]) }
    }
    @Test func missingContextRequestsExplicitRepo() throws {
        #expect(throws: HostRPCError("badRequest", detail: "pass --repo")) {
            try WorkspaceSelectors.defaultRepository(cwd: nil, worktrees: [])
        }
    }
}
