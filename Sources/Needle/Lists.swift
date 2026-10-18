import SwiftUI

/// The bottom of the panel: Up Next, Playlists, or Search.
struct ListArea: View {
    @ObservedObject var player: Player
    let art: ArtworkStore
    @ObservedObject var ui: PanelState
    let accent: Color

    var body: some View {
        Group {
            if !player.isOnline {
                EmptyNote(symbol: player.link == .away ? "house" : "wifi.exclamationmark",
                          title: player.link == .connecting ? "Connecting…" : "Not connected",
                          detail: player.link == .away
                            ? "Needle reconnects when this Mac is back on the home network."
                            : "Needle keeps trying. Check that \(Settings.serverName) is on, or change the server in Settings.")
            } else {
                switch ui.tab {
                case .queue: QueueList(player: player, art: art, accent: accent)
                case .playlists: PlaylistList(player: player, art: art, accent: accent)
                case .search: SearchPane(player: player, art: art, ui: ui, accent: accent)
                }
            }
        }
        .transition(.opacity)
    }
}

// MARK: up next

struct QueueList: View {
    @ObservedObject var player: Player
    let art: ArtworkStore
    let accent: Color

    var body: some View {
        if player.queue.isEmpty {
            EmptyNote(symbol: "music.note.list", title: "Nothing queued", detail: "Start a playlist, or search for something to play.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(player.queue) { song in
                            let current = song.songId == player.status.songId && player.status.songId != nil
                            let past = (song.pos ?? 0) < (player.status.songPos ?? 0)
                            SongRow(song: song, art: art, accent: accent, isCurrent: current,
                                    playing: current && player.status.state == .play, dimmed: past && !current) {
                                player.playQueued(song)
                            } actions: { _ in
                                EmptyView()
                            } menu: {
                                Button("Play") { player.playQueued(song) }
                                Button("Remove from Up Next") { player.removeQueued(song) }
                                Divider()
                                Button("Add the Whole Album to Up Next") { player.playAlbum(of: song, replace: false) }
                            }
                            .id(song.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.never)
                .onAppear { scrollToCurrent(proxy, animated: false) }
                .onChange(of: player.status.songId) { _, _ in scrollToCurrent(proxy, animated: true) }
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = player.status.songId else { return }
        let target = "id:\(id)"
        if animated { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .top) } }
        else { proxy.scrollTo(target, anchor: .top) }
    }
}

// MARK: playlists

struct PlaylistList: View {
    @ObservedObject var player: Player
    let art: ArtworkStore
    let accent: Color

    var body: some View {
        if player.playlists.isEmpty {
            EmptyNote(symbol: "rectangle.stack", title: "No saved playlists", detail: "Playlists saved on the server (mpc save, ncmpcpp) show up here.")
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(player.playlists) { p in
                        PlaylistRow(playlist: p, art: art, accent: accent, loaded: player.status.lastLoadedPlaylist == p.name,
                                    play: { player.playPlaylist(p.name) },
                                    shuffle: { player.playPlaylist(p.name, shuffle: true) },
                                    append: { player.appendPlaylist(p.name) })
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.never)
            .task { await player.refreshPlaylists() }
        }
    }
}

struct PlaylistRow: View {
    let playlist: PlaylistInfo
    let art: ArtworkStore
    let accent: Color
    let loaded: Bool
    let play: () -> Void
    let shuffle: () -> Void
    let append: () -> Void
    @Local private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            Mosaic(directories: playlist.directories, name: playlist.name, art: art)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(playlist.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(loaded ? accent : Theme.text)
                        .lineLimit(1)
                    if loaded {
                        Text("IN QUEUE")
                            .font(.system(size: 8, weight: .heavy))
                            .padding(.horizontal, 4).padding(.vertical, 1.5)
                            .background(Capsule().fill(accent.opacity(0.22)))
                            .foregroundStyle(accent)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                HStack(spacing: 2) {
                    MiniGlyph(symbol: "shuffle", help: "Shuffle and play", action: shuffle)
                    MiniGlyph(symbol: "text.append", help: "Add to the end of Up Next", action: append)
                    MiniGlyph(symbol: "play.fill", help: "Play now (replaces Up Next)", action: play)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hovering = h } }
        .onTapGesture(perform: play)
        .contextMenu {
            Button("Play", action: play)
            Button("Shuffle and Play", action: shuffle)
            Button("Add to Up Next", action: append)
        }
        .help("Click to play — replaces Up Next")
    }

