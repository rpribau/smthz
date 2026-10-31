import Foundation
import Testing
@testable import SmthzCore

/// Cases mirror Orca `src/shared/browser-url.test.ts` and `browser-page-zoom.ts`.
struct BrowserURLInputTests {
    @Test func localDevInputsBecomeHTTP() {
        #expect(BrowserURLInput.normalize("localhost:3000") == "http://localhost:3000/")
        #expect(BrowserURLInput.normalize("127.0.0.1:5173") == "http://127.0.0.1:5173/")
        #expect(BrowserURLInput.normalize("localhost:3000?debug=1") == "http://localhost:3000/?debug=1")
        #expect(BrowserURLInput.normalize("localhost:3000#preview") == "http://localhost:3000/#preview")
        #expect(BrowserURLInput.normalize("0.0.0.0:8080/app") == "http://0.0.0.0:8080/app")
    }

    @Test func webURLsAndBlankTabs() {
        #expect(BrowserURLInput.normalize("https://example.com") == "https://example.com/")
        #expect(BrowserURLInput.normalize("HTTPS://Example.COM/Path") == "https://example.com/Path")
        #expect(BrowserURLInput.normalize("") == BrowserURLInput.blankURL)
        #expect(BrowserURLInput.normalize("   ") == BrowserURLInput.blankURL)
        #expect(BrowserURLInput.normalize("about:blank") == BrowserURLInput.blankURL)
    }

    @Test func rejectsNonWebSchemes() {
        #expect(BrowserURLInput.normalize("javascript:alert(1)") == nil)
        #expect(BrowserURLInput.normalize("javascript:alert(1)", search: .google) == nil)
        #expect(BrowserURLInput.normalize("data:text/html,<b>x</b>") == nil)
        #expect(BrowserURLInput.normalizeExternal("about:blank") == nil)
    }

    @Test func fileURLsAndAbsolutePaths() {
        #expect(BrowserURLInput.normalize("file:///Users/me/site/index.html") == "file:///Users/me/site/index.html")
        #expect(BrowserURLInput.normalize("/Users/me/Downloads/Example.ipynb") == "file:///Users/me/Downloads/Example.ipynb")
        #expect(BrowserURLInput.normalize("C:\\Users\\me\\Downloads\\Example.ipynb") == "file:///C:/Users/me/Downloads/Example.ipynb")
        #expect(BrowserURLInput.normalize("\\\\server\\share\\Example.ipynb") == "file://server/share/Example.ipynb")
        #expect(BrowserURLInput.normalize("\\\\wsl.localhost\\Ubuntu\\home\\me\\Example.ipynb")
            == "file://wsl.localhost/Ubuntu/home/me/Example.ipynb")
    }

    @Test func pathsWithSpacesAndReservedCharacters() {
        #expect(BrowserURLInput.normalize("/Users/me/My Site/index #1.html") == "file:///Users/me/My%20Site/index%20%231.html")
        #expect(BrowserURLInput.normalize("C:\\Users\\me\\My Site\\index #1.html") == "file:///C:/Users/me/My%20Site/index%20%231.html")
        #expect(BrowserURLInput.normalize("C:\\tmp\\orca & 100% ! ^\\index.html")
            == "file:///C:/tmp/orca%20%26%20100%25%20!%20%5E/index.html")
        #expect(BrowserURLInput.isAbsoluteFilesystemPath("/tmp/x"))
        #expect(!BrowserURLInput.isAbsoluteFilesystemPath("tmp/x"))
    }

    @Test func externalOpensRefuseFileURLs() {
        #expect(BrowserURLInput.normalizeExternal("file:///etc/passwd") == nil)
        #expect(BrowserURLInput.normalizeExternal("\\\\server\\share\\Example.ipynb") == nil)
        #expect(BrowserURLInput.normalizeExternal("example.com") == "https://example.com/")
    }

    @Test func noSearchFallbackWithoutEngine() {
        #expect(BrowserURLInput.normalize("not a url") == nil)
        #expect(BrowserURLInput.normalize("singleword") == "https://singleword/")
    }

    @Test func searchFallbackWhenEnabled() {
        #expect(BrowserURLInput.normalize("react hooks", search: .google) == "https://www.google.com/search?q=react%20hooks")
        #expect(BrowserURLInput.normalize("what is typescript", search: .google)
            == "https://www.google.com/search?q=what%20is%20typescript")
        #expect(BrowserURLInput.normalize("singleword", search: .google) == "https://www.google.com/search?q=singleword")
        #expect(BrowserURLInput.normalize("c++ & swift?", search: .google) == "https://www.google.com/search?q=c%2B%2B%20%26%20swift%3F")
    }

    @Test func searchEngines() {
        #expect(BrowserURLInput.normalize("react hooks", search: .duckduckgo) == "https://duckduckgo.com/?q=react%20hooks")
        #expect(BrowserURLInput.normalize("react hooks", search: .bing) == "https://www.bing.com/search?q=react%20hooks")
        #expect(BrowserURLInput.normalize("react hooks", search: .kagi) == "https://kagi.com/search?q=react%20hooks")
        #expect(BrowserSearchEngine.allCases.map(\.label) == ["Google", "DuckDuckGo", "Bing", "Kagi"])
    }

    @Test func domainLikeInputNavigates() {
        #expect(BrowserURLInput.normalize("example.com", search: .google) == "https://example.com/")
        #expect(BrowserURLInput.normalize("github.com/org/repo", search: .google) == "https://github.com/org/repo")
        #expect(BrowserURLInput.normalize("example.com:8080/x") == "https://example.com:8080/x")
        #expect(BrowserURLInput.normalize("app.localhost:3000") == "http://app.localhost:3000/")
        #expect(!BrowserURLInput.looksLikeSearchQuery("docs.swift.org"))
        #expect(BrowserURLInput.looksLikeSearchQuery("swift"))
    }

    @Test func displayTextHidesBlank() {
        #expect(BrowserURLInput.displayText(nil) == "")
        #expect(BrowserURLInput.displayText(BrowserURLInput.blankURL) == "")
        #expect(BrowserURLInput.displayText("https://example.com/") == "https://example.com/")
    }

    @Test func pageZoomPresets() {
        #expect(BrowserPageZoom.percent(1) == 100)
        #expect(BrowserPageZoom.next(1, .zoomIn) == 1.1)
        #expect(BrowserPageZoom.next(1, .zoomOut) == 0.9)
        #expect(BrowserPageZoom.next(5, .zoomIn) == 5)
        #expect(BrowserPageZoom.next(0.25, .zoomOut) == 0.25)
        #expect(BrowserPageZoom.next(2.4, .reset) == 1)
        #expect(BrowserPageZoom.percent(1.07) == 110)
        #expect(BrowserPageZoom.percent(.nan) == 100)
        #expect(BrowserPageZoom.percent(0) == 100)
    }
}
