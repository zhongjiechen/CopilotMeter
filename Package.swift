// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CopilotMeter",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CopilotMeter", targets: ["CopilotMeter"])
    ],
    targets: [
        .executableTarget(
            name: "CopilotMeter",
            path: "Sources/CopilotMeter",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
