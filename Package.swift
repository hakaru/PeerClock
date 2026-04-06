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
        )
    ],
    targets: [
        .target(
            name: "PeerClock",
            path: "Sources/PeerClock"
        ),
        .testTarget(
            name: "PeerClockTests",
            dependencies: ["PeerClock"],
            path: "Tests/PeerClockTests"
        )
    ]
)
