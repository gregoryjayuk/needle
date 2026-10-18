import AppKit
import Combine
import Network

/// The server as the UI sees it: what is playing, the queue, the playlists, and every control.
///
/// Three channels to MPD: commands (MPDClient, self-healing), `idle` (MPD pushes "changed: player"
/// the moment anything happens, from any client — mpc on the server, ncmpcpp, the phone), and art
/// (ArtworkStore's own connection, so a big cover never delays a button). A slow status poll keeps
/// the clock honest and notices a server that has silently gone.
@MainActor
final class Player: ObservableObject {
    enum Link: Equatable {
        case connecting
        case online
        case offline(String)
        /// Not on the server's network: no retries on a timer until the network changes or the panel opens.
        case away
    }

    enum RepeatMode { case off, all, one }

    enum SearchState: Equatable {
        case idle
        case searching
        case done(Int)
        case failed(String)
    }

    static let searchLimit = 80

    @Published private(set) var link: Link = .connecting
    @Published private(set) var status = MPDStatus()
    @Published private(set) var song: MPDSong?
    @Published private(set) var queue: [MPDSong] = []
    @Published private(set) var playlists: [PlaylistInfo] = []
    @Published private(set) var stats: MPDStats?
    @Published private(set) var serverVersion = ""
    @Published private(set) var notice: String?
    @Published var searchText = "" { didSet { if searchText != oldValue { scheduleSearch() } } }
    @Published private(set) var searchResults: [MPDSong] = []
    @Published private(set) var searchArtists: [LibraryIndex.Artist] = []
    @Published private(set) var searchAlbums: [LibraryIndex.Album] = []
    @Published private(set) var searchState: SearchState = .idle
    /// Set when the volume is nudged from the menu bar, so the status item can show the level briefly.
    @Published private(set) var volumeNudgedAt: Date?

    let art: ArtworkStore
    let index = LibraryIndex()
    weak var nowPlaying: NowPlayingBridge?
    private(set) var fetchedAt = Date()
    private var client: MPDClient

    private var generation = 0
    private var connectTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var idleConnection: MPDConnection?
    private var backoff: TimeInterval = 1
    private var pathMonitor: NWPathMonitor?
    private var pathDebounce: Task<Void, Never>?
    private var wakeObserver: Any?
    private var queueDirty = true
    private var lastLoggedLink: Link?

    private var volumeTarget: Int?
    private var volumeTask: Task<Void, Never>?
    private var volumeBeforeMute: Int?
    /// MPD's PipeWire output reopens at 100 % when playback starts from stopped (seen 18 Oct 2026, and
    /// the amp is loud). When Needle starts playback, it re-applies the volume it had for a few seconds.
    private var holdVolume: (value: Int, until: Date)?

    var panelVisible = false {
        didSet { if panelVisible && !oldValue { panelOpened() } }
    }

    init(art: ArtworkStore) {
        self.art = art
        client = MPDClient(host: Settings.host, port: UInt16(Settings.port), password: Settings.password)
    }

    var isOnline: Bool { link == .online }
    var isPlaying: Bool { isOnline && status.state == .play }
    var hasSong: Bool { isOnline && song != nil }

    var duration: Double { status.duration > 0 ? status.duration : (song?.duration ?? 0) }

    func elapsed(at date: Date = Date()) -> Double {
        guard status.state == .play else { return status.elapsed }
        let e = status.elapsed + date.timeIntervalSince(fetchedAt)
        return duration > 0 ? min(e, duration) : e
    }

    func progress(at date: Date = Date()) -> Double {
        duration > 0 ? min(1, max(0, elapsed(at: date) / duration)) : 0
    }

    var repeatMode: RepeatMode { status.repeatOn ? (status.single ? .one : .all) : .off }

    var queueDuration: Double { queue.reduce(0) { $0 + ($1.duration ?? 0) } }

    // MARK: connection

