import Testing
import Foundation
@testable import SmthzCore

@Test
func identity_constants_match() {
    let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
    #expect(ApplicationIdentity.name == "smthz")
    #expect(ApplicationIdentity.bundleIdentifier == "dev.smthz.app")
    #expect(ApplicationIdentity.urlScheme == "smthz")
}

@Test
func directory_paths_are_correct() {
    let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
    #expect(ApplicationIdentity.applicationSupportDirectory(home: home).path == "/Users/test/Library/Application Support/smthz")
    #expect(ApplicationIdentity.cacheDirectory(home: home).path == "/Users/test/Library/Caches/smthz")
    #expect(ApplicationIdentity.logDirectory(home: home).path == "/Users/test/Library/Logs/smthz")
}

@Test
func path_leaf_names_match_product_identity() {
    let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
    let paths = [
        ApplicationIdentity.applicationSupportDirectory(home: home).path,
        ApplicationIdentity.cacheDirectory(home: home).path,
        ApplicationIdentity.logDirectory(home: home).path
    ]
    for path in paths {
        #expect(URL(filePath: path).lastPathComponent == ApplicationIdentity.name)
    }
}
