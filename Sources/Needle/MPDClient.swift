import Foundation

/// A self-healing command channel. It opens on first use and replaces a connection that has sat silent
/// for 30 s (MPD hangs up on clients silent for its connection_timeout, 60 s by default; the status
/// poll keeps the main channel busier than that, so in practice only the art channel is replaced); if a socket
/// still turns out dead, it reconnects and retries once — only on `.closed`, where MPD never read the
/// command, so nothing can run twice.
actor MPDClient {
    private(set) var host: String
    private(set) var port: UInt16
    private var password: String
    private var conn: MPDConnection?
    private var opening: Task<MPDConnection, Error>?
    private(set) var protocolVersion = ""

    init(host: String, port: UInt16, password: String = "") {
        self.host = host
        self.port = port
        self.password = password
    }

    func configure(host: String, port: UInt16, password: String) async {
        self.host = host
        self.port = port
        self.password = password
        await disconnect()
    }

    func disconnect() async {
        opening?.cancel()
        opening = nil
        let old = conn
        conn = nil
        await old?.close()
    }

    func run(_ command: String, timeout: TimeInterval = 6) async throws -> MPDReply {
        try await withRetry { try await $0.run(command, timeout: timeout) }
    }

    func runList(_ commands: [String], timeout: TimeInterval = 6) async throws -> [MPDReply] {
        try await withRetry { try await $0.runList(commands, timeout: timeout) }
    }

    private func withRetry<T>(_ body: (MPDConnection) async throws -> T) async throws -> T {
        let c = try await connection()
        do {
            return try await body(c)
        } catch MPDError.closed {
            conn = nil
            return try await body(try await connection())
        } catch let e as MPDError where e.isConnectionLevel {
            conn = nil
            throw e
        }
    }

    private func connection() async throws -> MPDConnection {
        if let c = conn, await c.isOpen {
            if await c.idleFor < 30 { return c }
            await c.close()   // MPD drops clients silent for 60 s; don't find out the hard way
            conn = nil
        }
        if let t = opening { return try await t.value }
        let (host, port, password) = (self.host, self.port, self.password)
        let task = Task { () throws -> MPDConnection in
            let c = MPDConnection(host: host, port: port)
            try await c.open()
            if !password.isEmpty { _ = try await c.run("password \(MPD.quote(password))") }
            _ = try? await c.run("binarylimit 1048576")   // bigger art chunks; servers before 0.22.4 refuse it, harmlessly
            return c
        }
        opening = task
        defer { opening = nil }
        let c = try await task.value
        conn = c
        protocolVersion = await c.protocolVersion
        return c
    }
}

// MARK: reading

extension MPDClient {
    /// Status and the current song in one round trip.
    func snapshot() async throws -> (MPDStatus, MPDSong?) {
        let r = try await runList(["status", "currentsong"])
        let song = r[1].pairs.isEmpty ? nil : MPDSong(pairs: r[1].pairs)
        return (MPDStatus(r[0]), song)
    }

    func status() async throws -> MPDStatus { MPDStatus(try await run("status")) }

    func queue() async throws -> [MPDSong] {
        try await run("playlistinfo", timeout: 20).records(startingAt: "file").map(MPDSong.init(pairs:))
    }