    func start() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reconnect(reason: "wake") }
        }
        reconnect(reason: "launch")
    }

    /// Drops every channel and starts over — after a settings change, a wake, a network change, or "Retry".
    func reconnect(reason: String) {
        generation += 1
        let gen = generation
        teardown()
        // A background retry keeps showing why it is offline; anything else shows "Connecting…".
        if link != .online, reason != "retry" { link = .connecting }
        let host = Settings.host, port = Settings.port, password = Settings.password
        connectTask = Task { [weak self] in
            guard let self else { return }
            await self.client.configure(host: host, port: UInt16(port), password: password)
            do {
                let (st, sg) = try await self.client.snapshot()
                guard gen == self.generation else { return }
                self.serverVersion = await self.client.protocolVersion
                self.backoff = 1
                self.link = .online
                self.lastLoggedLink = .online
                Log.write("online (\(reason)): \(host):\(port), MPD \(self.serverVersion)")
                self.apply(st, sg)
                self.startIdle(gen, host: host, port: port, password: password)
                self.startPolling(gen)
                await self.refreshPlaylists()
                await self.refreshStats()
                if self.panelVisible { await self.refreshQueue() } else { self.queueDirty = true }
            } catch {
                guard gen == self.generation else { return }
                self.wentOffline(error, gen: gen)
            }
        }
    }

    func reconfigure() {
        art.reconfigure()
        link = .connecting
        song = nil
        queue = []
        playlists = []
        stats = nil
        searchResults = []
        searchArtists = []
        searchAlbums = []
        reconnect(reason: "settings")
    }

    private func teardown() {
        for t in [connectTask, idleTask, pollTask, retryTask] { t?.cancel() }
        connectTask = nil
        idleTask = nil
        pollTask = nil
        retryTask = nil
        let idle = idleConnection
        idleConnection = nil
        Task { await idle?.close() }
    }

    private func wentOffline(_ error: Error, gen: Int) {
        guard gen == generation else { return }
        generation += 1
        let next = generation
        teardown()
        let message = error.localizedDescription
        let away = !LAN.isLocal(Settings.host)
        let newLink: Link = away ? .away : .offline(message)
        if newLink != lastLoggedLink {   // once per new reason, not once per retry
            Log.write(away ? "away from \(Settings.host)'s network" : "offline: \(message)")
            lastLoggedLink = newLink
        }
        link = newLink
        nowPlaying?.clear()
        if !away { scheduleRetry(next) }
    }

    private func scheduleRetry(_ gen: Int) {
        let delay = backoff
        backoff = min(backoff * 2, 30)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.reconnect(reason: "retry")
        }
    }

    private func networkChanged() {
        pathDebounce?.cancel()
        pathDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.isOnline { await self.verify() } else { self.backoff = 1; self.reconnect(reason: "network") }
        }
    }

    /// A quick status: if it fails, we were holding a dead socket.
    private func verify() async {
        let gen = generation
        do { applyStatus(try await client.status()) } catch { wentOffline(error, gen: gen) }
    }

    private func startIdle(_ gen: Int, host: String, port: Int, password: String) {
        idleTask = Task { [weak self] in
            let conn = MPDConnection(host: host, port: UInt16(port))
            self?.idleConnection = conn
            do {
                try await conn.open()
                if !password.isEmpty { _ = try await conn.run("password \(MPD.quote(password))") }
                while !Task.isCancelled {
                    let r = try await conn.run("idle database stored_playlist playlist player mixer options", timeout: .infinity)
                    guard let self, gen == self.generation else { return }
                    await self.changed(Set(r.all("changed")), gen: gen)
                }
            } catch {
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                Log.write("idle channel: \(error.localizedDescription)")
                self.wentOffline(error, gen: gen)
            }
        }
    }

    private func startPolling(_ gen: Int) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let wait: Double = (self?.panelVisible ?? false) ? 5 : 20
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                do { self.applyStatus(try await self.client.status()) } catch {
                    self.wentOffline(error, gen: gen)
                    return
                }
            }
        }
    }

    private func changed(_ what: Set<String>, gen: Int) async {
        do {
            if !what.isDisjoint(with: ["player", "playlist", "mixer", "options"]) {
                let (st, sg) = try await client.snapshot()
                guard gen == generation else { return }
                apply(st, sg)
            }
            if what.contains("playlist") {
                if panelVisible { await refreshQueue() } else { queueDirty = true }
            }
            if what.contains("stored_playlist") { await refreshPlaylists() }
            if what.contains("database") { await refreshStats() }
        } catch {
            wentOffline(error, gen: gen)
        }
    }

    private func panelOpened() {
        switch link {
        case .online:
            Task {
                await verify()
                if queueDirty { await refreshQueue() }
            }
        case .connecting:
            break
        case .offline, .away:
            backoff = 1
            reconnect(reason: "panel")
        }
    }

    // MARK: applying replies

    private func apply(_ st: MPDStatus, _ sg: MPDSong?) {
        if song != sg { song = sg }
        applyStatus(st)
    }

    private func applyStatus(_ incoming: MPDStatus) {
        var st = incoming
        if let target = volumeTarget { st.volume = target }   // a reply from before the slider moved
        if let hold = holdVolume {
            if Date() > hold.until {
                holdVolume = nil
            } else if st.state == .play, st.volume >= 0, st.volume != hold.value {
                Log.write("volume reopened at \(st.volume); putting back \(hold.value)")
                st.volume = hold.value
                Task { try? await client.setVolume(hold.value) }
            }
        }
        fetchedAt = Date()
        if status != st { status = st }
        art.show(song, playing: st.state == .play)
        nowPlaying?.update(song: song, status: st, elapsed: elapsed(), art: art.current)
    }

    func refreshQueue() async {
        guard isOnline else { return }
        do {
            queue = try await client.queue()
            queueDirty = false
        } catch {
            note(error)
        }
    }

    func refreshPlaylists() async {
        guard isOnline, let p = try? await client.playlists() else { return }
        if playlists != p { playlists = p }
    }

    private func refreshStats() async {
        guard isOnline, let s = try? await client.stats() else { return }
        stats = s
        if let stamp = s.dbUpdate?.timeIntervalSince1970 {
            await index.refresh(using: client, host: Settings.host, stamp: stamp)
            if !searchText.isEmpty { scheduleSearch() }
        }
    }

    // MARK: controls

    func togglePlay() {
        switch status.state {
        case .play:
            status.elapsed = elapsed()
            status.state = .pause
            perform { try await $0.pause(true) }
        case .pause:
            fetchedAt = Date()
            status.state = .play
            perform { try await $0.pause(false) }
        case .stop:
            startPlayback { try await $0.play() }
        }
        refreshDerived()
    }

    func play() { if status.state != .play { togglePlay() } }
    func pause() { if status.state == .play { togglePlay() } }
    func next() { perform { try await $0.next() } }

    /// Like a CD player: back to the start of the song, unless we are in its first few seconds.
    func previous() {
        if elapsed() > 4 { seek(to: 0) } else { perform { try await $0.previous() } }
    }

    func seek(to seconds: Double) {
        status.elapsed = max(0, min(seconds, duration))
        fetchedAt = Date()
        perform { try await $0.seek(to: seconds) }
        refreshDerived()
    }

    func setVolume(_ value: Int) {
        let v = max(0, min(100, value))
        guard isOnline, status.volume >= 0 else { return }
        volumeTarget = v
        status.volume = v
        holdVolume = nil
        guard volumeTask == nil else { return }   // the sender picks up the newest target when it's done
        volumeTask = Task { [weak self] in
            var sent: Int?
            while let self, let target = self.volumeTarget, target != sent {
                do { try await self.client.setVolume(target) } catch {
                    self.note(error)
                    break
                }
                sent = target
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            self?.volumeTarget = nil
            self?.volumeTask = nil
        }
    }

    func nudgeVolume(by delta: Int) {
        guard status.volume >= 0 else { return }
        setVolume((volumeTarget ?? status.volume) + delta)
        volumeNudgedAt = Date()
    }

    func toggleMute() {
        if status.volume > 0 {
            volumeBeforeMute = status.volume
            setVolume(0)
        } else {
            setVolume(volumeBeforeMute ?? 50)
        }
    }

    func toggleRandom() {
        status.random.toggle()
        let on = status.random
        perform { try await $0.setRandom(on) }
    }

    func cycleRepeat() {
        let cmds: [String]
        switch repeatMode {
        case .off: cmds = ["repeat 1", "single 0"]; status.repeatOn = true; status.single = false
        case .all: cmds = ["repeat 1", "single 1"]; status.single = true
        case .one: cmds = ["repeat 0", "single 0"]; status.repeatOn = false; status.single = false
        }
        perform { _ = try await $0.runList(cmds) }
    }

    func playQueued(_ song: MPDSong) {
        guard let id = song.songId else { return }
        startPlayback { try await $0.playId(id) }
    }

    func removeQueued(_ song: MPDSong) {
        guard let id = song.songId else { return }
        queue.removeAll { $0.songId == id }
        perform { try await $0.remove(id: id) }
    }

    func playPlaylist(_ name: String, shuffle: Bool = false) {
        startPlayback { try await $0.loadPlaylist(name, replace: true, shuffle: shuffle) }
    }

    func appendPlaylist(_ name: String) {
        perform { try await $0.loadPlaylist(name, replace: false, shuffle: false) }
        flash("Added \(PlaylistInfo(name: name).displayName) to the queue")
    }

    /// Plays a song now without losing the queue: it goes in right after the current song.
    func playNow(_ song: MPDSong) {
        let hasCurrent = status.songPos != nil
        startPlayback { c in
            if let id = try await c.insertAfterCurrent(song.file, hasCurrent: hasCurrent) { try await c.playId(id) }
        }
    }

    func playNext(_ song: MPDSong) {
        let hasCurrent = status.songPos != nil
        perform { try await $0.insertAfterCurrent(song.file, hasCurrent: hasCurrent) }
        flash("“\(song.displayTitle)” plays next")
    }

    func enqueue(_ song: MPDSong) {
        perform { try await $0.enqueue(song.file) }
        flash("Added “\(song.displayTitle)” to the queue")
    }

    /// The song's folder is its album in this library. Refuses folders of more than 150 songs.
    func playAlbum(of song: MPDSong, replace: Bool) {
        let folder = song.directory
        guard !folder.isEmpty else { return }
        let label = song.album ?? (folder as NSString).lastPathComponent
        startPlayback(holdingVolume: replace) { [weak self] c in
            let n = (try? await c.songCount(inFolder: folder)) ?? 0
            guard n <= 150 else {
                await self?.flash("That folder holds \(n) songs — too many to add at once")
                return
            }
            try await c.loadFolder(folder, replace: replace)
            if !replace { await self?.flash("Added \(label) to the queue") }
        }
    }

    // MARK: search

    /// Artists and albums answer at once from the local index; songs follow from the server a moment
    /// later. Only when neither finds anything does it fall back to MPD's slow everything-search.
    private func scheduleSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else {
            searchResults = []
            searchArtists = []
            searchAlbums = []
            searchState = .idle
            return
        }
        let local = index.search(q)
        searchArtists = local.artists
        searchAlbums = local.albums
        searchState = .searching
        let artist = index.likelyArtist(q)
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let self, !Task.isCancelled else { return }
            do {
                var found = try await self.client.searchSongs(q, artist: artist, limit: Player.searchLimit)
                if found.isEmpty, local.artists.isEmpty, local.albums.isEmpty {
                    found = try await self.client.search(q, limit: Player.searchLimit)
                }
                guard !Task.isCancelled, q == self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                self.searchResults = found
                self.searchState = .done(found.count)
            } catch {
                guard !Task.isCancelled else { return }
                self.searchState = .failed(error.localizedDescription)
            }
        }
    }

    func playAlbum(_ album: LibraryIndex.Album, replace: Bool) {
        startPlayback(holdingVolume: replace) { try await $0.loadAlbum(album, replace: replace) }
        if !replace { flash("Added \(album.title) to the queue") }
    }

    /// Everything by an artist, shuffled — refused past 600 songs.
    func shuffleArtist(_ name: String) {
        startPlayback { [weak self] c in
            let n = try await c.songCount(artist: name)
            guard n <= 600 else {
                await self?.flash("\(name) has \(n) songs — too many to queue at once")
                return
            }
            try await c.loadArtist(name, shuffle: true)
        }
    }

    private var albumFolders: [String: String] = [:]

    /// An album's folder, for its cached cover: one database lookup, remembered.
    func folder(of album: LibraryIndex.Album) async -> String? {
        if let f = albumFolders[album.id] { return f }
        guard isOnline, let song = try? await client.firstSong(of: album) else { return nil }
        albumFolders[album.id] = song.directory
        return song.directory
    }

    // MARK: plumbing

    private func perform(_ op: @escaping (MPDClient) async throws -> Void) {
        guard isOnline else {
            reconnect(reason: "command while offline")
            return
        }
        let client = self.client
        Task { [weak self] in
            do { try await op(client) } catch { self?.note(error) }
        }
    }

    /// For anything that may start playback from stopped: holds the current volume (see `holdVolume`).
    private func startPlayback(holdingVolume: Bool = true, _ op: @escaping (MPDClient) async throws -> Void) {
        if holdingVolume, Settings.keepVolume, status.volume >= 0 {
            holdVolume = (status.volume, Date().addingTimeInterval(6))
        }
        perform(op)
    }

    private func note(_ error: Error) {
        if let e = error as? MPDError, e.isConnectionLevel {
            wentOffline(error, gen: generation)
        } else {
            Log.write("command refused: \(error.localizedDescription)")
            flash(error.localizedDescription)
        }
    }

    func flash(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func refreshDerived() {
        nowPlaying?.update(song: song, status: status, elapsed: elapsed(), art: art.current)
    }
}
