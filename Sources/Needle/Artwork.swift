import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The colours a cover lends the panel: `glow` for the backdrop, `accent` for controls (always light
/// enough to read on charcoal), `deep` for shadows. Covers with no real colour keep the house ochre.
struct Palette: Equatable {
    var glow: Color
    var accent: Color
    var deep: Color
    var accentNS: NSColor

    static let house = Palette(base: Theme.accentNS, keepHouseAccent: true)

    init(base: NSColor, keepHouseAccent: Bool = false) {
        let c = base.usingColorSpace(.sRGB) ?? base
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let grey = s < 0.12
        let accent = (grey || keepHouseAccent)
            ? Theme.accentNS
            : NSColor(hue: h, saturation: min(max(s, 0.35), 0.62), brightness: max(b, 0.88), alpha: 1)
        accentNS = accent
        self.accent = Color(nsColor: accent)
        glow = Color(nsColor: NSColor(hue: h, saturation: grey ? s : min(1, s * 1.15 + 0.08), brightness: min(max(b, 0.42), 0.8), alpha: 1))
        deep = Color(nsColor: NSColor(hue: h, saturation: min(s, 0.45), brightness: 0.12, alpha: 1))
    }

    /// The cover's colour: a hue histogram weighted towards vivid pixels; the strongest bin's mean
    /// wins. Mostly-grey covers fall back to the plain average.
    static func from(_ image: CGImage) -> Palette {
        let side = 28
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return .house }
        var bins = [(w: Double, r: Double, g: Double, b: Double)](repeating: (0, 0, 0, 0), count: 12)
        var sum = (r: 0.0, g: 0.0, b: 0.0)
        var total = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
            sum.r += r; sum.g += g; sum.b += b
            let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
            guard mx > 0.14, d > 0.09 else { continue }
            var hue: Double
            if mx == r { hue = (g - b) / d } else if mx == g { hue = (b - r) / d + 2 } else { hue = (r - g) / d + 4 }
            hue = (hue / 6 + 1).truncatingRemainder(dividingBy: 1)
            let sat = d / mx
            let weight = sat * sat * mx
            let k = min(11, Int(hue * 12))
            bins[k].w += weight; bins[k].r += r * weight; bins[k].g += g * weight; bins[k].b += b * weight
            total += weight
        }
        let n = Double(side * side)
        if let best = bins.max(by: { $0.w < $1.w }), best.w > 0, total / n > 0.012 {
            return Palette(base: NSColor(srgbRed: best.r / best.w, green: best.g / best.w, blue: best.b / best.w, alpha: 1))
        }
        return Palette(base: NSColor(srgbRed: sum.r / n, green: sum.g / n, blue: sum.b / n, alpha: 1))
    }
}

struct CoverArt: Equatable {
    let key: String
    let image: NSImage
    let palette: Palette

    static func == (a: CoverArt, b: CoverArt) -> Bool { a.key == b.key }
}

/// Cover art, from MPD's `readpicture` (embedded) or `albumart` (cover.jpg in the folder).
///
/// The rule that shapes this file: **Needle never wakes a sleeping drive.** It asks MPD for art only
/// for the song that is playing — that drive is already spinning — and keeps everything it gets on
/// this Mac (one image per album folder). Lists show only art already cached here.
@MainActor
final class ArtworkStore: ObservableObject {
    @Published private(set) var current: CoverArt?

    private var client: MPDClient
    private var memory: [String: CoverArt] = [:]
    private var memoryOrder: [String] = []
    private var thumbs: [String: NSImage] = [:]
    private var thumbMisses = Set<String>()
    private var inFlight = Set<String>()
    private var missing = Set<String>()
    private var wanted: String?
    private let dir: URL
    /// Covers are filed per server: two servers can share folder names (the test mock does) but not covers.
    private var namespace = "\(Settings.host):\(Settings.port)"

    /// Fetches that failed on the wire (not "this song has no cover"). The self-test expects none.
    private(set) var failedFetches = 0

    init(cacheDirectory: URL? = nil) {
        client = MPDClient(host: Settings.host, port: UInt16(Settings.port), password: Settings.password)
        dir = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.greggaynor.needle/art", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func reconfigure() {
        let c = client
        client = MPDClient(host: Settings.host, port: UInt16(Settings.port), password: Settings.password)
        Task { await c.disconnect() }
        namespace = "\(Settings.host):\(Settings.port)"
        memory = [:]
        memoryOrder = []
        thumbs = [:]
        thumbMisses = []
        missing = []
        current = nil
    }

