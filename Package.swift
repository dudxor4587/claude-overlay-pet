// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OverlayPet",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "OverlayPet",
            path: "Sources/OverlayPet",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
