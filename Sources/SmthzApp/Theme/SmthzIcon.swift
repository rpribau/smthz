import AppKit
import SwiftUI

/// Lucide icons bundled as SVG in `Contents/Resources/Icons` (UI-SPEC §14, §16).
/// Falls back to the SF Symbol from the §14 table when the SVG is missing.
enum SmthzIcon {
    struct Name: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }
        init(stringLiteral value: String) { self.rawValue = value }

        static let panelLeft: Name = "panel-left"
        static let panelRight: Name = "panel-right"
        static let arrowLeft: Name = "arrow-left"
        static let arrowRight: Name = "arrow-right"
        static let minimize2: Name = "minimize-2"
        static let search: Name = "search"
        static let list: Name = "list"
        static let calendarClock: Name = "calendar-clock"
        static let smartphone: Name = "smartphone"
        static let files: Name = "files"
        static let bookOpen: Name = "book-open"
        static let eyeOff: Name = "eye-off"
        static let bell: Name = "bell"
        static let slidersHorizontal: Name = "sliders-horizontal"
        static let folderPlus: Name = "folder-plus"
        static let plus: Name = "plus"
        static let settings: Name = "settings"
        static let crosshair: Name = "crosshair"
        static let kanban: Name = "square-kanban"
        static let chevronDown: Name = "chevron-down"
        static let chevronLeft: Name = "chevron-left"
        static let chevronRight: Name = "chevron-right"
        static let chevronUp: Name = "chevron-up"
        static let folderTree: Name = "folder-tree"
        static let pin: Name = "pin"
        static let x: Name = "x"
        static let ellipsis: Name = "ellipsis"
        static let play: Name = "play"
        static let star: Name = "star"
        static let trash2: Name = "trash-2"
        static let server: Name = "server"
        static let serverOff: Name = "server-off"
        static let gitBranch: Name = "git-branch"
        static let gitBranchPlus: Name = "git-branch-plus"
        static let gitMerge: Name = "git-merge"
        static let workflow: Name = "workflow"
        static let listChecks: Name = "list-checks"
        static let plug: Name = "plug"
        static let memoryStick: Name = "memory-stick"
        static let terminal: Name = "terminal"
        static let squareTerminal: Name = "square-terminal"
        static let panelsTopLeft: Name = "panels-top-left"
        static let folder: Name = "folder"
        static let folderOpen: Name = "folder-open"
        static let activity: Name = "activity"
        static let circleCheck: Name = "circle-check"
        static let circleDashed: Name = "circle-dashed"
        static let loaderCircle: Name = "loader-circle"
        static let alertTriangle: Name = "triangle-alert"
        static let palette: Name = "palette"
        static let keyboard: Name = "keyboard"
        static let mic: Name = "mic"
        static let globe: Name = "globe"
        static let lock: Name = "lock"
        static let shieldCheck: Name = "shield-check"
        static let wrench: Name = "wrench"
        static let bug: Name = "bug"
        static let flaskConical: Name = "flask-conical"
        static let history: Name = "history"
        static let barChart3: Name = "chart-no-axes-column"
        static let messageSquare: Name = "message-square"
        static let network: Name = "network"
        static let mousePointerClick: Name = "mouse-pointer-click"
        static let bot: Name = "bot"
        static let userCog: Name = "user-cog"
        static let circleUserRound: Name = "circle-user-round"
        static let blocks: Name = "blocks"
        static let textCursorInput: Name = "text-cursor-input"
        static let cable: Name = "cable"
        static let circleHelp: Name = "circle-help"
        static let check: Name = "check"
        static let copy: Name = "copy"
        static let tabletSmartphone: Name = "tablet-smartphone"
    }

    /// SF Symbol fallbacks (UI-SPEC §14). Names without an exact match use the closest symbol.
    static let sfSymbolFallback: [String: String] = [
        "panel-left": "sidebar.left", "panel-right": "sidebar.right",
        "arrow-left": "arrow.left", "arrow-right": "arrow.right",
        "minimize-2": "arrow.down.right.and.arrow.up.left", "search": "magnifyingglass",
        "list": "list.bullet", "calendar-clock": "calendar.badge.clock", "smartphone": "iphone",
        "files": "doc.on.doc", "book-open": "book", "eye-off": "eye.slash", "bell": "bell",
        "sliders-horizontal": "slider.horizontal.3", "folder-plus": "folder.badge.plus",
        "plus": "plus", "settings": "gearshape", "crosshair": "scope",
        "square-kanban": "rectangle.split.3x1", "chevron-down": "chevron.down",
        "chevron-left": "chevron.left", "chevron-right": "chevron.right", "chevron-up": "chevron.up",
        "folder-tree": "folder", "pin": "pin", "x": "xmark", "ellipsis": "ellipsis", "play": "play",
        "star": "star.fill", "trash-2": "trash", "server": "server.rack", "server-off": "server.rack",
        "git-branch": "arrow.triangle.branch", "git-branch-plus": "arrow.triangle.branch",
        "git-merge": "arrow.triangle.merge", "workflow": "point.3.connected.trianglepath.dotted",
        "list-checks": "checklist", "plug": "powerplug", "memory-stick": "memorychip",
        "terminal": "terminal", "square-terminal": "apple.terminal",
        "panels-top-left": "uiwindow.split.2x1", "folder": "folder", "folder-open": "folder",
        "activity": "waveform.path.ecg", "circle-check": "checkmark.circle",
        "circle-dashed": "circle.dashed", "loader-circle": "arrow.triangle.2.circlepath",
        "triangle-alert": "exclamationmark.triangle", "palette": "paintpalette",
        "keyboard": "keyboard", "mic": "mic", "globe": "globe", "lock": "lock",
        "shield-check": "checkmark.shield", "wrench": "wrench.and.screwdriver", "bug": "ant",
        "flask-conical": "flask", "history": "clock.arrow.circlepath",
        "chart-no-axes-column": "chart.bar", "message-square": "message", "network": "network",
        "mouse-pointer-click": "cursorarrow.click", "bot": "cpu", "user-cog": "person.crop.circle",
        "circle-user-round": "person.crop.circle", "blocks": "square.grid.2x2",
        "text-cursor-input": "character.cursor.ibeam", "cable": "cable.connector",
        "circle-help": "questionmark.circle", "check": "checkmark", "copy": "doc.on.doc",
        "tablet-smartphone": "ipad.and.iphone",
    ]

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [String: NSImage] = [:]
        private var svgs: [String: String] = [:]

        func image(for key: String) -> NSImage? {
            lock.lock(); defer { lock.unlock() }
            return images[key]
        }
        func store(_ image: NSImage, for key: String) {
            lock.lock(); defer { lock.unlock() }
            images[key] = image
        }
        func svg(for name: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return svgs[name]
        }
        func store(svg: String, for name: String) {
            lock.lock(); defer { lock.unlock() }
            svgs[name] = svg
        }
    }

    private static let cache = Cache()

    private static func svgSource(_ name: String) -> String? {
        if let cached = cache.svg(for: name) { return cached }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Icons/\(name).svg"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        cache.store(svg: text, for: name)
        return text
    }

    /// Template `NSImage` (24×24 pt) for the Lucide icon at the given stroke width, or nil if not bundled.
    static func nsImage(_ name: Name, stroke: Double = 2) -> NSImage? {
        let key = "\(name.rawValue)@\(stroke)"
        if let hit = cache.image(for: key) { return hit }
        guard let svg = svgSource(name.rawValue) else { return nil }
        let adjusted = svg.replacingOccurrences(of: "stroke-width=\"2\"", with: "stroke-width=\"\(stroke)\"")
        // `currentColor` has no meaning outside a browser; render black and let template tinting recolour.
        let concrete = adjusted.replacingOccurrences(of: "currentColor", with: "#000000")
        guard let data = concrete.data(using: .utf8), let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: 24, height: 24)
        image.isTemplate = true
        cache.store(image, for: key)
        return image
    }

    /// Resizable template image: size it with `.frame` and colour it with `.foregroundStyle`.
    static func image(_ name: Name, stroke: Double = 2) -> Image {
        if let ns = nsImage(name, stroke: stroke) {
            return Image(nsImage: ns).renderingMode(.template).resizable()
        }
        let symbol = sfSymbolFallback[name.rawValue] ?? "questionmark.square.dashed"
        return Image(systemName: symbol).renderingMode(.template).resizable()
    }

    /// String-keyed variant for callers that hold a Lucide name at runtime.
    static func image(_ name: String, stroke: Double = 2) -> Image {
        image(Name(rawValue: name), stroke: stroke)
    }

    /// Convenience: an icon at a point size (Lucide's 24-unit box scaled to `size`).
    static func view(_ name: Name, size: CGFloat = 16, stroke: Double = 2) -> some View {
        image(name, stroke: stroke)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}
