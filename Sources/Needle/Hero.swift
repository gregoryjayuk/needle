import SwiftUI

enum PanelMetrics {
    static let width: CGFloat = 372
    static let pad: CGFloat = 18
    static let heroWidth: CGFloat = width - 2 * pad
    static let cover: CGFloat = 188
    static let disc: CGFloat = 180
    /// How far the record slides out of its sleeve: to the cover's right edge, so half of it shows.
    static let discTravel: CGFloat = cover / 2
    static let pivot = CGPoint(x: 318, y: 22)
    /// The tonearm's swing: 0° parked off the record; 24° is the lead-in groove, 38° the run-out.
    static let armStart = 24.0
    static let armEnd = 38.0
    static let listHeight: CGFloat = 212
}

/// The top of the panel: the sleeve, the record sliding out of it, and the tonearm.
/// The record spins at a true 33⅓ rpm while the server plays, and the arm tracks inward through the song.
struct HeroView: View {
    @ObservedObject var player: Player
    let art: CoverArt?
    let palette: Palette
    @Local private var spin = SpinClock()
    @Local private var armDown = false
    @Environment(\.panelActive) private var active

    private typealias M = PanelMetrics

    var body: some View {
        let online = player.isOnline
        let state: MPDStatus.State = online ? player.status.state : .stop
        let discOut = online && player.song != nil && state != .stop
        let spinning = active && state == .play
        // Only what moves is on a clock: the label at 60 fps (inside VinylView), the arm once a second
        // (it crosses the record over a whole song). The sleeve, grooves and shadows render once.
        ZStack(alignment: .topLeading) {
            VinylView(art: art, palette: palette, seed: player.song?.directory ?? "needle", spinning: spinning) { spin.angle(at: $0) }
                .frame(width: M.disc, height: M.disc)
                .offset(x: (M.cover - M.disc) / 2 + (discOut ? M.discTravel : 0), y: (M.cover - M.disc) / 2)
            CoverView(art: art, song: player.song, online: online, link: player.link)
            TonearmBase()
            TimelineView(.animation(minimumInterval: 1, paused: !spinning)) { timeline in
                let arm = armDown ? M.armStart + (M.armEnd - M.armStart) * player.progress(at: timeline.date) - (state == .pause ? 1.2 : 0) : 0
                TonearmArm(accent: palette.accent)
                    .rotationEffect(.degrees(arm), anchor: UnitPoint(x: M.pivot.x / M.heroWidth, y: M.pivot.y / M.cover))
            }
        }
        .frame(width: M.heroWidth, height: M.cover, alignment: .topLeading)
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: discOut)
        .onChange(of: state == .play, initial: true) { _, playing in spin.set(playing: playing) }
        .onChange(of: discOut, initial: true) { _, out in
            if out {
                // The record comes out first; then the arm swings over and drops.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    let stillOut = player.isOnline && player.song != nil && player.status.state != .stop
                    withAnimation(.spring(response: 0.9, dampingFraction: 0.8)) { armDown = stillOut }
                }
            } else {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { armDown = false }
            }
        }
    }
}

/// Keeps the record's angle continuous across pauses: it stops where it was and starts from there.
final class SpinClock {
    /// 33⅓ revolutions a minute.
    static let degreesPerSecond = 360.0 * (100.0 / 3.0) / 60.0
    private var base = 0.0
    private var since: Date?

    func set(playing: Bool, at now: Date = Date()) {
        if playing, since == nil { since = now }
        if !playing, let s = since {
            base += now.timeIntervalSince(s) * SpinClock.degreesPerSecond
            since = nil
        }
    }

    func angle(at date: Date) -> Double {
        (base + (since.map { date.timeIntervalSince($0) * SpinClock.degreesPerSecond } ?? 0)).truncatingRemainder(dividingBy: 360)
    }
}

struct CoverView: View {
    let art: CoverArt?
    let song: MPDSong?
    let online: Bool
    let link: Player.Link

