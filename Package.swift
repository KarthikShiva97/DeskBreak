// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StandupReminder",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "StandupReminderCore",
            path: "Sources/StandupReminderCore",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "StandupReminder",
            dependencies: ["StandupReminderCore"],
            path: "Sources/StandupReminder",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "StandupReminderCoreTests",
            dependencies: ["StandupReminderCore"],
            path: "Tests/StandupReminderCoreTests"
        ),
    ]
)
