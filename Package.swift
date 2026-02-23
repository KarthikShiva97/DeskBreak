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
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications"),
            ]
        ),
    ]
)
