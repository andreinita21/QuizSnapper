// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuizSnapper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QuizSnapper",
            path: "Sources/QuizSnapper",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        )
    ]
)
