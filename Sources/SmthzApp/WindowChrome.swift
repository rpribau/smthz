import AppKit
import SwiftUI

/// Configures the existing SwiftUI window without replacing its delegate.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeAttachment { ChromeAttachment() }
    func updateNSView(_ nsView: ChromeAttachment, context: Context) { nsView.configure() }

    @MainActor final class ChromeAttachment: NSView {
        private weak var configuredWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(updateButtons),
                name: NSWindow.didResizeNotification, object: window)
            configure()
            // SwiftUI finishes installing its titlebar after attachment.
            Task { @MainActor [weak self] in self?.configure() }
        }

        func configure() {
            guard let window else { return }
            window.tabbingMode = .disallowed
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbar = nil
            window.isMovableByWindowBackground = false
            window.minSize = NSSize(width: 600, height: 400)
            window.backgroundColor = NSColor(SmthzTheme.background)
            if configuredWindow !== window {
                configuredWindow = window
                let name = NSWindow.FrameAutosaveName("smthz.workspace")
                if !window.setFrameUsingName(name), let screen = window.screen ?? NSScreen.main {
                    window.setFrame(screen.visibleFrame, display: false)
                }
                window.setFrameAutosaveName(name)
            }
            updateButtons()
        }

        override func layout() {
            super.layout()
            updateButtons()
        }

        @objc private func updateButtons() {
            guard let window, !window.styleMask.contains(.fullScreen), let content = window.contentView else { return }
            for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
                let center = NSPoint(x: 16 + CGFloat(index) * 20 + button.frame.width / 2,
                    y: content.isFlipped ? 18 : content.bounds.height - 18)
                let local = parent.convert(center, from: content)
                button.setFrameOrigin(NSPoint(x: local.x - button.frame.width / 2,
                                              y: local.y - button.frame.height / 2))
            }
        }
    }
}

/// Put behind a chrome band: controls above it retain their own hit targets.
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) }
            else { window?.performDrag(with: event) }
        }
    }
}
