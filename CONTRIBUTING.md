# Contributing to PeerClock

Thanks for your interest in contributing! This guide covers how to build,
test, and submit changes.

## Prerequisites

- **Swift 6.0+** (Xcode 16+ or a compatible Swift toolchain)
- **macOS 14+** (Sonoma) for building
- Physical iOS 17+ devices for WiFi/MultipeerConnectivity integration tests

## Building

```bash
swift build
```

PeerClock is a Swift Package Manager project with no external dependencies.

## Running Tests

```bash
# All tests
swift test

# A specific test suite
swift test --filter NTPSyncEngineTests

# A single test
swift test --filter NTPSyncEngineTests/offsetCalculation
```

Tests use `MockTransport` (in-memory) — no network or devices required.

The test suite uses Swift Testing (`import Testing`, `@Suite`, `@Test`,
`#expect`), not XCTest.

## Project Structure

```
Sources/PeerClock/       Library source
Sources/PeerClockCLI/    macOS CLI tool
Tests/PeerClockTests/    Unit tests (MockTransport-based)
Examples/PeerClockDemo/  iOS SwiftUI demo app
docs/                    Architecture and design documents
```

See [ARCHITECTURE.md](docs/ARCHITECTURE.md) for component details.

## Code Style

- **Swift 6 strict concurrency** — all public types must be `Sendable`.
  Mutable classes use `@unchecked Sendable` + `NSLock`.
- **No external dependencies** — the library must remain dependency-free.
- **Protocol at every boundary** — new components should implement a
  protocol so they can be mocked in tests.

## Submitting Changes

1. Fork the repository and create a feature branch
2. Write tests first (TDD preferred)
3. Ensure all 127+ tests pass: `swift test`
4. Ensure the build succeeds with no warnings: `swift build`
5. Keep commits focused and conventional:
   - `feat:` new feature
   - `fix:` bug fix
   - `docs:` documentation only
   - `test:` test additions
   - `refactor:` code restructuring with no behavior change
6. Open a pull request against `main`

## Adding a New Transport

Implement the `Transport` protocol (see
[`Sources/PeerClock/Transport/Transport.swift`](Sources/PeerClock/Transport/Transport.swift)):

```swift
public protocol Transport: Sendable {
    func start() async throws
    func stop() async
    var peers: AsyncStream<Set<PeerID>> { get }
    var incomingMessages: AsyncStream<(PeerID, Data)> { get }
    func send(_ data: Data, to peer: PeerID) async throws
    func broadcast(_ data: Data) async throws
    func broadcastUnreliable(_ data: Data) async throws
}
```

Test it by injecting via `PeerClock(transportFactory:)`.

## Questions?

Open an issue at [github.com/hakaru/PeerClock/issues](https://github.com/hakaru/PeerClock/issues).