    private var subtitle: String {
        var parts: [String] = []
        if let n = playlist.count { parts.append("\(n) song\(n == 1 ? "" : "s")") }
        if let d = playlist.duration, d > 0 { parts.append(TimeText.span(d)) }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }
}

/// Four covers from the playlist's albums — the ones already cached on this Mac — or its own generated tile.
struct Mosaic: View {
    let directories: [String]
    let name: String
    let art: ArtworkStore
    @Local private var images: [NSImage] = []

    var body: some View {
        ZStack {
            if images.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) { tile(images[0]); tile(images[1]) }
                    HStack(spacing: 0) { tile(images[2]); tile(images[3]) }
                }
            } else if let first = images.first {
                Image(nsImage: first).resizable().aspectRatio(contentMode: .fill)
            } else {
                GeneratedCover(title: name, compact: true)
            }
        }
        .task(id: directories) {
            var found: [NSImage] = []
            for d in directories {
                if let img = await art.thumbnail(for: d) { found.append(img) }
                if found.count == 4 { break }
            }
            images = found
        }
    }

    private func tile(_ image: NSImage) -> some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 20, height: 20).clipped()
    }
}

// MARK: search

struct SearchPane: View {
    @ObservedObject var player: Player
    let art: ArtworkStore
    @ObservedObject var ui: PanelState
    let accent: Color
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.muted)
                TextField(placeholder, text: $player.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit {
                        if let first = player.searchResults.first { player.playNow(first) }
                        else if let album = player.searchAlbums.first { player.playAlbum(album, replace: true) }
                    }
                if player.searchState == .searching {
                    ProgressView().controlSize(.mini)
                } else if !player.searchText.isEmpty {
                    Button { player.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(focused ? accent.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1))
            .padding(.horizontal, 14)

            results
        }
        .onAppear { if player.searchText.isEmpty { focused = true } }
        .onChange(of: ui.focusSearch) { _, _ in focused = true }
    }

    private var placeholder: String {
        if let n = player.stats?.songs, n > 0 { return "Search \(n.formatted()) songs" }
        return "Search the library"
    }

    @ViewBuilder private var results: some View {
        let nothingLocal = player.searchArtists.isEmpty && player.searchAlbums.isEmpty
        switch player.searchState {
        case .idle:
            EmptyNote(symbol: "sparkle.magnifyingglass", title: "Artist, album or song",
                      detail: "Artists and albums appear as you type; songs a moment later. Return plays the first song.")
        case .failed(let why) where nothingLocal:
            EmptyNote(symbol: "exclamationmark.triangle", title: "Search failed", detail: why)
        case .done(0) where nothingLocal:
            EmptyNote(symbol: "magnifyingglass", title: "Nothing matches", detail: "Try fewer or shorter words.")
        default:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !player.searchArtists.isEmpty {
                        SectionLabel(text: "Artists")
                        ForEach(player.searchArtists) { artist in
                            ArtistRow(artist: artist, shuffle: { player.shuffleArtist(artist.name) }) {
                                player.searchText = artist.name
                            }
                        }
                    }
                    if !player.searchAlbums.isEmpty {
                        SectionLabel(text: "Albums")
                        ForEach(player.searchAlbums) { album in
                            AlbumRow(album: album, player: player, art: art,
                                     play: { player.playAlbum(album, replace: true) },
                                     append: { player.playAlbum(album, replace: false) })
                        }
                    }
                    if !player.searchResults.isEmpty {
                        SectionLabel(text: "Songs")
                        ForEach(player.searchResults) { song in
                            SongRow(song: song, art: art, accent: accent, isCurrent: song.file == player.song?.file,
                                    playing: song.file == player.song?.file && player.status.state == .play, dimmed: false) {
                                player.playNow(song)
                            } actions: { hovering in
                                if hovering {
                                    HStack(spacing: 0) {
                                        MiniGlyph(symbol: "text.line.first.and.arrowtriangle.forward", help: "Play next") { player.playNext(song) }
                                        MiniGlyph(symbol: "plus", help: "Add to the end of Up Next") { player.enqueue(song) }
                                    }
                                }
                            } menu: {
                                Button("Play Now") { player.playNow(song) }
                                Button("Play Next") { player.playNext(song) }
                                Button("Add to Up Next") { player.enqueue(song) }
                                Divider()
                                Button("Play the Album (its folder)") { player.playAlbum(of: song, replace: true) }
                                Button("Add the Album to Up Next") { player.playAlbum(of: song, replace: false) }
                            }
                        }
                    } else if player.searchState == .searching {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text("Finding songs…").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.never)
        }
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.muted.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }
}

