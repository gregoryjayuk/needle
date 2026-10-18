// swift-tools-version: 5.9
import PackageDescription

// Needle — an MPD music server, played from the Mac's menu bar. See README.md.
let package = Package(
    name: "Needle",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Needle", targets: ["Needle"])
    ],
    targets: [
        .executableTarget(
            name: "Needle",
            path: "Sources/Needle"
        )
    ]
)