    /// Shows art for `song`. Asks the server only when `playing`.
    func show(_ song: MPDSong?, playing: Bool) {
        guard let song else {
            wanted = nil
            if current != nil { current = nil }
            return
        }
        let key = song.directory
        wanted = key
        if current?.key == key { return }
        if let art = memory[key] ?? loadFromDisk(key) {
            current = art
            return
        }
        if current != nil { current = nil }
        guard playing, !inFlight.contains(key), !missing.contains(key) else { return }
        if knownMissing(key) {
            missing.insert(key)   // asked on every status update while playing: remember, skip the disk
            return
        }
        inFlight.insert(key)
        let client = self.client
        let uri = song.file
        Task { [weak self] in
            var answered = true
            var data: Data?
            do { data = try await ArtworkStore.fetch(uri, from: client) } catch {
                answered = false
                self?.failedFetches += 1
                Log.write("art \(uri): \(error.localizedDescription)")
            }
            let decoded: (CGImage, Data)? = await Task.detached(priority: .utility) { [data] in
                guard let data, let cg = ArtworkStore.downscale(data, maxPixel: 640), let jpeg = ArtworkStore.jpeg(cg) else { return nil }
                return (cg, jpeg)
            }.value
            guard let self else { return }
            self.inFlight.remove(key)
            if let (cg, jpeg) = decoded {
                try? jpeg.write(to: self.fileURL(key, ext: "jpg"), options: .atomic)
                let art = CoverArt(key: key, image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), palette: Palette.from(cg))
                self.remember(art)
                if self.wanted == key { self.current = art }
            } else if answered && data == nil {
                // The server answered: no embedded picture, no cover file. Remember, so we don't ask every time.
                try? Data().write(to: self.fileURL(key, ext: "none"), options: .atomic)
                self.missing.insert(key)
            }
        }
    }

    /// A small cover for list rows: memory, then disk. Never the server.
    func thumbnail(for directory: String) async -> NSImage? {
        if let t = thumbs[directory] { return t }
        if thumbMisses.contains(directory) { return nil }
        if let art = memory[directory] {
            thumbs[directory] = art.image
            return art.image
        }
        let url = fileURL(directory, ext: "jpg")
        let image: NSImage? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url), let cg = ArtworkStore.downscale(data, maxPixel: 96) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image { thumbs[directory] = image } else { thumbMisses.insert(directory) }
        return image
    }

    // MARK: cache

    private func remember(_ art: CoverArt) {
        memory[art.key] = art
        memoryOrder.removeAll { $0 == art.key }
        memoryOrder.append(art.key)
        if memoryOrder.count > 40 { memory.removeValue(forKey: memoryOrder.removeFirst()) }
        thumbMisses.remove(art.key)
    }

    private func loadFromDisk(_ key: String) -> CoverArt? {
        guard let data = try? Data(contentsOf: fileURL(key, ext: "jpg")),
              let cg = ArtworkStore.downscale(data, maxPixel: 640) else { return nil }
        let art = CoverArt(key: key, image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), palette: Palette.from(cg))
        remember(art)
        return art
    }

    /// A folder with no art is asked again after 30 days, in case a cover has been added since.
    private func knownMissing(_ key: String) -> Bool {
        let url = fileURL(key, ext: "none")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let made = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(made) < 30 * 86400
    }

    private func fileURL(_ key: String, ext: String) -> URL {
        dir.appendingPathComponent(String(format: "%016llx", Theme.fnv(namespace + "\u{1F}" + key))).appendingPathExtension(ext)
    }

    // MARK: fetching and decoding

    /// The embedded picture first (most of this library), then a cover.* file beside the song.
    nonisolated static func fetch(_ uri: String, from client: MPDClient) async throws -> Data? {
        for command in ["readpicture", "albumart"] {
            var data = Data()
            var total = -1
            chunks: while total < 0 || data.count < total {
                let reply: MPDReply
                do {
                    reply = try await client.run("\(command) \(MPD.quote(uri)) \(data.count)", timeout: 20)
                } catch let e as MPDError {
                    if case .ack = e { break chunks }
                    throw e
                }
                guard let size = reply["size"].flatMap(Int.init), let chunk = reply.binary, !chunk.isEmpty else { break chunks }
                total = size
                data.append(chunk)
            }
            if total > 0, data.count >= total { return data }
        }
        return nil
    }

    nonisolated static func downscale(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    nonisolated static func jpeg(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
