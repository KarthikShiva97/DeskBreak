// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StandupReminder",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "StandupReminder",
            path: "Sources/StandupReminder",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreMedia"),
            ]
        ),
    ]
)
