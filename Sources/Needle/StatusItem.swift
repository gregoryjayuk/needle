import AppKit
import Combine

/// The menu-bar item: a little level meter that dances while the server plays, and the song beside it.
///
///   click            → the panel
///   ⌥-click, middle  → play / pause, without opening anything
///   right-click      → quick menu (volume presets, playlists, settings)
///   scroll over it   → volume (the level shows in place of the title for a moment)
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let player: Player
    var onTogglePanel: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private var bag = Set<AnyCancellable>()
    private let meter = MeterView(frame: NSRect(origin: .zero, size: MeterView.size))
    private var scrollMonitor: Any?
    private var scrollCarry: CGFloat = 0
    private var flashTask: Task<Void, Never>?

    var button: NSStatusBarButton? { item.button }

    init(player: Player) {
        self.player = player
        super.init()
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp, .otherMouseUp])
        button.imagePosition = .imageLeading
        // A blank image holds the meter's place; the meter itself is a layer-animated subview on top.
        let spacer = NSImage(size: MeterView.size)
        spacer.isTemplate = true
        button.image = spacer
        button.addSubview(meter)
        item.autosaveName = "NeedleStatusItem"

        player.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] ev in
            guard let self, let w = self.item.button?.window, ev.window === w else { return ev }
            self.scrolled(ev)
            return nil
        }
        refresh()
    }

    // MARK: drawing

    func refresh() {
        guard let button = item.button else { return }
        let mode: MeterView.Mode
        switch (player.isOnline, player.status.state) {
        case (false, _): mode = .offline
        case (true, .stop): mode = .stopped
        case (true, .pause): mode = .paused
        case (true, .play): mode = Settings.animateIcon ? .playing : .paused
        }
        meter.set(mode)
        button.attributedTitle = title()
        button.toolTip = tooltip()
        placeMeter()
    }

    /// Over the spacer image, wherever the button's layout put it (it moves when the title changes).
    private func placeMeter() {
        guard let button = item.button, let cell = button.cell else { return }
        button.layoutSubtreeIfNeeded()
        let r = cell.imageRect(forBounds: button.bounds)
        meter.frame = NSRect(x: r.midX - MeterView.size.width / 2, y: r.midY - MeterView.size.height / 2,
                             width: MeterView.size.width, height: MeterView.size.height)
    }

    private func title() -> NSAttributedString {
        let font = NSFont.menuBarFont(ofSize: 0)
        var text = ""
        if let at = player.volumeNudgedAt, Date().timeIntervalSince(at) < 1.4, player.status.volume >= 0 {
            text = "Volume \(player.status.volume)"
            scheduleFlashEnd()
        } else if Settings.showTitle, player.isOnline, let song = player.song, player.status.state != .stop {
            text = "\(song.displayTitle) · \(song.displayArtist)"
        }
        guard !text.isEmpty else { return NSAttributedString(string: "") }
        text = StatusItemController.fit(" " + text, font: font, width: 170)
        let dim = player.status.state == .pause
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: dim ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
    }

    private func tooltip() -> String {
        switch player.link {
        case .online:
            guard let s = player.song else { return "Needle — nothing queued on \(Settings.serverName)" }
            var t = "\(s.displayTitle)\n\(s.displayArtist)"
            if let album = s.album { t += " — \(album)" }
            return t + "\n\nClick for the player · ⌥-click to play/pause · scroll for volume"
        case .connecting: return "Needle — connecting to \(Settings.serverName)…"
        case .offline(let why): return "Needle — can't reach \(Settings.serverName)\n\(why)"
        case .away: return "Needle — \(Settings.serverName) is on your home network"
        }
    }

    private func scheduleFlashEnd() {
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Truncates with an ellipsis so the item never grows past `width` points — the MacBook's notch
    /// hides menu-bar items that get pushed too far left.
    static func fit(_ s: String, font: NSFont, width: CGFloat) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (s as NSString).size(withAttributes: attrs).width <= width { return s }
        var chars = Array(s)
        while chars.count > 1 {
            chars.removeLast()
            let candidate = String(chars).trimmingCharacters(in: .whitespaces) + "…"
            if (candidate as NSString).size(withAttributes: attrs).width <= width { return candidate }
        }
        return s
    }

    // MARK: input

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let ev = NSApp.currentEvent else { return }
        switch ev.type {
        case .rightMouseUp:
            showMenu()
        case .otherMouseUp:
            player.togglePlay()
        default:
            if ev.modifierFlags.contains(.option) { player.togglePlay() }
            else if ev.modifierFlags.contains(.control) { showMenu() }
            else { onTogglePanel?() }
        }
    }

    private func scrolled(_ ev: NSEvent) {
        guard player.isOnline, player.status.volume >= 0 else { return }
        // Fingers (or wheel) up = louder, whatever the natural-scrolling setting.
        let dy = ev.isDirectionInvertedFromDevice ? -ev.scrollingDeltaY : ev.scrollingDeltaY
        if ev.hasPreciseScrollingDeltas {
            scrollCarry += dy
            let steps = Int(scrollCarry / 6)
            guard steps != 0 else { return }
            scrollCarry -= CGFloat(steps) * 6
            player.nudgeVolume(by: steps)
        } else if dy != 0 {
            player.nudgeVolume(by: dy > 0 ? 2 : -2)
        }
    }

    // MARK: menu

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: headerText(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let online = player.isOnline
        menu.addItem(entry(player.status.state == .play ? "Pause" : "Play", enabled: online) { $0.togglePlay() })
        menu.addItem(entry("Next Song", enabled: online && player.song != nil) { $0.next() })
        menu.addItem(entry("Previous Song", enabled: online && player.song != nil) { $0.previous() })
        menu.addItem(.separator())

        let volume = NSMenuItem(title: "Volume", action: nil, keyEquivalent: "")
        let volumeMenu = NSMenu()
        for v in [100, 85, 70, 50, 30] {
            let e = entry("\(v)", enabled: online) { $0.setVolume(v) }
            e.state = player.status.volume == v ? .on : .off
            volumeMenu.addItem(e)
        }
        volumeMenu.addItem(.separator())
        volumeMenu.addItem(entry(player.status.volume == 0 ? "Unmute" : "Mute", enabled: online) { $0.toggleMute() })
        volume.submenu = volumeMenu
        volume.isEnabled = online && player.status.volume >= 0
        menu.addItem(volume)

        let lists = NSMenuItem(title: "Playlists", action: nil, keyEquivalent: "")
        let listsMenu = NSMenu()
        for p in player.playlists {
            let e = entry(p.displayName, enabled: online) { $0.playPlaylist(p.name) }
            e.state = player.status.lastLoadedPlaylist == p.name ? .on : .off
            listsMenu.addItem(e)
        }
        lists.submenu = listsMenu
        lists.isEnabled = online && !player.playlists.isEmpty
        menu.addItem(lists)
        menu.addItem(.separator())

        let titleToggle = action("Song Title in Menu Bar") { me in
            Settings.showTitle.toggle()
            me.refresh()
        }
        titleToggle.state = Settings.showTitle ? .on : .off
        menu.addItem(titleToggle)
        menu.addItem(action("Settings…") { $0.onOpenSettings?() })
        if !online {
            menu.addItem(entry("Reconnect", enabled: true) { $0.reconnect(reason: "menu") })
        }
        menu.addItem(.separator())
        menu.addItem(action("Quit Needle") { _ in NSApp.terminate(nil) })

        if let button = item.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        }
    }

    private func headerText() -> String {
        switch player.link {
        case .online:
            guard let s = player.song else { return "Nothing queued on \(Settings.serverName)" }
            return "\(s.displayTitle) — \(s.displayArtist)"
        case .connecting: return "Connecting to \(Settings.serverName)…"
        case .offline: return "Can't reach \(Settings.serverName)"
        case .away: return "Away from \(Settings.serverName)'s network"
        }
    }

    private func entry(_ title: String, enabled: Bool, _ body: @escaping (Player) -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title) { [weak self] in
            guard let p = self?.player else { return }
            body(p)
        }
        item.isEnabled = enabled
        return item
    }

    private func action(_ title: String, _ body: @escaping (StatusItemController) -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title) { [weak self] in
            guard let self else { return }
            body(self)
        }
    }
}

