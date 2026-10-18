import SwiftUI

/// The whole panel, top to bottom: record, song, scrubber, transport, volume, the three lists, footer.
struct PanelView: View {
    @ObservedObject var player: Player
    @ObservedObject var art: ArtworkStore
    @ObservedObject var ui: PanelState

    private typealias M = PanelMetrics

    var body: some View {
        let palette = art.current?.palette ?? .house
        VStack(spacing: 0) {
            HeroView(player: player, art: art.current, palette: palette)
                .padding(.top, 20)
                .padding(.horizontal, M.pad)
            TrackInfo(player: player)
                .padding(.horizontal, M.pad)
                .padding(.top, 16)
            Scrubber(player: player, accent: palette.accent)
                .padding(.horizontal, M.pad)
                .padding(.top, 10)
            TransportRow(player: player, accent: palette.accent)
                .padding(.horizontal, M.pad + 10)
                .padding(.top, 4)
            VolumeRow(player: player, accent: palette.accent)
                .padding(.horizontal, M.pad)
                .padding(.top, 8)
            TabBar(ui: ui, player: player)
                .padding(.horizontal, M.pad - 4)
                .padding(.top, 14)
            ListArea(player: player, art: art, ui: ui, accent: palette.accent)
                .frame(height: M.listHeight)
                .padding(.top, 6)
            Footer(player: player, ui: ui)
        }
        .disabled(ui.showSettings)
        .frame(width: M.width)
        .background(Backdrop(art: art.current, palette: palette).equatable())
        .overlay(alignment: .bottom) { NoticeToast(text: player.notice) }
        .overlay { if ui.showSettings { SettingsCard(player: player, ui: ui).transition(.opacity.combined(with: .scale(scale: 0.97))) } }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .animation(.easeInOut(duration: 0.4), value: art.current?.key)
        .animation(.easeOut(duration: 0.18), value: ui.showSettings)
        .animation(.easeOut(duration: 0.2), value: player.notice)
        .tint(palette.accent)
        .environment(\.colorScheme, .dark)
        .environment(\.panelActive, ui.visible)
    }
}

/// The cover, blown up and blurred behind everything, fading into charcoal.
struct Backdrop: View, Equatable {
    let art: CoverArt?
    let palette: Palette

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg
            if let art {
                Image(nsImage: art.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: PanelMetrics.width + 120, height: 520)
                    .blur(radius: 46)
                    .saturation(1.35)
                    .opacity(0.62)
                    .frame(width: PanelMetrics.width, height: 520)
                    .clipped()
                    .id(art.key)
                    .transition(.opacity)
            } else {
                RadialGradient(colors: [palette.glow.opacity(0.38), .clear], center: UnitPoint(x: 0.3, y: 0.1), startRadius: 0, endRadius: 420)
            }
            LinearGradient(stops: [
                .init(color: Theme.bg.opacity(0.1), location: 0),
                .init(color: Theme.bg.opacity(0.55), location: 0.32),
                .init(color: Theme.bg.opacity(0.94), location: 0.62),
                .init(color: Theme.bg, location: 0.8),
            ], startPoint: .top, endPoint: .bottom)
        }
    }
}

// MARK: song

