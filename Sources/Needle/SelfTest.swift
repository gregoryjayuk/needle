import Foundation

/// `Needle selftest` — drives the real Player through every control against scripts/mock-mpd.py and
/// checks what the server ends up doing. Refuses to run against anything but 127.0.0.1, so it can
/// never touch real music.
@MainActor
enum SelfTest {
    private static var failures = 0

    static func run() async -> Int32 {
        guard Settings.host == "127.0.0.1" else {
            print("selftest runs only against the mock: NEEDLE_HOST=127.0.0.1 NEEDLE_PORT=6601 (scripts/mock-mpd.py)")
            return 2
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("needle-selftest-\(getpid())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let art = ArtworkStore(cacheDirectory: scratch)   // a cold cache, so every cover is really fetched
        let player = Player(art: art)
        let probe = MPDClient(host: Settings.host, port: UInt16(Settings.port))
        player.start()

        await check("connects and goes online") { player.isOnline }
        _ = try? await probe.run("setvol 70")
        _ = try? await probe.runList(["clear", "load slow-evening", "play 1"])
        await check("follows a change made by another client (idle push)") { player.song?.displayTitle == "Northern Sky" }
        await check("cover art arrives for the playing song, with a palette") { art.current != nil }
        await check("the volume quirk (snap to 100 on play-from-stop) is NOT undone for another client's play") {
            (try? await probe.status().volume) == 100
        }
        _ = try? await probe.run("setvol 60")
        await check("volume change from elsewhere shows up") { player.status.volume == 60 }

        player.togglePlay()
        await check("pause") { (try? await probe.status().state) == .pause }
        player.togglePlay()
        await check("resume") { (try? await probe.status().state) == .play }

        let before = player.song?.file
        player.next()
        await check("next") { player.song?.file != before && player.song != nil }
        player.previous()
        await check("previous (at the start of a song it goes back a song)") { player.song?.file == before }

        player.seek(to: 100)
        await check("seek") { abs(((try? await probe.status().elapsed) ?? 0) - 100) < 3 }
        player.previous()
        await check("previous past 4 s restarts the song") { ((try? await probe.status().elapsed) ?? 99) < 3 && player.song?.file == before }

        for v in [55, 50, 45, 40, 35] { player.setVolume(v) }
        await check("volume drag sends the last value") { (try? await probe.status().volume) == 35 }
        player.toggleMute()
        await check("mute") { (try? await probe.status().volume) == 0 }
        player.toggleMute()
        await check("unmute restores the level") { (try? await probe.status().volume) == 35 }

        player.cycleRepeat()
        await check("repeat → one song") { player.repeatMode == .one }
        player.cycleRepeat()
        await check("repeat → off") { player.repeatMode == .off }
        player.cycleRepeat()
        await check("repeat → all") { player.repeatMode == .all }
        player.toggleRandom()
        await check("shuffle on") { (try? await probe.status().random) == true }
        player.toggleRandom()
        await check("shuffle off") { (try? await probe.status().random) == false }

        _ = try? await probe.run("stop")
        await check("stopped") { player.status.state == .stop }
        player.playPlaylist("mellow")
        await check("playlist starts (replacing the queue)") {
            let s = try? await probe.status()
            return s?.state == .play && s?.lastLoadedPlaylist == "mellow"
        }
        try? await Task.sleep(nanoseconds: 2_600_000_000)   // the mock snaps the volume to 100 at +1.5 s
        await check("…and the volume Needle had is put back after the stream reopens at 100") { (try? await probe.status().volume) == 35 }

        player.panelVisible = true
        await check("queue loads when the panel opens") { player.queue.count == 13 }
        player.searchText = "drake"
        await check("search: artists and albums from the local index") { !player.searchArtists.isEmpty && !player.searchAlbums.isEmpty }
        await check("search: songs from the server") { player.searchResults.count >= 10 }
        player.searchText = "joni mitchell"
        await check("search: an exact artist lists their songs first") { player.searchResults.first?.artist == "Joni Mitchell" }

        let pick = player.searchResults.first { $0.title == "River" }
        if let pick {
            let length = player.queue.count
            player.playNow(pick)
            await check("play now: inserted after the current song and playing") {
                player.song?.title == "River" && player.queue.count == length + 1
            }
            player.playNext(pick)
            await check("play next: queued right after the current song") {
                guard let pos = player.status.songPos, pos + 1 < player.queue.count else { return false }
                return player.queue[pos + 1].title == "River"
            }
            player.enqueue(pick)
            await check("add to queue: at the end") { player.queue.last?.title == "River" }
            if let id = player.queue.last?.songId, let last = player.queue.last {
                _ = id
                player.removeQueued(last)
                await check("remove from queue") { player.queue.count == length + 2 }
            }
        } else {
            fail("search did not return River")
        }

        if let album = player.searchAlbums.first {
            player.playAlbum(album, replace: true)
            await check("play album: the queue is that album") { player.queue.allSatisfy { $0.album == album.title } && !player.queue.isEmpty }
        }

        let folder = player.song?.directory ?? ""
        let folderCount = player.queue.count
        if let song = player.song {
            player.playAlbum(of: song, replace: false)
            await check("add album by folder") { player.queue.count == folderCount * 2 && !folder.isEmpty }
        }

        // Cover art after the art connection has sat silent past the server's connection_timeout
        // (run the mock with a short one: `mock-mpd.py 6603 2`). On 18 Oct every such fetch failed once
        // with "Socket is not connected".
        // Two songs from two albums, found by album name so the check works whatever the mock's folders are.
        func firstSong(of album: String) async -> MPDSong? {
            (try? await probe.run("find album \(MPD.quote(album)) window 0:1"))?.records(startingAt: "file").first.map(MPDSong.init(pairs:))
        }
        if let one = await firstSong(of: "Bryter Layter"), let two = await firstSong(of: "Heaven or Las Vegas") {
            _ = try? await probe.runList(["clear", "add \(MPD.quote(one.file))", "add \(MPD.quote(two.file))", "play 0"])
            await check("cover for the first album") { art.current?.key == one.directory }
            let silence = Double(ProcessInfo.processInfo.environment["NEEDLE_SILENCE"] ?? "") ?? 4
            try? await Task.sleep(nanoseconds: UInt64(silence * 1_000_000_000))
            let failedBefore = art.failedFetches
            _ = try? await probe.run("next")
            await check("cover after a silent spell arrives first time (no stale-socket failure)") {
                art.current?.key == two.directory && art.failedFetches == failedBefore
            }
        } else {
            fail("the mock's library has Bryter Layter and Heaven or Las Vegas")
        }

        print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
        if failures > 0 {
            // Let anything still stuck reach its deadline, so its error lands in ~/Library/Logs/needle.log.
            try? await Task.sleep(nanoseconds: 8_000_000_000)
        }
        return failures == 0 ? 0 : 1
    }

    private static func check(_ label: String, timeout: TimeInterval = 4, _ condition: @MainActor () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                print("  ✓ \(label)")
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        fail(label)
    }

    private static func fail(_ label: String) {
        failures += 1
        print("  ✗ \(label)")
    }
}