/// An NSMenuItem that runs a closure — keeps the menu code readable.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// The menu-bar level meter: four bars as CALayers. While the server plays, each bar runs its own
/// endless keyframe animation, which Core Animation renders outside this process. The first version
/// redrew an image 12 times a second from a timer and cost ~6 % CPU; this costs nothing measurable.
final class MeterView: NSView {
    enum Mode: Equatable { case playing, paused, stopped, offline }

    static let size = NSSize(width: 15, height: 16)
    private let barWidth: CGFloat = 2.5
    private let gap: CGFloat = 1.6
    private let tallest: CGFloat = 12
    private var bars: [CALayer] = []
    private var mode: Mode?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<4 {
            let bar = CALayer()
            bar.cornerRadius = barWidth / 2
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        layoutBars()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks belong to the button underneath

    override func layout() {
        super.layout()
        layoutBars()
    }

    /// Follows the menu bar's own appearance (dark text on a light wallpaper, light on dark).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    func set(_ new: Mode) {
        if new == mode, new != .playing || bars.first?.animation(forKey: "level") != nil { return }
        mode = new
        applyColor()
        let still: [CGFloat]
        switch new {
        case .playing: still = []
        case .paused: still = [0.38, 0.62, 0.48, 0.3]
        case .stopped: still = [0.2, 0.2, 0.2, 0.2]
        case .offline: still = [0.16, 0.16, 0.16, 0.16]
        }
        for (i, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: "level")
            if new == .playing {
                var rng = SeededRandom(UInt64(i + 1) &* 7919)
                var heights = (0..<14).map { _ in self.tallest * CGFloat(0.18 + 0.82 * rng.unit()) }
                heights.append(heights[0])   // loop seamlessly
                let a = CAKeyframeAnimation(keyPath: "bounds.size.height")
                a.values = heights
                a.duration = 2.9 + Double(i) * 0.43
                a.calculationMode = .cubic
                a.repeatCount = .infinity
                a.isRemovedOnCompletion = false
                bar.add(a, forKey: "level")
            } else {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.25)
                bar.bounds.size.height = max(2.5, tallest * still[i])
                CATransaction.commit()
            }
        }
    }

    private func layoutBars() {
        let total = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
        var x = (bounds.width - total) / 2 + barWidth / 2
        let y = (bounds.height - tallest) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: max(2.5, bar.bounds.height == 0 ? tallest * 0.2 : bar.bounds.height))
            bar.position = CGPoint(x: x, y: y)
            x += barWidth + gap
        }
        CATransaction.commit()
    }

    private func applyColor() {
        var color = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars { bar.backgroundColor = color }
        CATransaction.commit()
        alphaValue = mode == .offline ? 0.4 : 1
    }
}
