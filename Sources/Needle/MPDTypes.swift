import Foundation

/// A song as MPD describes it: from `currentsong`, `playlistinfo`, `search` or `listplaylistinfo`.
struct MPDSong: Identifiable, Hashable {
    var file: String
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var date: String?
    var genre: String?
    var track: String?
    var duration: Double?
    var format: String?
    var pos: Int?
    var songId: Int?

    /// Queue entries are unique by MPD's song id; search results (no id) by file.
    var id: String { songId.map { "id:\($0)" } ?? "file:\(file)" }

    init(file: String) { self.file = file }

    init(pairs: [MPDPair]) {
        file = ""
        for (key, value) in pairs {
            switch key {
            case "file": file = value
            case "Title": title = title ?? value
            case "Artist": artist = artist ?? value
            case "AlbumArtist": albumArtist = albumArtist ?? value
            case "Album": album = album ?? value
            case "Date": date = date ?? value
            case "Genre": genre = genre ?? value
            case "Track": track = track ?? value
            case "duration": duration = Double(value)
            case "Time": if duration == nil { duration = Double(value) }
            case "Format": format = value
            case "Pos": pos = Int(value)
            case "Id": songId = Int(value)
            default: break
            }
        }
    }

    /// The Title tag, or the file name with its track number and extension stripped.
    var displayTitle: String {
        if let t = title?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
        var name = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        if let r = name.range(of: #"^[\d\s.\-_]+"#, options: .regularExpression), r.upperBound < name.endIndex {
            name = String(name[r.upperBound...])
        }
        return name
    }

    var displayArtist: String {
        if let a = artist?.trimmingCharacters(in: .whitespaces), !a.isEmpty { return a }
        if let a = albumArtist?.trimmingCharacters(in: .whitespaces), !a.isEmpty { return a }
        return "Unknown artist"
    }

    /// The folder the song lives in: the album, in this library. Art is cached per folder.
    var directory: String { (file as NSString).deletingLastPathComponent }

    var year: String? {
        guard let d = date, d.count >= 4 else { return nil }
        let y = String(d.prefix(4))
        return Int(y) != nil ? y : nil
    }

    /// "MP3", "FLAC"… from the extension; a cue-sheet track reports its sheet's audio file type as "CUE".
    var fileKind: String {
        let parts = file.split(separator: "/")
        if parts.dropLast().last.map({ $0.lowercased().hasSuffix(".cue") }) == true { return "CUE" }
        let ext = (file as NSString).pathExtension.lowercased()
        switch ext {
        case "m4a", "mp4": return "AAC"
        case "": return ""
        default: return ext.uppercased()
        }
    }
}

struct MPDStatus: Equatable {
    enum State: String { case play, pause, stop }

    var state: State = .stop
    var volume = -1
    var repeatOn = false
    var random = false
    var single = false
    var consume = false
    var songPos: Int?
    var songId: Int?
    var nextSongId: Int?
    var elapsed: Double = 0
    var duration: Double = 0
    var playlistLength = 0
    var bitrate: Int?
    var audio: String?
    var lastLoadedPlaylist: String?
    var updatingDB = false
    var error: String?

    init() {}

    init(_ reply: MPDReply) {
        for (key, value) in reply.pairs {
            switch key {
            case "state": state = State(rawValue: value) ?? .stop
            case "volume": volume = Int(value) ?? -1
            case "repeat": repeatOn = value == "1"
            case "random": random = value == "1"
            case "single": single = value == "1" || value == "oneshot"
            case "consume": consume = value == "1" || value == "oneshot"
            case "song": songPos = Int(value)
            case "songid": songId = Int(value)
            case "nextsongid": nextSongId = Int(value)
            case "elapsed": elapsed = Double(value) ?? 0
            case "duration": duration = Double(value) ?? 0
            case "time":
                // Older servers: "elapsed:total" in whole seconds.
                let p = value.split(separator: ":")
                if p.count == 2, duration == 0 { duration = Double(p[1]) ?? 0 }
            case "playlistlength": playlistLength = Int(value) ?? 0
            case "bitrate": bitrate = Int(value).flatMap { $0 > 0 ? $0 : nil }
            case "audio": audio = value
            case "lastloadedplaylist": lastLoadedPlaylist = value.isEmpty ? nil : value
            case "updating_db": updatingDB = true
            case "error": error = value
            default: break
            }
        }
    }

    /// "44.1 kHz · 16-bit" from MPD's "44100:16:2".
    var audioDescription: String? {
        guard let audio else { return nil }
        let p = audio.split(separator: ":").map(String.init)
        guard p.count >= 2 else { return nil }
        var out: [String] = []
        if let rate = Double(p[0]) {
            let khz = rate / 1000
            out.append(khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz))
        } else if p[0].hasPrefix("dsd") {
            out.append(p[0].uppercased())
        }
        if p[1] == "f" { out.append("32-bit float") } else if let bits = Int(p[1]) { out.append("\(bits)-bit") }
        return out.joined(separator: " · ")
    }

    /// Above CD quality: more than 16 bits or more than 48 kHz.
    var isHiRes: Bool {
        guard let audio else { return false }
        let p = audio.split(separator: ":")
        guard p.count >= 2 else { return false }
        let rate = Double(p[0]) ?? 0
        let bits = p[1] == "f" ? 32 : (Int(p[1]) ?? 0)
        return bits > 16 || rate > 48000
    }
}

struct MPDStats: Equatable {
    var songs = 0
    var artists = 0
    var albums = 0
    var uptime: TimeInterval = 0
    var dbUpdate: Date?

    init(_ reply: MPDReply) {
        songs = reply["songs"].flatMap(Int.init) ?? 0
        artists = reply["artists"].flatMap(Int.init) ?? 0
        albums = reply["albums"].flatMap(Int.init) ?? 0
        uptime = reply["uptime"].flatMap(Double.init) ?? 0
        dbUpdate = reply["db_update"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
    }
}

/// A saved playlist, with what `listplaylistinfo` adds: its size, length, and folders (for its cover mosaic).
struct PlaylistInfo: Identifiable, Equatable {
    var name: String
    var modified: Date?
    var count: Int?
    var duration: Double?
    var directories: [String] = []

    var id: String { name }

    /// "slow-evening" → "Slow Evening".
    var displayName: String {
        name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

enum TimeText {
    /// 3:46, or 1:02:09 past an hour.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "1 h 24 min" / "38 min".
    static func span(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        if m >= 60 { return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min" }
        return "\(max(1, m)) min"
    }
}
