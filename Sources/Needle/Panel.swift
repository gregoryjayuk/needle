import AppKit
import SwiftUI

/// A borderless, non-activating panel (the launcher's recipe): it takes the keyboard for search
/// without activating Needle, so the app underneath keeps its menu bar and gets focus straight back.
final class NeedlePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// UI-only state the panel and its views share.
@MainActor
final class PanelState: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case queue = "Up Next"
        case playlists = "Playlists"
        case search = "Search"
        var id: String { rawValue }
    }

    @Published var tab: Tab = Tab(rawValue: Settings.tab) ?? .queue {
        didSet { Settings.tab = tab.rawValue }
    }
    @Published var showSettings = false
    /// Bumped to ask the search field to take focus.
    @Published var focusSearch = 0
    @Published var visible = false
}

/// Owns the panel: hangs it under the menu-bar item, fades it in and out, and handles the keys.
@MainActor
final class PanelController {
    let panel: NeedlePanel
    let ui = PanelState()
    private let player: Player
    private let hosting: NSHostingView<PanelView>
    private var keyMonitor: Any?
    private var resignObserver: Any?
    private var lastHide = Date.distantPast

    init(player: Player) {
        self.player = player
        panel = NeedlePanel(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 600),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        hosting = NSHostingView(rootView: PanelView(player: player, art: player.art, ui: ui))
        panel.contentView = hosting

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // NEEDLE_PIN keeps it open when focus goes elsewhere — for screenshots and debugging only.
            guard ProcessInfo.processInfo.environment["NEEDLE_PIN"] == nil else { return }
            Task { @MainActor in self?.hide() }
        }
    }

    var isVisible: Bool { ui.visible }

    func toggle(from button: NSStatusBarButton?) {
        if ui.visible { hide() }
        else if Date().timeIntervalSince(lastHide) > 0.3 { show(from: button) }   // the item's click arrives after resign-key hid us
    }

    func show(from button: NSStatusBarButton?, settings: Bool = false) {
        ui.showSettings = settings
        let size = hosting.fittingSize
        var frame = NSRect(origin: .zero, size: size)
        if let w = button?.window, let screen = w.screen ?? NSScreen.main {
            let item = w.frame
            let vf = screen.visibleFrame
            frame.origin.x = min(max(item.midX - size.width / 2, vf.minX + 8), vf.maxX - size.width - 8)
            frame.origin.y = item.minY - size.height - 6
        } else if let screen = NSScreen.main {
            frame.origin.x = screen.visibleFrame.maxX - size.width - 12
            frame.origin.y = screen.visibleFrame.maxY - size.height - 6
        }
        ui.visible = true
        player.panelVisible = true
        Log.write("panel: show at \(Int(frame.minX)),\(Int(frame.minY)) size \(Int(size.width))×\(Int(size.height))")
        panel.setFrame(frame.offsetBy(dx: 0, dy: 8), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
        installKeyMonitor()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
        panel.invalidateShadow()
    }

    func hide() {
        guard ui.visible else { return }
        ui.visible = false
        player.panelVisible = false
        lastHide = Date()
        removeKeyMonitor()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.ui.visible else { return }
                self.panel.orderOut(nil)
                self.ui.showSettings = false
            }
        })
    }

    // MARK: keys

    /// Space play/pause · ←/→ previous/next · ↑/↓ volume · ⌘F search · ⌘1-3 tabs · ⌘, settings · esc back out.
    /// Arrows and space belong to the search field while it is being typed in.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, self.ui.visible, ev.window === self.panel else { return ev }
            let typing = self.panel.firstResponder is NSTextView
            let cmd = ev.modifierFlags.contains(.command)
            if cmd {
                switch ev.charactersIgnoringModifiers ?? "" {
                case "f": self.ui.tab = .search; self.ui.focusSearch += 1; return nil
                case "1": self.ui.tab = .queue; return nil
                case "2": self.ui.tab = .playlists; return nil
                case "3": self.ui.tab = .search; return nil
                case ",": self.ui.showSettings = true; return nil
                case "w": self.hide(); return nil
                default: return ev
                }
            }
            switch ev.keyCode {
            case 53:   // esc
                if self.ui.showSettings { self.ui.showSettings = false }
                else if typing && !self.player.searchText.isEmpty { self.player.searchText = "" }
                else if typing { self.panel.makeFirstResponder(nil) }
                else { self.hide() }
                return nil
            case 49 where !typing: self.player.togglePlay(); return nil               // space
            case 123 where !typing: self.player.previous(); return nil                // ←
            case 124 where !typing: self.player.next(); return nil                    // →
            case 126 where !typing: self.player.nudgeVolume(by: 5); return nil        // ↑
            case 125 where !typing: self.player.nudgeVolume(by: -5); return nil       // ↓
            default: return ev
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }
}