    var body: some View {
        ZStack {
            if let art {
                Image(nsImage: art.image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else if online, let song {
                GeneratedCover(title: song.album ?? song.displayTitle, subtitle: song.displayArtist)
            } else {
                GeneratedCover(title: placeholderTitle, subtitle: placeholderSubtitle, symbol: placeholderSymbol)
            }
        }
        .frame(width: PanelMetrics.cover, height: PanelMetrics.cover)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 16, x: 0, y: 10)
        .id(art?.key ?? "generated:\(song?.directory ?? placeholderTitle)")
        .transition(.opacity)
    }

    private var placeholderTitle: String {
        switch link {
        case .online: return "Nothing playing"
        case .connecting: return "Connecting"
        case .offline: return "Can't reach \(Settings.serverName)"
        case .away: return "Away from home"
        }
    }

    private var placeholderSubtitle: String? {
        switch link {
        case .online: return "Pick a playlist below"
        case .connecting: return Settings.serverName
        case .offline: return "Retrying"
        case .away: return "\(Settings.serverName) is on the home network"
        }
    }

    private var placeholderSymbol: String? {
        switch link {
        case .online: return "music.note"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .offline: return "wifi.exclamationmark"
        case .away: return "house"
        }
    }
}

/// The record: grooves (static — real ones look still), dust specks and the label (turning),
/// and a sheen that stays put while the disc turns under it, as light on vinyl does.
/// Its shadow is a separate, static circle: a shadow on the turning composite would be re-blurred every frame.
struct VinylView: View {
    let art: CoverArt?
    let palette: Palette
    let seed: String
    let spinning: Bool
    let angle: (Date) -> Double

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(Color.black).shadow(color: .black.opacity(0.6), radius: 10, x: 0, y: 6)
                Circle().fill(RadialGradient(colors: [Color(white: 0.15), Color(white: 0.055), Color(white: 0.085)],
                                             center: .center, startRadius: 0, endRadius: d / 2))
                GroovesView(seed: seed).equatable()
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !spinning)) { timeline in
                    ZStack {
                        SpecksView(seed: seed).equatable()
                        RecordLabel(art: art, palette: palette)
                            .frame(width: d * 0.34, height: d * 0.34)
                    }
                    .rotationEffect(.degrees(angle(timeline.date)))
                }
                Circle()
                    .fill(AngularGradient(gradient: Gradient(stops: [
                        .init(color: .white.opacity(0.0), location: 0.00),
                        .init(color: .white.opacity(0.11), location: 0.07),
                        .init(color: .white.opacity(0.0), location: 0.17),
                        .init(color: .white.opacity(0.0), location: 0.50),
                        .init(color: .white.opacity(0.09), location: 0.57),
                        .init(color: .white.opacity(0.0), location: 0.67),
                        .init(color: .white.opacity(0.0), location: 1.00),
                    ]), center: .center, angle: .degrees(-40)))
                    .mask(Ring(inner: 0.36).fill(style: FillStyle(eoFill: true)))
                    .blendMode(.plusLighter)
                Circle().strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            }
            .frame(width: d, height: d)
        }
    }
}

struct Ring: Shape {
    let inner: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path(ellipseIn: rect)
        let r = min(rect.width, rect.height) * inner / 2
        p.addEllipse(in: CGRect(x: rect.midX - r, y: rect.midY - r, width: 2 * r, height: 2 * r))
        return p
    }
}

struct GroovesView: View, Equatable {
    let seed: String

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let R = min(size.width, size.height) / 2
            var rng = SeededRandom(Theme.fnv(seed))
            // The silent bands between tracks: smooth, darker rings, different for every album.
            let gaps = (0..<(3 + Int(rng.next() % 4))).map { _ in R * (0.47 + 0.47 * rng.unit()) }
            var r = R * 0.41
            while r < R * 0.985 {
                if !gaps.contains(where: { abs($0 - r) < 1.4 }) {
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(.white.opacity(0.03 + 0.04 * rng.unit())), lineWidth: 0.55)
                }
                r += 1.1
            }
            for g in gaps {
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - g, y: c.y - g, width: 2 * g, height: 2 * g)),
                           with: .color(.black.opacity(0.55)), lineWidth: 1.5)
            }
        }
    }
}

/// A few motes of dust: on a turning record they are what shows it turning.
struct SpecksView: View, Equatable {
    let seed: String

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let R = min(size.width, size.height) / 2
            var rng = SeededRandom(Theme.fnv(seed + "dust"))
            for _ in 0..<9 {
                let r = R * (0.45 + 0.5 * rng.unit())
                let a = rng.unit() * 2 * .pi
                let s = 0.7 + 1.1 * rng.unit()
                let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)),
                         with: .color(.white.opacity(0.18 + 0.25 * rng.unit())))
            }
        }
    }
}

struct RecordLabel: View {
    let art: CoverArt?
    let palette: Palette

    var body: some View {
        GeometryReader { geo in
            let d = geo.size.width
            ZStack {
                if let art {
                    Image(nsImage: art.image).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                } else {
                    RadialGradient(colors: [palette.accent, palette.accent.opacity(0.75)], center: .center, startRadius: 0, endRadius: d / 2)
                }
                Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: d * 0.05)
                Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6).padding(d * 0.12)
                Circle().fill(Theme.bg).frame(width: d * 0.08, height: d * 0.08)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
            }
            .frame(width: d, height: d)
            .clipShape(Circle())
        }
    }
}

