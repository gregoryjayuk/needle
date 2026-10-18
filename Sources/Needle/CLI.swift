import AppKit

/// `Needle <command>`: the same controls from a terminal or a hotkey, straight to MPD (no app needed).
/// Installed as `needle` in ~/.local/bin.
@MainActor
enum CLI {
    static func run(_ args: [String]) async -> Int32 {
        let client = MPDClient(host: Settings.host, port: UInt16(Settings.port), password: Settings.password)
        let rest = Array(args.dropFirst())
        do {
            switch args[0] {
            case "status", "st":
                print(try await describe(client))
            case "toggle", "tog":
                let s = try await client.status()
                if s.state == .play { try await client.pause(true) } else if s.state == .pause { try await client.pause(false) } else { try await client.play() }
                print(try await describe(client))
            case "play":
                try await client.play()
            case "pause":
                try await client.pause(true)
            case "stop":
                try await client.stop()
            case "next":
                try await client.next()
                print(try await describe(client))
            case "prev", "previous":
                try await client.previous()
                print(try await describe(client))
            case "vol", "volume":
                let s = try await client.status()
                guard let arg = rest.first else {
                    print(s.volume)
                    return 0
                }
                let base = s.volume
                let target: Int
                if arg.hasPrefix("+") || arg.hasPrefix("-") { target = base + (Int(arg) ?? 0) } else { target = Int(arg) ?? base }
                try await client.setVolume(target)
                print(max(0, min(100, target)))
            case "playlists", "lists":
                for p in try await client.playlists() {
                    let length = p.duration.map { " · " + TimeText.span($0) } ?? ""
                    print("\(p.name)\t\(p.count ?? 0) songs\(length)")
                }
            case "load":
                guard let name = rest.first(where: { !$0.hasPrefix("--") }) else { return usage() }
                try await client.loadPlaylist(name, replace: true, shuffle: rest.contains("--shuffle"))
                print(try await describe(client))
            case "search", "find":
                let words = rest.joined(separator: " ")
                guard !words.isEmpty else { return usage() }
                for s in try await client.search(words, limit: 40) {
                    print("\(s.displayArtist) — \(s.displayTitle)\(s.album.map { " (\($0))" } ?? "")\t\(s.file)")
                }
            case "show":
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.greggaynor.needle").first else {
                    FileHandle.standardError.write(Data("Needle is not running\n".utf8))
                    return 1
                }
                kill(app.processIdentifier, SIGUSR1)
            case "probe":
                try await probe(client)
            case "selftest":
                return await SelfTest.run()
            case "help", "-h", "--help":
                return usage(code: 0)
            default:
                return usage()
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("needle: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static func describe(_ client: MPDClient) async throws -> String {
        let (s, song) = try await client.snapshot()
        let mark: String
        switch s.state {
        case .play: mark = "▶"
        case .pause: mark = "⏸"
        case .stop: mark = "■"
        }
        guard let song else { return "\(mark) nothing queued · volume \(s.volume)" }
        var line = "\(mark) \(song.displayArtist) — \(song.displayTitle)"
        if s.duration > 0 { line += "  \(TimeText.clock(s.elapsed))/\(TimeText.clock(s.duration))" }
        line += " · volume \(s.volume)"
        if let p = s.lastLoadedPlaylist { line += " · \(p)" }
        return line
    }

    /// Read-only health check: every read path the app uses, timed. Art only if a song is playing
    /// (that drive is awake already).
    static func probe(_ client: MPDClient) async throws {
        func timed<T>(_ label: String, _ body: () async throws -> T) async throws -> T {
            let t0 = Date()
            let out = try await body()
            print(String(format: "  %-26@ %6.0f ms", label as NSString, Date().timeIntervalSince(t0) * 1000))
            return out
        }
        print("server \(Settings.host):\(Settings.port)  (on its subnet: \(LAN.isLocal(Settings.host)))")
        let (status, song) = try await timed("connect + status/song") { try await client.snapshot() }
        print("  protocol \(await client.protocolVersion) · state \(status.state.rawValue) · volume \(status.volume) · \(status.audioDescription ?? "-")")
        if let song { print("  now: \(song.displayArtist) — \(song.displayTitle) [\(song.fileKind)]") }
        let queue = try await timed("playlistinfo") { try await client.queue() }
        print("  queue: \(queue.count) songs")
        let lists = try await timed("playlists (+ info each)") { try await client.playlists() }
        print("  playlists: " + lists.map { "\($0.name) (\($0.count ?? 0))" }.joined(separator: ", "))
        let found = try await timed("search \"nick drake\"") { try await client.search("nick drake", limit: 10) }
        print("  search: \(found.count) results, first: \(found.first.map { $0.displayTitle } ?? "-")")
        let stats = try await timed("stats") { try await client.stats() }
        print("  library: \(stats.songs) songs, \(stats.albums) albums")
        if let song, status.state == .play {
            let data = try await timed("cover art (playing song)") { try await ArtworkStore.fetch(song.file, from: client) }
            print("  art: \(data.map { "\($0.count) bytes" } ?? "none")")
        } else {
            print("  art: skipped — nothing playing, and asking would wake a sleeping drive")
        }
    }

    @discardableResult
    static func usage(code: Int32 = 2) -> Int32 {
        print("""
        needle — control the music server (\(Settings.host):\(Settings.port)) from the terminal
          status            what's playing          toggle | play | pause | stop | next | prev
          vol [N|+N|-N]     show or set the volume  playlists        saved playlists
          load NAME [--shuffle]   replace the queue with a playlist and play it
          search WORDS      find songs              show             open the menu-bar panel
          probe             timed read-only health check of every path the app uses
        server: NEEDLE_HOST / MPD_HOST and NEEDLE_PORT / MPD_PORT override the app's setting
        """)
        return code
    }
}
