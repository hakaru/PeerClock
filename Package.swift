// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PeerClock",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PeerClock",
            targets: ["PeerClock"]
        ),
        .executable(
            name: "PeerClockCLI",
            targets: ["PeerClockCLI"]
        )
    ],
    targets: [
        .target(
            name: "PeerClock",
            path: "Sources/PeerClock"
        ),
        .executableTarget(
            name: "PeerClockCLI",
            dependencies: ["PeerClock"],
            path: "Sources/PeerClockCLI"
        ),
        .testTarget(
            name: "PeerClockTests",
            dependencies: ["PeerClock"],
            path: "Tests/PeerClockTests"
        )
    ]
)
