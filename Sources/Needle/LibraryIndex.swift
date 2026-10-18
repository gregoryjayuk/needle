import Foundation

/// Every album and album-artist in the library, held on the Mac so search can answer them as you type.
///
/// MPD's own `search any` takes ~2 s over a 263,600-song library and ranks badly ("nick drake" put
/// Drake ft. Nicki Minaj first). `list album group albumartist` is ~200 ms and ~1.5 MB, from the song
/// database only (no drive is touched), so it is fetched once, cached on disk, and refetched only
/// when MPD's `db_update` stamp changes.
@MainActor
final class LibraryIndex {
    struct Album: Hashable, Identifiable, Codable {
        let title: String
        let artist: String
        var id: String { artist + "\u{1F}" + title }
    }

    struct Artist: Hashable, Identifiable {
        let name: String
        let albums: Int
        var id: String { name }
    }

    private struct Entry {
        let album: Album
        let titleKey: String
        let artistKey: String
        let key: String
    }

    private struct Cache: Codable {
        let host: String
        let stamp: Double
        let albums: [Album]
    }

    private(set) var stamp: Double = 0
    private var entries: [Entry] = []
    private var artists: [(artist: Artist, key: String)] = []
    private let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.greggaynor.needle/library-index.json")

    var isEmpty: Bool { entries.isEmpty }
    var albumCount: Int { entries.count }

    /// Brings the index up to date with the server's database stamp: from the disk cache if it matches,
    /// otherwise from MPD.
    func refresh(using client: MPDClient, host: String, stamp: Double) async {
        if stamp == self.stamp, !entries.isEmpty { return }
        let url = cacheURL
        let cached: Cache? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Cache.self, from: data)
        }.value
        if let cached, cached.host == host, cached.stamp == stamp {
            install(cached.albums, stamp: stamp)
            return
        }
        guard let reply = try? await client.run("list album group albumartist", timeout: 30) else { return }
        var albums: [Album] = []
        albums.reserveCapacity(reply.pairs.count)
        var artist = ""
        for (key, value) in reply.pairs {
            if key == "AlbumArtist" { artist = value } else if key == "Album", !value.isEmpty { albums.append(Album(title: value, artist: artist)) }
        }
        install(albums, stamp: stamp)
        let cache = Cache(host: host, stamp: stamp, albums: albums)
        Task.detached(priority: .background) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(cache) { try? data.write(to: url, options: .atomic) }
        }
        Log.write("library index: \(albums.count) albums")
    }

    private func install(_ albums: [Album], stamp: Double) {
        self.stamp = stamp
        entries = albums.map { a in
            let t = LibraryIndex.fold(a.title), r = LibraryIndex.fold(a.artist)
            return Entry(album: a, titleKey: t, artistKey: r, key: t + " " + r)
        }
        var counts: [String: Int] = [:]
        for a in albums where !a.artist.isEmpty { counts[a.artist, default: 0] += 1 }
        artists = counts.map { (Artist(name: $0.key, albums: $0.value), LibraryIndex.fold($0.key)) }
    }

    /// Artists and albums where every word of the query appears; exact and leading matches first.
    func search(_ query: String, artistLimit: Int = 3, albumLimit: Int = 6) -> (artists: [Artist], albums: [Album]) {
        let phrase = LibraryIndex.fold(query)
        let words = phrase.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return ([], []) }

        var foundArtists: [(Artist, Int)] = []
        for (artist, key) in artists where words.allSatisfy({ key.contains($0) }) {
            foundArtists.append((artist, LibraryIndex.score(key, phrase: phrase, words: words) + min(artist.albums, 20)))
        }
        var foundAlbums: [(Album, Int)] = []
        for e in entries where words.allSatisfy({ e.key.contains($0) }) {
            var s = LibraryIndex.score(e.titleKey, phrase: phrase, words: words)
            if e.artistKey == phrase { s += 70 } else if e.artistKey.hasPrefix(phrase) { s += 25 }
            foundAlbums.append((e.album, s))
        }
        let a = foundArtists.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }.prefix(artistLimit).map(\.0)
        let b = foundAlbums.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title < $1.0.title }.prefix(albumLimit).map(\.0)
        return (Array(a), Array(b))
    }

    /// The artist a query most plausibly names, whose songs lead the results: an exact name, else one
    /// where the query starts a word ("joni" → Joni Mitchell), preferring a match at the very start,
    /// then the artist with more albums. Needs three letters before guessing.
    func likelyArtist(_ query: String) -> String? {
        let phrase = LibraryIndex.fold(query)
        if let exact = artists.first(where: { $0.key == phrase }) { return exact.artist.name }
        guard phrase.count >= 3 else { return nil }
        var best: (name: String, rank: Int)?
        for (artist, key) in artists {
            let atStart = key.hasPrefix(phrase)
            guard atStart || key.contains(" " + phrase) else { continue }
            let rank = (atStart ? 100_000 : 0) + artist.albums * 10 - key.count
            if best == nil || rank > best!.rank { best = (artist.name, rank) }
        }
        return best?.name
    }

    private static func score(_ text: String, phrase: String, words: [String]) -> Int {
        var s = 0
        if text == phrase { s += 100 } else if text.hasPrefix(phrase) { s += 60 } else if text.contains(phrase) { s += 30 }
        for w in words where text.hasPrefix(w) || text.contains(" " + w) { s += 8 }
        return s > 0 ? s - text.count / 6 : 0   // shorter wins only among real title matches
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