struct TrackInfo: View {
    @ObservedObject var player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .help(title)
            Text(artist)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.text.opacity(0.78))
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(albumLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let format = formatLine {
                    HStack(spacing: 5) {
                        if player.status.isHiRes {
                            Text("HI-RES")
                                .font(.system(size: 8.5, weight: .heavy))
                                .padding(.horizontal, 4).padding(.vertical, 1.5)
                                .background(Capsule().fill(Theme.accent.opacity(0.85)))
                                .foregroundStyle(Theme.bg)
                        }
                        Text(format)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.muted.opacity(0.85))
                    }
                    .fixedSize()
                    .help("What the server is playing, as MPD decodes it")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        switch player.link {
        case .online: return player.song?.displayTitle ?? "Nothing playing"
        case .connecting: return "Connecting to \(Settings.serverName)…"
        case .offline: return "Can't reach \(Settings.serverName)"
        case .away: return "You're away from home"
        }
    }

    private var artist: String {
        switch player.link {
        case .online: return player.song?.displayArtist ?? "The queue is empty — pick a playlist below"
        case .connecting: return "\(Settings.host):\(Settings.port)"
        case .offline(let why): return why
        case .away: return "Needle reconnects when the Mac is back on \(Settings.serverName)'s network"
        }
    }

    private var albumLine: String {
        guard player.isOnline, let s = player.song else {
            if case .offline = player.link { return "Retrying in the background" }
            return " "
        }
        return [s.album, s.year].compactMap { $0 }.joined(separator: " · ")
    }

    private var formatLine: String? {
        guard player.isOnline, let s = player.song, player.status.state != .stop else { return nil }
        var parts: [String] = []
        if !s.fileKind.isEmpty { parts.append(s.fileKind) }
        if let rate = player.status.audioDescription { parts.append(rate) }
        if let br = player.status.bitrate, s.fileKind == "MP3" || s.fileKind == "AAC" || s.fileKind == "OGG" { parts.append("\(br) kbps") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: scrubber

/// Thin until you hover; drag anywhere along it to seek (sent on release).
struct Scrubber: View {
    @ObservedObject var player: Player
    let accent: Color
    @Environment(\.panelActive) private var active
    @Local private var drag: Double? = nil
    @Local private var hovering = false

    var body: some View {
        let live = player.hasSong && player.duration > 0
        TimelineView(.animation(minimumInterval: 0.25, paused: !active || !player.isPlaying || drag != nil)) { timeline in
            let duration = player.duration
            let elapsed = drag.map { $0 * duration } ?? player.elapsed(at: timeline.date)
            let fraction = duration > 0 ? min(1, max(0, elapsed / duration)) : 0
            VStack(spacing: 4) {
                GeometryReader { geo in
                    let w = geo.size.width
                    let thick: CGFloat = (hovering || drag != nil) && live ? 7 : 4
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.13))
                        Capsule().fill(accent).frame(width: fraction > 0 ? max(thick, w * fraction) : 0)
                        if (hovering || drag != nil) && live {
                            Circle().fill(Theme.text)
                                .frame(width: 13, height: 13)
                                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                                .offset(x: w * fraction - 6.5)
                        }
                    }
                    .frame(height: thick)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in if live { drag = min(1, max(0, v.location.x / w)) } }
                        .onEnded { v in
                            guard live else { return }
                            player.seek(to: min(1, max(0, v.location.x / w)) * duration)
                            drag = nil
                        })
                }
                .frame(height: 14)
                HStack {
                    Text(live ? TimeText.clock(elapsed) : "–:––")
                    Spacer()
                    Text(live ? "-" + TimeText.clock(max(0, duration - elapsed)) : "–:––")
                }
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(drag != nil ? Theme.text : Theme.muted)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .opacity(live ? 1 : 0.45)
    }
}

// MARK: transport

struct TransportRow: View {
    @ObservedObject var player: Player
    let accent: Color

    var body: some View {
        let online = player.isOnline
        let playing = player.status.state == .play
        HStack(spacing: 0) {
            ToggleGlyph(symbol: "shuffle", on: player.status.random, accent: accent, help: "Shuffle") { player.toggleRandom() }
            Spacer()
            RoundGlyph(symbol: "backward.fill", size: 17, help: "Previous (←)") { player.previous() }
            Spacer()
            Button { player.togglePlay() } label: {
                ZStack {
                    Circle().fill(accent).shadow(color: accent.opacity(0.45), radius: 10, y: 3)
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(Theme.bg)
                        .offset(x: playing ? 0 : 1.5)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 50, height: 50)
            }
            .buttonStyle(PressStyle())
            .help(playing ? "Pause (space)" : "Play (space)")
            Spacer()
            RoundGlyph(symbol: "forward.fill", size: 17, help: "Next (→)") { player.next() }
            Spacer()
            ToggleGlyph(symbol: player.repeatMode == .one ? "repeat.1" : "repeat", on: player.repeatMode != .off, accent: accent,
                        help: "Repeat: off → all → this song") { player.cycleRepeat() }
        }
        .disabled(!online)
        .opacity(online ? 1 : 0.4)
        .animation(.easeOut(duration: 0.15), value: playing)
    }
}

