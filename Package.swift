// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "audio-relay",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "audio-relay",
            path: "Sources/audio-relay",
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist (NSAudioCaptureUsageDescription) so macOS can show the
                // "System Audio Recording" permission prompt for this CLI.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/audio-relay/Info.plist",
                ])
            ]
        )
    ]
)
