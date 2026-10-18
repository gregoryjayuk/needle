import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The app icon, drawn by the same code as the panel's record: charcoal tile, record, ochre label, tonearm.
struct IconArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.27, green: 0.25, blue: 0.225), Color(red: 0.125, green: 0.115, blue: 0.105)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 186, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 5))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            VinylView(art: nil, palette: .house, seed: "needle", spinning: false) { _ in 30 }
                .frame(width: 610, height: 610)
                .offset(x: -48, y: 42)
            Canvas { ctx, _ in
                let pivot = CGPoint(x: 790, y: 236)
                let tip = CGPoint(x: 646, y: 612)
                ctx.fill(Path(ellipseIn: CGRect(x: pivot.x - 54, y: pivot.y - 54, width: 108, height: 108)),
                         with: .linearGradient(Gradient(colors: [Color(white: 0.5), Color(white: 0.18)]),
                                               startPoint: CGPoint(x: pivot.x - 50, y: pivot.y - 50), endPoint: CGPoint(x: pivot.x + 50, y: pivot.y + 50)))
                let dx = tip.x - pivot.x, dy = tip.y - pivot.y
                let len = (dx * dx + dy * dy).squareRoot()
                let ux = dx / len, uy = dy / len
                let weight = CGPoint(x: pivot.x - ux * 70, y: pivot.y - uy * 70)
                var back = Path()
                back.move(to: pivot)
                back.addLine(to: weight)
                ctx.stroke(back, with: .color(Color(white: 0.55)), style: StrokeStyle(lineWidth: 40, lineCap: .round))
                var tube = Path()
                tube.move(to: pivot)
                tube.addLine(to: CGPoint(x: tip.x - ux * 52, y: tip.y - uy * 52))
                ctx.stroke(tube, with: .color(Color(white: 0.86)), style: StrokeStyle(lineWidth: 24, lineCap: .round))
                ctx.stroke(tube.offsetBy(dx: -4, dy: -2), with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                let shell = Path(roundedRect: CGRect(x: -26, y: -40, width: 52, height: 80), cornerRadius: 9)
                    .applying(CGAffineTransform(rotationAngle: atan2(-ux, uy)).concatenating(CGAffineTransform(translationX: tip.x - ux * 22, y: tip.y - uy * 22)))
                ctx.fill(shell, with: .color(Color(white: 0.28)))
                ctx.stroke(shell, with: .color(.white.opacity(0.3)), lineWidth: 3)
                ctx.fill(Path(ellipseIn: CGRect(x: pivot.x - 22, y: pivot.y - 22, width: 44, height: 44)),
                         with: .color(Color(white: 0.82)))
            }
            .frame(width: 1024, height: 1024)
            .shadow(color: .black.opacity(0.45), radius: 10, x: 6, y: 10)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
enum IconRenderer {
    /// Writes a full .iconset (16–1024 px) for `iconutil -c icns`.
    static func write(to dir: URL) -> Bool {
        let renderer = ImageRenderer(content: IconArt())
        renderer.scale = 1
        guard let master = renderer.cgImage else {
            FileHandle.standardError.write(Data("icon: render failed\n".utf8))
            return false
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sizes: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, px) in sizes {
            guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
            guard let image = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent("\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return false }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { return false }
        }
        return true
    }
}