struct ArtistRow: View {
    let artist: LibraryIndex.Artist
    let shuffle: () -> Void
    let open: () -> Void
    @Local private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            GeneratedCover(title: artist.name, compact: true)
                .frame(width: 32, height: 32)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1.5) {
                Text(artist.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(artist.albums) album\(artist.albums == 1 ? "" : "s") · click for their songs")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering { MiniGlyph(symbol: "shuffle", help: "Shuffle everything by \(artist.name)", action: shuffle) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            Button("Show Their Songs", action: open)
            Button("Shuffle Everything by \(artist.name)", action: shuffle)
        }
    }
}

struct AlbumRow: View {
    let album: LibraryIndex.Album
    let player: Player
    let art: ArtworkStore
    let play: () -> Void
    let append: () -> Void
    @Local private var hovering = false
    @Local private var image: NSImage? = nil

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                else { GeneratedCover(title: album.title, compact: true) }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1.5) {
                Text(album.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(album.artist.isEmpty ? "Unknown artist" : album.artist).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                HStack(spacing: 0) {
                    MiniGlyph(symbol: "plus", help: "Add the album to Up Next", action: append)
                    MiniGlyph(symbol: "play.fill", help: "Play the album now (replaces Up Next)", action: play)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: play)
        .contextMenu {
            Button("Play Album", action: play)
            Button("Add Album to Up Next", action: append)
        }
        .help("Click to play the album — replaces Up Next")
        .task(id: album.id) {
            if let folder = await player.folder(of: album) { image = await art.thumbnail(for: folder) }
        }
    }
}

// MARK: rows

/// One song: cover thumbnail (from this Mac's cache only), title, artist — album, and length.
struct SongRow<Actions: View, Menu: View>: View {
    let song: MPDSong
    let art: ArtworkStore
    let accent: Color
    let isCurrent: Bool
    let playing: Bool
    let dimmed: Bool
    let action: () -> Void
    @ViewBuilder let actions: (Bool) -> Actions
    @ViewBuilder let menu: () -> Menu
    @Local private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Thumb(song: song, art: art)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    if isCurrent {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.5))
                            LevelBars(playing: playing, color: accent).frame(width: 14, height: 12)
                        }
                    }
                }
            VStack(alignment: .leading, spacing: 1.5) {
                Text(song.displayTitle)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? accent : Theme.text)
                    .lineLimit(1)
                Text(song.displayArtist + (song.album.map { " — \($0)" } ?? ""))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            actions(hovering)
            Text(song.duration.map(TimeText.clock) ?? "")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : (isCurrent ? Color.white.opacity(0.04) : .clear)))
        .opacity(dimmed && !hovering ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .contextMenu { menu() }
    }
}

struct Thumb: View {
    let song: MPDSong
    let art: ArtworkStore
    @Local private var image: NSImage? = nil

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                GeneratedCover(title: song.album ?? song.displayTitle, compact: true)
            }
        }
        .task(id: song.directory) { image = await art.thumbnail(for: song.directory) }
    }
}

/// Three little bars for the song that's playing; they rest when it's paused.
struct LevelBars: View {
    let playing: Bool
    let color: Color
    @Environment(\.panelActive) private var active

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !active || !playing)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = Double(i) * 1.9
                    let level = playing ? 0.35 + 0.65 * abs(sin(t * (2.2 + Double(i) * 0.7) + phase)) : [0.45, 0.8, 0.6][i]
                    Capsule().fill(color).frame(width: 3, height: max(2, 12 * level))
                }
            }
            .frame(height: 12, alignment: .bottom)
        }
    }
}

struct MiniGlyph: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Theme.text : Theme.muted)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.1 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct EmptyNote: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.muted.opacity(0.8))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text.opacity(0.9))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