struct VolumeRow: View {
    @ObservedObject var player: Player
    let accent: Color

    var body: some View {
        let v = max(0, player.status.volume)
        let usable = player.isOnline && player.status.volume >= 0
        HStack(spacing: 10) {
            Button { player.toggleMute() } label: {
                Image(systemName: v == 0 ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 11))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .help(v == 0 ? "Unmute" : "Mute")
            ValueSlider(value: Double(v) / 100, accent: accent) { player.setVolume(Int(($0 * 100).rounded())) }
            Text(usable ? "\(v)" : "–")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.muted)
                .frame(width: 24, alignment: .trailing)
        }
        .disabled(!usable)
        .opacity(usable ? 1 : 0.4)
        .help("Volume on \(Settings.serverName) (↑ ↓ in the panel, or scroll over the menu-bar icon)")
    }
}

/// A slim slider in the house style; reports every movement while dragging.
struct ValueSlider: View {
    let value: Double
    let accent: Color
    let onChange: (Double) -> Void
    @Local private var hovering = false
    @Local private var drag: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let shown = drag ?? value
            let thick: CGFloat = hovering || drag != nil ? 6 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.13))
                Capsule().fill(accent.opacity(0.9)).frame(width: shown > 0 ? max(thick, w * shown) : 0)
                Circle().fill(Theme.text)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: w * shown - 6)
                    .opacity(hovering || drag != nil ? 1 : 0)
            }
            .frame(height: thick)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let x = min(1, max(0, g.location.x / w))
                    drag = x
                    onChange(x)
                }
                .onEnded { _ in drag = nil })
        }
        .frame(height: 16)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Settings' buttons in the house colours (a plain default button takes the system accent, purple here).
struct PillStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .foregroundStyle(filled ? Theme.bg : Theme.text)
            .background(Capsule().fill(filled ? Theme.accent : Color.white.opacity(0.1)))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct RoundGlyph: View {
    let symbol: String
    var size: CGFloat = 15
    var help: String = ""
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.09 : 0)))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct ToggleGlyph: View {
    let symbol: String
    let on: Bool
    let accent: Color
    var help: String = ""
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? accent : Theme.muted)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.08 : 0)))
                .overlay(alignment: .bottom) {
                    Circle().fill(accent).frame(width: 3.5, height: 3.5).offset(y: -2).opacity(on ? 1 : 0)
                }
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: tabs

struct TabBar: View {
    @ObservedObject var ui: PanelState
    @ObservedObject var player: Player
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelState.Tab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { ui.tab = tab }
                    if tab == .search { ui.focusSearch += 1 }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 11)
                        .background {
                            if ui.tab == tab {
                                Capsule().fill(Color.white.opacity(0.12)).matchedGeometryEffect(id: "tab", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(ui.tab == tab ? Theme.text : Theme.muted)
            }
            Spacer()
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .padding(.trailing, 4)
        }
    }

    private var caption: String {
        guard player.isOnline else { return "" }
        switch ui.tab {
        case .queue:
            let n = player.status.playlistLength
            guard n > 0 else { return "" }
            let d = player.queueDuration
            return "\(n) song\(n == 1 ? "" : "s")" + (d > 0 ? " · \(TimeText.span(d))" : "")
        case .playlists:
            return player.playlists.isEmpty ? "" : "\(player.playlists.count) saved"
        case .search:
            if case .done(let n) = player.searchState, n > 0 { return n >= Player.searchLimit ? "\(n)+ songs" : "\(n) song\(n == 1 ? "" : "s")" }
            return ""
        }
    }
}

// MARK: footer

struct Footer: View {
    @ObservedObject var player: Player
    @ObservedObject var ui: PanelState
    @Environment(\.panelActive) private var active

