import AppKit
import SwiftUI

// Needle — an MPD music server, played from the Mac's menu bar.
//
// Runs as a menu-bar-only app. Ways in:
//   menu-bar icon   → click: the panel · ⌥-click or middle-click: play/pause · right-click: quick menu · scroll: volume
//   SIGUSR1         → toggles the panel (bind a hotkey to `pkill -USR1 -x Needle`)
//   media keys      → play/pause, next, previous, while the server is what's playing
// CLI (talks to MPD directly, no UI, exits): Needle status | toggle | play | pause | next | prev | stop
//   | vol [N|+N|-N] | playlists | load <name> [--shuffle] | search <words> | show | probe | help
// Build helpers: Needle --render-icon <dir.iconset> · Needle --app runs the menu-bar app from outside the bundle (development)

let arguments = Array(CommandLine.arguments.dropFirst())

if let first = arguments.first, first == "--render-icon" {
    let dir = arguments.count > 1 ? arguments[1] : "Needle.iconset"
    let ok = MainActor.assumeIsolated { IconRenderer.write(to: URL(fileURLWithPath: dir)) }
    exit(ok ? 0 : 1)
}

// Run as `needle` from a terminal (outside the .app) with nothing after it: say what's playing rather
// than start a second menu-bar app (that happened once, 18 Oct, from ~/.local/bin). `--app` forces the app.
let outsideBundle = Bundle.main.bundleIdentifier == nil
if let first = arguments.first, !first.hasPrefix("-") {
    Task { @MainActor in
        let code = await CLI.run(arguments)
        exit(code)
    }
    dispatchMain()
} else if arguments.isEmpty && outsideBundle {
    Task { @MainActor in
        let code = await CLI.run(["status"])
        exit(code)
    }
    dispatchMain()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var art: ArtworkStore!
    private var player: Player!
    private var nowPlaying: NowPlayingBridge!
    private var panel: PanelController!
    private var statusItem: StatusItemController!
    private var signalSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        art = ArtworkStore()
        player = Player(art: art)
        nowPlaying = NowPlayingBridge(player: player)
        player.nowPlaying = nowPlaying
        nowPlaying.setEnabled(Settings.mediaKeys)
        panel = PanelController(player: player)
        statusItem = StatusItemController(player: player)
        statusItem.onTogglePanel = { [weak self] in self?.togglePanel() }
        statusItem.onOpenSettings = { [weak self] in
            guard let self else { return }
            if self.panel.isVisible { self.panel.ui.showSettings = true } else { self.panel.show(from: self.statusItem.button, settings: true) }
        }
        buildMainMenu()

        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in self?.togglePanel() }
        source.resume()
        signalSource = source

        player.start()
        Log.write("started: \(Bundle.main.bundlePath) → \(Settings.host):\(Settings.port)")

        // Opening flags, for screenshots and debugging: --show [--tab queue|playlists|search] [--query words] [--settings]
        let args = CommandLine.arguments
        if args.contains("--show") || args.contains("--settings") {
            func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                if let tab = value("--tab"), let t = PanelState.Tab.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(tab.lowercased()) || "\($0)" == tab }) {
                    self.panel.ui.tab = t
                }
                if let q = value("--query") { self.panel.ui.tab = .search; self.player.searchText = q }
                self.panel.show(from: self.statusItem.button, settings: args.contains("--settings"))
            }
        }
    }

    func togglePanel() {
        panel.toggle(from: statusItem.button)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        togglePanel()
        return false
    }

    /// No menu bar of its own (LSUIElement), but text fields need the Edit commands for ⌘C, ⌘V, ⌘A.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Needle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

// One copy at a time: a second launch (Finder, `open`, the LaunchAgent) asks the first to show its panel.
if ProcessInfo.processInfo.environment["NEEDLE_ALLOW_SECOND"] == nil,
   let other = NSRunningApplication.runningApplications(withBundleIdentifier: "com.greggaynor.needle").first(where: { $0.processIdentifier != getpid() }) {
    kill(other.processIdentifier, SIGUSR1)
    exit(0)
}

signal(SIGUSR1, SIG_IGN)   // the default action would terminate; the DispatchSource picks it up instead
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