    /// Saved playlists with their size and length. `listplaylistinfo` reads the playlist file and the
    /// song database only — never the music drives.
    func playlists() async throws -> [PlaylistInfo] {
        let listing = try await run("listplaylists")
        let stamp = ISO8601DateFormatter()
        var out: [PlaylistInfo] = listing.records(startingAt: "playlist").map { rec in
            var p = PlaylistInfo(name: rec[0].value)
            p.modified = rec.first { $0.key == "Last-Modified" }.flatMap { stamp.date(from: $0.value) }
            return p
        }
        for i in out.indices {
            guard let songs = try? await playlistSongs(out[i].name) else { continue }
            out[i].count = songs.count
            out[i].duration = songs.reduce(0) { $0 + ($1.duration ?? 0) }
            var seen = Set<String>()
            out[i].directories = songs.map(\.directory).filter { seen.insert($0).inserted }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func playlistSongs(_ name: String) async throws -> [MPDSong] {
        try await run("listplaylistinfo \(MPD.quote(name))", timeout: 15).records(startingAt: "file").map(MPDSong.init(pairs:))
    }

    /// Every word must match some tag ("nick pink" finds Nick Drake's Pink Moon). Case-insensitive.
    func search(_ text: String, limit: Int) async throws -> [MPDSong] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let filter = words.map { "any \(MPD.quote($0))" }.joined(separator: " ")
        return try await run("search \(filter) window 0:\(limit)", timeout: 15).records(startingAt: "file").map(MPDSong.init(pairs:))
    }

    func stats() async throws -> MPDStats { MPDStats(try await run("stats")) }

    /// Songs for the search box: the songs of the artist the query names (LibraryIndex.likelyArtist),
    /// then titles containing the phrase. Both are quick tag lookups (~30 ms and ~500 ms on a 263,600-song library).
    func searchSongs(_ phrase: String, artist: String?, limit: Int) async throws -> [MPDSong] {
        var commands: [String] = []
        if let artist { commands.append("find artist \(MPD.quote(artist)) window 0:\(limit)") }
        commands.append("search title \(MPD.quote(phrase)) window 0:\(limit)")
        var seen = Set<String>()
        return try await runList(commands, timeout: 15)
            .flatMap { $0.records(startingAt: "file").map(MPDSong.init(pairs:)) }
            .filter { seen.insert($0.file).inserted }
    }

    /// The first song of an album, to find its folder (for a cached cover) — database only.
    func firstSong(of album: LibraryIndex.Album) async throws -> MPDSong? {
        let r = try await run("find album \(MPD.quote(album.title)) albumartist \(MPD.quote(album.artist)) window 0:1")
        return r.records(startingAt: "file").first.map(MPDSong.init(pairs:))
    }

    func songCount(artist: String) async throws -> Int {
        try await run("count artist \(MPD.quote(artist))", timeout: 15)["songs"].flatMap(Int.init) ?? 0
    }

    /// How many songs sit under a folder — asked before adding one, so a stray click on a song in
    /// a giant folder never queues half the library.
    func songCount(inFolder folder: String) async throws -> Int {
        let expr = "(base \(MPD.quote(folder)))"
        return try await run("count \(MPD.quote(expr))", timeout: 15)["songs"].flatMap(Int.init) ?? 0
    }
}

// MARK: playing

extension MPDClient {
    func play() async throws { _ = try await run("play") }
    func playId(_ id: Int) async throws { _ = try await run("playid \(id)") }
    func pause(_ on: Bool) async throws { _ = try await run("pause \(on ? 1 : 0)") }
    func stop() async throws { _ = try await run("stop") }
    func next() async throws { _ = try await run("next") }
    func previous() async throws { _ = try await run("previous") }
    func seek(to seconds: Double) async throws { _ = try await run(String(format: "seekcur %.2f", max(0, seconds))) }
    func setVolume(_ v: Int) async throws { _ = try await run("setvol \(max(0, min(100, v)))") }
    func setRandom(_ on: Bool) async throws { _ = try await run("random \(on ? 1 : 0)") }
    func remove(id: Int) async throws { _ = try await run("deleteid \(id)") }
    func enqueue(_ uri: String) async throws { _ = try await run("add \(MPD.quote(uri))") }

    /// Inserts `uri` right after the current song (`+0` is relative to it); returns the new song id.
    @discardableResult
    func insertAfterCurrent(_ uri: String, hasCurrent: Bool) async throws -> Int? {
        let r = try await run(hasCurrent ? "addid \(MPD.quote(uri)) +0" : "addid \(MPD.quote(uri))")
        return r["Id"].flatMap(Int.init)
    }

    func loadPlaylist(_ name: String, replace: Bool, shuffle: Bool) async throws {
        var cmds: [String] = []
        if replace { cmds.append("clear") }
        cmds.append("load \(MPD.quote(name))")
        if shuffle { cmds.append("shuffle") }
        if replace { cmds.append("play 0") }
        _ = try await runList(cmds)
    }

    func loadAlbum(_ album: LibraryIndex.Album, replace: Bool) async throws {
        let add = "findadd album \(MPD.quote(album.title)) albumartist \(MPD.quote(album.artist))"
        _ = try await runList(replace ? ["clear", add, "play 0"] : [add])
    }

    func loadArtist(_ artist: String, shuffle: Bool) async throws {
        var cmds = ["clear", "findadd artist \(MPD.quote(artist))"]
        if shuffle { cmds.append("shuffle") }
        cmds.append("play 0")
        _ = try await runList(cmds, timeout: 15)
    }

    func loadFolder(_ folder: String, replace: Bool) async throws {
        _ = try await runList(replace ? ["clear", "add \(MPD.quote(folder))", "play 0"] : ["add \(MPD.quote(folder))"])
    }
}