/// The pivot's housing: drawn separately because it does not turn with the arm.
struct TonearmBase: View {
    var body: some View {
        let p = PanelMetrics.pivot
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.5), radius: 3, x: 1, y: 2)
        }
        .position(x: p.x, y: p.y)
        .frame(width: PanelMetrics.heroWidth, height: PanelMetrics.cover, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// The arm itself, drawn pointing straight down from the pivot; HeroView swings it.
struct TonearmArm: View {
    let accent: Color

    var body: some View {
        Canvas { ctx, _ in
            let p = PanelMetrics.pivot
            // Counterweight, behind the pivot.
            let weight = CGRect(x: p.x - 7.5, y: p.y - 27, width: 15, height: 14)
            ctx.fill(Path(roundedRect: weight, cornerRadius: 3.5),
                     with: .linearGradient(Gradient(colors: [Color(white: 0.62), Color(white: 0.24)]),
                                           startPoint: CGPoint(x: weight.minX, y: 0), endPoint: CGPoint(x: weight.maxX, y: 0)))
            var stub = Path()
            stub.move(to: CGPoint(x: p.x, y: p.y - 13))
            stub.addLine(to: CGPoint(x: p.x, y: p.y))
            ctx.stroke(stub, with: .color(Color(white: 0.7)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))

            // The tube, with a gentle bend into the headshell.
            var tube = Path()
            tube.move(to: CGPoint(x: p.x, y: p.y))
            tube.addLine(to: CGPoint(x: p.x, y: p.y + 120))
            tube.addQuadCurve(to: CGPoint(x: p.x - 7, y: p.y + 138), control: CGPoint(x: p.x, y: p.y + 131))
            ctx.stroke(tube, with: .color(Color(white: 0.83)), style: StrokeStyle(lineWidth: 3.6, lineCap: .round, lineJoin: .round))
            ctx.stroke(tube.offsetBy(dx: -0.9, dy: 0), with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))

            // Headshell, cartridge (in the cover's colour) and finger lift.
            let shell = Path(roundedRect: CGRect(x: -5.5, y: 0, width: 11, height: 18), cornerRadius: 2.2)
                .applying(CGAffineTransform(rotationAngle: 0.13).concatenating(CGAffineTransform(translationX: p.x - 8.5, y: p.y + 136)))
            ctx.fill(shell, with: .color(Color(white: 0.3)))
            ctx.stroke(shell, with: .color(.white.opacity(0.25)), lineWidth: 0.6)
            let cart = Path(roundedRect: CGRect(x: -3.5, y: 9, width: 7, height: 7), cornerRadius: 1.2)
                .applying(CGAffineTransform(rotationAngle: 0.13).concatenating(CGAffineTransform(translationX: p.x - 8.5, y: p.y + 136)))
            ctx.fill(cart, with: .color(accent))
            var lift = Path()
            lift.move(to: CGPoint(x: p.x - 3.5, y: p.y + 142))
            lift.addLine(to: CGPoint(x: p.x + 4.5, y: p.y + 145))
            ctx.stroke(lift, with: .color(Color(white: 0.75)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))

            // Cap over the bearing.
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5.5, y: p.y - 5.5, width: 11, height: 11)),
                     with: .linearGradient(Gradient(colors: [Color(white: 0.85), Color(white: 0.45)]),
                                           startPoint: CGPoint(x: p.x - 5, y: p.y - 5), endPoint: CGPoint(x: p.x + 5, y: p.y + 5)))
        }
        .frame(width: PanelMetrics.heroWidth, height: PanelMetrics.cover)
        .shadow(color: .black.opacity(0.45), radius: 3, x: 2, y: 3)
        .allowsHitTesting(false)
    }
}

/// A cover for a song with no picture yet: two warm tones seeded by the album (so an album always
/// gets the same one), record grooves in the corner, and the title set in serif.
struct GeneratedCover: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var compact = false

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Theme.swatch(title), Theme.swatch(title, salt: 5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width * 0.95, y: size.height * 1.0)
                    for i in 0..<10 {
                        let r = size.width * (0.2 + CGFloat(i) * 0.075)
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                                   with: .color(.white.opacity(i % 3 == 0 ? 0.1 : 0.05)), lineWidth: max(0.5, size.width * 0.005))
                    }
                }
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.32)], startPoint: .top, endPoint: .bottom)
                if compact {
                    Text(GeneratedCover.initials(title))
                        .font(.system(size: s * 0.38, weight: .semibold, design: .serif))
                        .foregroundStyle(Theme.text.opacity(0.92))
                        .frame(width: s, height: geo.size.height)
                } else {
                    VStack(alignment: .leading, spacing: s * 0.025) {
                        if let symbol {
                            Image(systemName: symbol).font(.system(size: s * 0.13, weight: .medium)).padding(.bottom, s * 0.03)
                        }
                        Text(title).font(.system(size: s * 0.105, weight: .semibold, design: .serif)).lineLimit(3)
                        if let subtitle {
                            Text(subtitle).font(.system(size: s * 0.064, weight: .medium)).opacity(0.75).lineLimit(2)
                        }
                    }
                    .foregroundStyle(Theme.text)
                    .padding(s * 0.09)
                }
            }
        }
    }

    static func initials(_ s: String) -> String {
        let words = s.split { !$0.isLetter && !$0.isNumber }.prefix(2)
        let out = words.compactMap { $0.first.map { String($0).uppercased() } }.joined()
        return out.isEmpty ? "♪" : out
    }
}

/// SplitMix64: a tiny deterministic generator, so an album's grooves and dust never change.
struct SeededRandom {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
