// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppleWatchCursorCore",
    platforms: [.macOS(.v14), .watchOS(.v10)],
    products: [.library(name: "AppleWatchCursorCore", targets: ["AppleWatchCursorCore"]),
               .executable(name: "TapReplay", targets: ["TapReplay"])],
    targets: [
        .target(name: "AppleWatchCursorCore"),
        .testTarget(name: "AppleWatchCursorCoreTests", dependencies: ["AppleWatchCursorCore"]),
        .executableTarget(name: "TapReplay", dependencies: ["AppleWatchCursorCore"], path: "Tools/TapReplay")
    ]
)
