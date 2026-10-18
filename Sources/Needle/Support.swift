import AppKit
import Darwin
import SwiftUI

/// Everything the user can change. One defaults suite, so the app and the CLI read the same values.
/// Environment variables win when set: NEEDLE_HOST / NEEDLE_PORT, then the classic MPD_HOST / MPD_PORT
/// (MPD_HOST may carry a password as "secret@host").
enum Settings {
    static let defaults = UserDefaults(suiteName: "com.greggaynor.needle.settings") ?? .standard
    /// MPD's own default. Set the real server in Settings, or with NEEDLE_HOST / MPD_HOST.
    static let defaultHost = "localhost"
    static let defaultPort = 6600

    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    private static var envHost: (host: String, password: String?)? {
        guard let raw = env["NEEDLE_HOST"] ?? env["MPD_HOST"], !raw.isEmpty else { return nil }
        if let at = raw.lastIndex(of: "@"), !raw.hasPrefix("@") {
            return (String(raw[raw.index(after: at)...]), String(raw[..<at]))
        }
        return (raw, nil)
    }

    static var host: String {
        get { envHost?.host ?? defaults.string(forKey: "host").flatMap { $0.isEmpty ? nil : $0 } ?? defaultHost }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "host") }
    }

    static var port: Int {
        get {
            if let p = (env["NEEDLE_PORT"] ?? env["MPD_PORT"]).flatMap(Int.init) { return p }
            let p = defaults.integer(forKey: "port")
            return p > 0 ? p : defaultPort
        }
        set { defaults.set(newValue, forKey: "port") }
    }

    static var password: String {
        get { envHost?.password ?? defaults.string(forKey: "password") ?? "" }
        set { defaults.set(newValue, forKey: "password") }
    }

    /// Shown in the UI: "the music server" for the default, otherwise what was typed.
    static var serverName: String { host == defaultHost ? "the music server" : host }

    static var showTitle: Bool {
        get { defaults.object(forKey: "showTitle") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showTitle") }
    }

    static var animateIcon: Bool {
        get { defaults.object(forKey: "animateIcon") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "animateIcon") }
    }

    static var mediaKeys: Bool {
        get { defaults.object(forKey: "mediaKeys") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "mediaKeys") }
    }

    /// Re-apply the volume when playback starts from stopped (see Player.holdVolume).
    static var keepVolume: Bool {
        get { defaults.object(forKey: "keepVolume") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepVolume") }
    }

    static var tab: String {
        get { defaults.string(forKey: "tab") ?? "" }
        set { defaults.set(newValue, forKey: "tab") }
    }
}

/// Greg's house palette (the launcher's Face Dragons tokens): warm charcoal, parchment text,
/// one ochre accent, no blue. A playing cover may lend its own colour for the accent.
enum Theme {
    static let bg = Color(red: 0x1f / 255, green: 0x1d / 255, blue: 0x1a / 255)
    static let bgNS = NSColor(srgbRed: 0x1f / 255, green: 0x1d / 255, blue: 0x1a / 255, alpha: 1)
    static let raised = Color(red: 0x2a / 255, green: 0x27 / 255, blue: 0x23 / 255)
    static let text = Color(red: 0xe9 / 255, green: 0xe1 / 255, blue: 0xd2 / 255)
    static let muted = Color(red: 0x9c / 255, green: 0x93 / 255, blue: 0x85 / 255)
    static let accent = Color(red: 0xc4 / 255, green: 0x98 / 255, blue: 0x6b / 255)
    static let accentNS = NSColor(srgbRed: 0xc4 / 255, green: 0x98 / 255, blue: 0x6b / 255, alpha: 1)
    static let hairline = Color.white.opacity(0.08)
    static let hover = Color.white.opacity(0.06)
    static let selected = Color.white.opacity(0.11)
    static let good = Color(red: 0.55, green: 0.72, blue: 0.42)
    static let bad = Color(red: 0.86, green: 0.42, blue: 0.34)

    /// Muted warm tones for generated covers, picked deterministically per album.
    static let swatches: [Color] = [
        Color(red: 0.36, green: 0.42, blue: 0.30), // moss
        Color(red: 0.55, green: 0.33, blue: 0.27), // rust
        Color(red: 0.42, green: 0.32, blue: 0.42), // plum
        Color(red: 0.60, green: 0.50, blue: 0.34), // sand
        Color(red: 0.36, green: 0.38, blue: 0.40), // warm slate
        Color(red: 0.47, green: 0.47, blue: 0.30), // olive
        Color(red: 0.52, green: 0.38, blue: 0.30), // clay
        Color(red: 0.30, green: 0.42, blue: 0.42), // teal-grey
    ]

    static func swatch(_ key: String, salt: UInt64 = 0) -> Color {
        swatches[Int((fnv(key) &+ salt &* 0x9E3779B97F4A7C15) % UInt64(swatches.count))]
    }

    /// FNV-1a, 64-bit: stable across launches (Swift's hashValue is not).
    static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/needle.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

enum LAN {
    /// True when one of this Mac's IPv4 interfaces is on the server's subnet — the cheap test for
    /// "at home". At work Needle then stops retrying on a timer, so it never keeps knocking on a
    /// stranger's machine at the same address. A hostname (not an IPv4 address) always counts as worth trying.
    static func isLocal(_ host: String) -> Bool {
        var target = in_addr()
        guard inet_pton(AF_INET, host, &target) == 1 else { return true }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return true }
        defer { freeifaddrs(list) }
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  let nm = ifa.pointee.ifa_netmask else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            guard mask != 0, mask != UInt32.max else { continue }
            if addr & mask == target.s_addr & mask { return true }
        }
        return false
    }
}

/// View-local state without SwiftUI's `@State`: in the macOS 27 SDK `@State` is a macro whose plugin
/// ships only with Xcode, and this Mac builds with the Command Line Tools. `@StateObject` is still a
/// plain property wrapper, so this boxes the value in one. Same lifetime, same `$binding`.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> { $box.value }
}

/// Whether the panel is on screen. Clock-driven views (the record, the scrubber, the level bars) stop
/// ticking when it is not, so a hidden panel costs nothing. A plain EnvironmentKey: `@Entry` is a
/// macro, and this Mac's toolchain has no SwiftUI macro plugin (see `Local`).
private struct PanelActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var panelActive: Bool {
        get { self[PanelActiveKey.self] }
        set { self[PanelActiveKey.self] = newValue }
    }
}