    var body: some View {
        HStack(spacing: 7) {
            // Pulses while connecting. A clock, not a repeatForever animation: those also replay any
            // layout change caught in the same transaction, and the dot wandered off across the list.
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !active || player.link != .connecting)) { tl in
                Circle()
                    .fill(dot)
                    .frame(width: 7, height: 7)
                    .opacity(player.link == .connecting ? 0.45 + 0.55 * abs(sin(tl.date.timeIntervalSinceReferenceDate * 2.4)) : 1)
            }
            Text(line)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .help(detail)
            Spacer()
            if !player.isOnline, player.link != .connecting {
                Button("Retry") { player.reconnect(reason: "retry button") }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            FooterGlyph(symbol: "gearshape", help: "Settings (⌘,)") { ui.showSettings = true }
            FooterGlyph(symbol: "power", help: "Quit Needle") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var dot: Color {
        switch player.link {
        case .online: return Theme.good
        case .connecting: return Theme.accent
        case .offline: return Theme.bad
        case .away: return Theme.muted
        }
    }

    private var line: String {
        switch player.link {
        case .online:
            var parts = [Settings.serverName]
            if let s = player.stats { parts.append("\(s.songs.formatted()) songs") }
            if player.status.updatingDB { parts.append("updating library") }
            return parts.joined(separator: " · ")
        case .connecting: return "Connecting to \(Settings.serverName)…"
        case .offline: return "Offline"
        case .away: return "Away — not on the home network"
        }
    }

    private var detail: String {
        var lines = ["\(Settings.host):\(Settings.port)"]
        if player.isOnline {
            if !player.serverVersion.isEmpty { lines.append("MPD protocol \(player.serverVersion)") }
            if let s = player.stats {
                lines.append("\(s.artists.formatted()) artists · \(s.albums.formatted()) albums")
                let days = Int(s.uptime / 86400)
                lines.append("MPD up \(days) day\(days == 1 ? "" : "s")")
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct FooterGlyph: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : Theme.muted)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct NoticeToast: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.raised).shadow(color: .black.opacity(0.5), radius: 10, y: 4))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                .padding(.bottom, 46)
                .padding(.horizontal, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: settings

struct SettingsCard: View {
    @ObservedObject var player: Player
    @ObservedObject var ui: PanelState
    @Local private var host = Settings.host
    @Local private var port = String(Settings.port)
    @Local private var showTitle = Settings.showTitle
    @Local private var animateIcon = Settings.animateIcon
    @Local private var mediaKeys = Settings.mediaKeys
    @Local private var keepVolume = Settings.keepVolume

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).onTapGesture { ui.showSettings = false }
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                VStack(alignment: .leading, spacing: 6) {
                    Label("Server", systemImage: "hifispeaker.2")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                    HStack(spacing: 6) {
                        field("Host", text: $host)
                        field("Port", text: $port).frame(width: 64)
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    toggle("Song title in the menu bar", $showTitle)
                    toggle("Dancing menu-bar icon while playing", $animateIcon)
                    toggle("Media keys and Control Center", $mediaKeys)
                    toggle("Keep the volume when playback starts", $keepVolume)
                }
                Text("Cover art is read only for the song that's playing, so Needle never wakes a sleeping drive.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open log") { NSWorkspace.shared.open(Log.url) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Cancel") { ui.showSettings = false }
                        .buttonStyle(PillStyle(filled: false))
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { save() }
                        .buttonStyle(PillStyle(filled: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(width: PanelMetrics.width - 44)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: .monospaced))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }

    private func toggle(_ title: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Text(title).font(.system(size: 12.5)).foregroundStyle(Theme.text)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    private func save() {
        let newHost = host.trimmingCharacters(in: .whitespaces)
        let newPort = Int(port.trimmingCharacters(in: .whitespaces)) ?? Settings.defaultPort
        let serverChanged = newHost != Settings.host || newPort != Settings.port
        Settings.host = newHost.isEmpty ? Settings.defaultHost : newHost
        Settings.port = newPort
        Settings.showTitle = showTitle
        Settings.animateIcon = animateIcon
        Settings.mediaKeys = mediaKeys
        Settings.keepVolume = keepVolume
        player.nowPlaying?.setEnabled(mediaKeys)
        ui.showSettings = false
        if serverChanged { player.reconfigure() } else { player.objectWillChange.send() }
    }
}
