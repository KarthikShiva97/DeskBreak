// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StandupReminder",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "StandupReminderLib",
            path: "Sources/StandupReminderLib",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "StandupReminder",
            dependencies: ["StandupReminderLib"],
            path: "Sources/StandupReminder",
            linkerSettings: [
                .linkedFramework("Cocoa"),
            ]
        ),
        .testTarget(
            name: "StandupReminderTests",
            dependencies: ["StandupReminderLib"],
            path: "Tests/StandupReminderTests"
        ),
    ]
)
