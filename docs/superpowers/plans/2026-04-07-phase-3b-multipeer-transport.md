# Phase 3b: MultipeerConnectivity Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PeerClock に `MultipeerConnectivity` ベースの代替トランスポート `MultipeerTransport` を追加する。自動切替は Phase 3c 以降、Phase 3b は実装と opt-in での実機検証のみ。

**Architecture:** `MultipeerTransport: Transport` を新設し、`MCSession` / `MCNearbyServiceAdvertiser` / `MCNearbyServiceBrowser` で発見と接続を管理する。`MCPeerID.displayName` に PeerID (UUID 文字列) を埋め込んで identity を同時確定。招待方向は `local < remote` で一意化し、context marker で異種アプリ誤接続を防御。接続確立後は既存 `Transport` protocol 上を流れる Wire メッセージでそのまま Phase 1-3a の上位層が動作する。

**Tech Stack:** Swift 6 strict concurrency, Swift Testing, MultipeerConnectivity.framework, Foundation

**Spec reference:** `docs/superpowers/specs/2026-04-07-peerclock-v2-design.md` (Phase 3b 節)

---

## File Structure

**Create:**
- `Sources/PeerClock/Transport/MultipeerIdentity.swift` — 純関数ヘルパ (encode/decode/shouldInitiateInvitation/verifyInvitation)
- `Sources/PeerClock/Transport/MultipeerPeerIDStore.swift` — MCPeerID 永続化 (UserDefaults + NSSecureCoding)
- `Sources/PeerClock/Transport/MultipeerTransport.swift` — 本体
- `Tests/PeerClockTests/MultipeerIdentityTests.swift` — 純関数ユニットテスト

**Modify:**
- `Sources/PeerClock/Configuration.swift` — `mcServiceType`, `mcMaxPeers`
- `Examples/PeerClockDemo/Info.plist` — `NSBonjourServices` に MPC 追加
- `Examples/PeerClockDemo/PeerClockDemo/PeerClockViewModel.swift` — MC モード切替
- `Examples/PeerClockDemo/PeerClockDemo/ContentView.swift` — MC トグル UI

---

## Task 1: Configuration fields for MPC

**Files:**
- Modify: `Sources/PeerClock/Configuration.swift`

- [ ] **Step 1: Configuration に MPC フィールドを追加**

現状の Configuration に MPC 項目を追加する。`serviceType` の直前に新セクションを挿入:

```swift
    // MARK: - MultipeerConnectivity

    /// MultipeerConnectivity service type (1-15 ASCII 英数字/ハイフンのみ、
    /// 先頭末尾ハイフン不可)。WiFiTransport の serviceType とは別物。
    public let mcServiceType: String

    /// MCSession の仕様上限 (自分を含めて 8 peer)。9 台目以降は発見しても
    /// 招待しない / 受諾しない。
    public let mcMaxPeers: Int
```

`init(...)` の引数リストで `serviceType` の直前に追加:

```swift
        mcServiceType: String = "peerclock-mpc",
        mcMaxPeers: Int = 8,
```

`init` 本体で `self.serviceType = serviceType` の直前に追加:

```swift
        self.mcServiceType = mcServiceType
        self.mcMaxPeers = mcMaxPeers
```

- [ ] **Step 2: Build & test**

```bash
cd /Volumes/Dev/DEVELOP/PeerClock
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5
```

Expected: Build complete, 81 tests passing (no regression).

- [ ] **Step 3: Commit**

```bash
git add Sources/PeerClock/Configuration.swift
git commit -m "feat(config): add Phase 3b MultipeerConnectivity fields"
```

---

## Task 2: MultipeerIdentity pure-function helpers

**Files:**
- Create: `Sources/PeerClock/Transport/MultipeerIdentity.swift`
- Create: `Tests/PeerClockTests/MultipeerIdentityTests.swift`

- [ ] **Step 1: Create MultipeerIdentity.swift**

```swift
// Sources/PeerClock/Transport/MultipeerIdentity.swift
import Foundation

/// Pure-function helpers for MultipeerTransport. Kept separate so they can be
/// unit-tested without MCSession / MCNearbyService dependencies.
enum MultipeerIdentity {

    /// Invitation context marker used to reject connections from apps that
    /// happen to share our serviceType.
    static let invitationContextMarker = Data("peerclock-v1".utf8)

    /// Encodes a PeerID into an MCPeerID-compatible display name.
    static func encode(_ peerID: PeerID) -> String {
        peerID.rawValue.uuidString
    }

    /// Decodes a display name back into a PeerID. Returns nil if the string
    /// is not a valid UUID.
    static func decode(_ displayName: String) -> PeerID? {
        guard let uuid = UUID(uuidString: displayName) else { return nil }
        return PeerID(rawValue: uuid)
    }

    /// Returns true if the local peer should be the one initiating an
    /// invitation to the remote peer (used to break ties in symmetric
    /// discovery). Smaller PeerID invites.
    static func shouldInitiateInvitation(local: PeerID, remote: PeerID) -> Bool {
        local < remote
    }

    /// Verifies that an invitation context contains the expected marker.
    static func verifyInvitation(context: Data?) -> Bool {
        context == invitationContextMarker
    }
}
```

- [ ] **Step 2: Create MultipeerIdentityTests.swift**

```swift
// Tests/PeerClockTests/MultipeerIdentityTests.swift
import Foundation
import Testing
@testable import PeerClock

@Suite("MultipeerIdentity")
struct MultipeerIdentityTests {

    @Test("encode and decode round-trip")
    func roundTrip() {
        let peerID = PeerID(rawValue: UUID())
        let encoded = MultipeerIdentity.encode(peerID)
        let decoded = MultipeerIdentity.decode(encoded)
        #expect(decoded == peerID)
    }

    @Test("decode returns nil for non-UUID strings")
    func decodeRejectsGarbage() {
        #expect(MultipeerIdentity.decode("hello") == nil)
        #expect(MultipeerIdentity.decode("") == nil)
        #expect(MultipeerIdentity.decode("not-a-uuid-string-1234") == nil)
    }

    @Test("shouldInitiateInvitation uses < ordering")
    func invitationDirection() {
        let a = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let b = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        #expect(MultipeerIdentity.shouldInitiateInvitation(local: a, remote: b) == true)
        #expect(MultipeerIdentity.shouldInitiateInvitation(local: b, remote: a) == false)
    }

    @Test("verifyInvitation accepts correct marker")
    func verifyAcceptsMarker() {
        let correct = Data("peerclock-v1".utf8)
        #expect(MultipeerIdentity.verifyInvitation(context: correct) == true)
    }

    @Test("verifyInvitation rejects nil and wrong markers")
    func verifyRejectsBadContext() {
        #expect(MultipeerIdentity.verifyInvitation(context: nil) == false)
        #expect(MultipeerIdentity.verifyInvitation(context: Data()) == false)
        #expect(MultipeerIdentity.verifyInvitation(context: Data("other".utf8)) == false)
    }

    @Test("invitationContextMarker is stable")
    func markerStable() {
        #expect(MultipeerIdentity.invitationContextMarker == Data("peerclock-v1".utf8))
    }
}
```

- [ ] **Step 3: Build & test**

```bash
swift build 2>&1 | tail -5
swift test --filter MultipeerIdentityTests 2>&1 | tail -15
swift test 2>&1 | tail -5
```

Expected: 6 new tests pass, total 87.

- [ ] **Step 4: Commit**

```bash
git add Sources/PeerClock/Transport/MultipeerIdentity.swift Tests/PeerClockTests/MultipeerIdentityTests.swift
git commit -m "feat(transport): MultipeerIdentity pure-function helpers"
```

---

## Task 3: MultipeerPeerIDStore (NSSecureCoding persistence)

**Files:**
- Create: `Sources/PeerClock/Transport/MultipeerPeerIDStore.swift`

- [ ] **Step 1: Create MultipeerPeerIDStore.swift**

```swift
// Sources/PeerClock/Transport/MultipeerPeerIDStore.swift
import Foundation
import MultipeerConnectivity

/// Persists an `MCPeerID` across process launches so that nearby devices do
/// not see the same PeerID reappear with a fresh MCPeerID instance (which
/// confuses the MPC framework cache).
enum MultipeerPeerIDStore {

    /// Loads a persisted `MCPeerID` matching the given display name, or
    /// creates and stores a new one if none exists or the display name has
    /// changed.
    static func loadOrCreate(displayName: String, userDefaults: UserDefaults = .standard) -> MCPeerID {
        let key = "PeerClock.MCPeerID.\(displayName)"
        if let data = userDefaults.data(forKey: key) {
            if let peerID = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: MCPeerID.self,
                from: data
            ), peerID.displayName == displayName {
                return peerID
            }
        }
        let newPeerID = MCPeerID(displayName: displayName)
        if let data = try? NSKeyedArchiver.archivedData(
            withRootObject: newPeerID,
            requiringSecureCoding: true
        ) {
            userDefaults.set(data, forKey: key)
        }
        return newPeerID
    }

    /// Removes the persisted MCPeerID for the given display name. Useful when
    /// the local PeerID changes (e.g. user reset) and the cached MCPeerID is
    /// no longer valid.
    static func reset(displayName: String, userDefaults: UserDefaults = .standard) {
        let key = "PeerClock.MCPeerID.\(displayName)"
        userDefaults.removeObject(forKey: key)
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -5
```

Expected: clean build. `MultipeerConnectivity` import should resolve (available on iOS + macOS).

Note: no unit test for this helper — it touches UserDefaults which requires integration setup beyond Phase 3b's scope. Manual verification on a real device is sufficient.

- [ ] **Step 3: Commit**

```bash
git add Sources/PeerClock/Transport/MultipeerPeerIDStore.swift
git commit -m "feat(transport): MultipeerPeerIDStore for MCPeerID persistence"
```

---

## Task 4: MultipeerTransport — skeleton, init, delegates scaffold

**Files:**
- Create: `Sources/PeerClock/Transport/MultipeerTransport.swift`

This task creates the full file. Subsequent tasks only adjust behaviour inside delegate methods if needed, but the skeleton should be correct enough to build and do nothing-but-exist at the end of Task 4.

- [ ] **Step 1: Create MultipeerTransport.swift**

```swift
// Sources/PeerClock/Transport/MultipeerTransport.swift
import Foundation
import MultipeerConnectivity
import os

/// MultipeerConnectivity-based transport. Uses MCSession over the
/// peerclock-mpc service type. Supports reliable (send/broadcast) and
/// unreliable (broadcastUnreliable) paths via MCSessionSendDataMode.
public final class MultipeerTransport: NSObject, Transport, @unchecked Sendable {

    // MARK: - Public

    public let peers: AsyncStream<Set<PeerID>>
    public let incomingMessages: AsyncStream<(PeerID, Data)>

    // MARK: - Private

    private let localPeerID: PeerID
    private let configuration: Configuration
    private let logger: Logger

    private let lock = NSLock()

    // MCPeerID + MCSession are created on start() so start/stop is idempotent.
    private var mcPeerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    // Bi-directional maps between our PeerID and MCPeerID.
    private var pcToMC: [PeerID: MCPeerID] = [:]
    private var mcToPC: [MCPeerID: PeerID] = [:]

    private let peersContinuation: AsyncStream<Set<PeerID>>.Continuation
    private let incomingMessagesContinuation: AsyncStream<(PeerID, Data)>.Continuation

    // MARK: - Init

    public init(localPeerID: PeerID, configuration: Configuration) {
        self.localPeerID = localPeerID
        self.configuration = configuration
        self.logger = Logger(subsystem: "net.hakaru.PeerClock", category: "MultipeerTransport")

        var peersCont: AsyncStream<Set<PeerID>>.Continuation!
        self.peers = AsyncStream { peersCont = $0 }
        self.peersContinuation = peersCont

        var incomingCont: AsyncStream<(PeerID, Data)>.Continuation!
        self.incomingMessages = AsyncStream { incomingCont = $0 }
        self.incomingMessagesContinuation = incomingCont

        super.init()
    }

    // MARK: - Transport protocol

    public func start() async throws {
        let displayName = MultipeerIdentity.encode(localPeerID)
        let mcID = MultipeerPeerIDStore.loadOrCreate(displayName: displayName)

        let session = MCSession(
            peer: mcID,
            securityIdentity: nil,
            encryptionPreference: .optional
        )
        session.delegate = self

        let advertiser = MCNearbyServiceAdvertiser(
            peer: mcID,
            discoveryInfo: nil,
            serviceType: configuration.mcServiceType
        )
        advertiser.delegate = self

        let browser = MCNearbyServiceBrowser(
            peer: mcID,
            serviceType: configuration.mcServiceType
        )
        browser.delegate = self

        lock.withLock {
            self.mcPeerID = mcID
            self.session = session
            self.advertiser = advertiser
            self.browser = browser
        }

        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        logger.info("MultipeerTransport started as \(displayName, privacy: .public)")
    }

    public func stop() async {
        let (session, advertiser, browser) = lock.withLock {
            () -> (MCSession?, MCNearbyServiceAdvertiser?, MCNearbyServiceBrowser?) in
            let s = self.session
            let a = self.advertiser
            let b = self.browser
            self.session?.delegate = nil
            self.advertiser?.delegate = nil
            self.browser?.delegate = nil
            self.session = nil
            self.advertiser = nil
            self.browser = nil
            self.mcPeerID = nil
            self.pcToMC.removeAll()
            self.mcToPC.removeAll()
            return (s, a, b)
        }
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        peersContinuation.yield([])
        logger.info("MultipeerTransport stopped")
    }

    public func send(_ data: Data, to peer: PeerID) async throws {
        let (session, mcPeer) = lock.withLock {
            (self.session, self.pcToMC[peer])
        }
        guard let session, let mcPeer, session.connectedPeers.contains(mcPeer) else {
            throw MultipeerTransportError.notConnected
        }
        try session.send(data, toPeers: [mcPeer], with: .reliable)
    }

    public func broadcast(_ data: Data) async throws {
        let (session, connected) = lock.withLock {
            (self.session, self.session?.connectedPeers ?? [])
        }
        guard let session, !connected.isEmpty else { return }
        try session.send(data, toPeers: connected, with: .reliable)
    }

    public func broadcastUnreliable(_ data: Data) async throws {
        let (session, connected) = lock.withLock {
            (self.session, self.session?.connectedPeers ?? [])
        }
        guard let session, !connected.isEmpty else { return }
        try session.send(data, toPeers: connected, with: .unreliable)
    }

    // MARK: - Internal helpers

    fileprivate func currentPeerSet() -> Set<PeerID> {
        lock.withLock { Set(pcToMC.keys) }
    }
}

// MARK: - Errors

public enum MultipeerTransportError: Error, Sendable {
    case notConnected
}

// MARK: - MCSessionDelegate

extension MultipeerTransport: MCSessionDelegate {

    public func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        guard let pcPeerID = MultipeerIdentity.decode(peerID.displayName) else {
            logger.warning("Ignoring MC peer with non-UUID displayName: \(peerID.displayName, privacy: .public)")
            return
        }

        switch state {
        case .connected:
            lock.withLock {
                pcToMC[pcPeerID] = peerID
                mcToPC[peerID] = pcPeerID
            }
            peersContinuation.yield(currentPeerSet())
            logger.info("MC peer connected: \(pcPeerID.description, privacy: .public)")
        case .notConnected:
            lock.withLock {
                pcToMC.removeValue(forKey: pcPeerID)
                mcToPC.removeValue(forKey: peerID)
            }
            peersContinuation.yield(currentPeerSet())
            logger.info("MC peer disconnected: \(pcPeerID.description, privacy: .public)")
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let pcPeerID = lock.withLock { mcToPC[peerID] }
        guard let pcPeerID else { return }
        incomingMessagesContinuation.yield((pcPeerID, data))
    }

    // Unused resource/stream callbacks (protocol requires empty impls).
    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {

    public func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String : String]?
    ) {
        guard let remotePeerID = MultipeerIdentity.decode(peerID.displayName) else {
            logger.warning("Ignoring found peer with non-UUID displayName: \(peerID.displayName, privacy: .public)")
            return
        }

        // Direction gate: only the smaller PeerID invites.
        guard MultipeerIdentity.shouldInitiateInvitation(local: localPeerID, remote: remotePeerID) else {
            return
        }

        // 8-peer cap + existing-session guard.
        let shouldInvite = lock.withLock { () -> Bool in
            guard let session = self.session else { return false }
            if session.connectedPeers.count >= self.configuration.mcMaxPeers - 1 {
                return false
            }
            if let existing = self.pcToMC[remotePeerID], session.connectedPeers.contains(existing) {
                return false
            }
            return true
        }
        guard shouldInvite else { return }

        lock.withLock { [weak self] in
            guard let self, let session = self.session else { return }
            browser.invitePeer(
                peerID,
                to: session,
                withContext: MultipeerIdentity.invitationContextMarker,
                timeout: 10
            )
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // No-op: the MCSessionState change will drive our peer set updates.
    }

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        logger.error("Browser failed to start: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {

    public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        guard MultipeerIdentity.verifyInvitation(context: context) else {
            logger.warning("Rejecting invitation with bad context from \(peerID.displayName, privacy: .public)")
            invitationHandler(false, nil)
            return
        }
        guard let remotePeerID = MultipeerIdentity.decode(peerID.displayName) else {
            logger.warning("Rejecting invitation with non-UUID displayName: \(peerID.displayName, privacy: .public)")
            invitationHandler(false, nil)
            return
        }

        let (session, accept) = lock.withLock { () -> (MCSession?, Bool) in
            guard let session = self.session else { return (nil, false) }
            if session.connectedPeers.count >= self.configuration.mcMaxPeers - 1 {
                return (session, false)
            }
            if let existing = self.pcToMC[remotePeerID], session.connectedPeers.contains(existing) {
                return (session, false)
            }
            return (session, true)
        }

        guard accept, let session else {
            invitationHandler(false, nil)
            return
        }
        invitationHandler(true, session)
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        logger.error("Advertiser failed to start: \(error.localizedDescription, privacy: .public)")
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -20
```

Expected: clean build. Common issues to fix if they arise:
- `PeerID: Comparable` must already be satisfied — it should be since Phase 1 `shouldInitiateInvitation` compares `local < remote`
- `MultipeerConnectivity` auto-imports on iOS/macOS; on Linux it would fail but PeerClock targets Apple only
- The `browser.invitePeer` call inside `lock.withLock` may issue a framework warning; it's safe because we just use the lock to read `session` — if warnings appear, split the lock read from the call

- [ ] **Step 3: Run full test suite (no new tests here)**

```bash
swift test 2>&1 | tail -5
```

Expected: 87 tests still passing (existing + Task 2 helpers). MultipeerTransport has no unit tests at this stage — it's only exercised manually on real devices in Task 7.

- [ ] **Step 4: Commit**

```bash
git add Sources/PeerClock/Transport/MultipeerTransport.swift
git commit -m "feat(transport): MultipeerTransport with delegate scaffolding"
```

---

## Task 5: Info.plist MPC entries for demo app

**Files:**
- Modify: `Examples/PeerClockDemo/Info.plist`

- [ ] **Step 1: Add MPC Bonjour services**

Find the existing `NSBonjourServices` array:

```xml
    <key>NSBonjourServices</key>
    <array>
        <string>_peerclock._tcp</string>
    </array>
```

Replace with:

```xml
    <key>NSBonjourServices</key>
    <array>
        <string>_peerclock._tcp</string>
        <string>_peerclock-mpc._tcp</string>
        <string>_peerclock-mpc._udp</string>
    </array>
```

(The `NSLocalNetworkUsageDescription` is already set by Phase 1 and is reused.)

- [ ] **Step 2: Xcode build**

```bash
xcodebuild -project /Volumes/Dev/DEVELOP/PeerClock/Examples/PeerClockDemo/PeerClockDemo.xcodeproj -scheme PeerClockDemo -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Examples/PeerClockDemo/Info.plist
git commit -m "feat(demo): add MPC Bonjour services to Info.plist"
```

---

## Task 6: Demo app MC mode toggle

**Files:**
- Modify: `Examples/PeerClockDemo/PeerClockDemo/PeerClockViewModel.swift`
- Modify: `Examples/PeerClockDemo/PeerClockDemo/ContentView.swift`

- [ ] **Step 1: ViewModel に MC モード切替を追加**

Read `PeerClockViewModel.swift` first. Add an observable toggle near the other state:

```swift
    var useMultipeerConnectivity: Bool = false
```

Modify `start()` so the toggle selects the transport factory. Replace the line `let clock = PeerClock()` with:

```swift
        let clock: PeerClock
        if useMultipeerConnectivity {
            clock = PeerClock(transportFactory: { peerID in
                MultipeerTransport(localPeerID: peerID, configuration: .default)
            })
            appendLog("Using MultipeerTransport (MC)")
        } else {
            clock = PeerClock()
            appendLog("Using WiFiTransport (default)")
        }
```

- [ ] **Step 2: ContentView にトグル UI を追加**

Read `ContentView.swift` first. Find the top of the main body (before `syncStatusSection`). Add a new small section:

```swift
            HStack {
                Text("Transport")
                    .font(.headline)
                Spacer()
                Picker("", selection: $viewModel.useMultipeerConnectivity) {
                    Text("WiFi").tag(false)
                    Text("MC").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .disabled(viewModel.runState != .stopped)
            }
            .padding(.horizontal)
```

(The `disabled` prevents switching while the clock is running. The user must Stop before changing transport.)

Since `useMultipeerConnectivity` is a plain `var` on an `@Observable @MainActor` view model, SwiftUI binding works via `$viewModel.useMultipeerConnectivity`.

- [ ] **Step 3: Xcode build**

```bash
xcodebuild -project /Volumes/Dev/DEVELOP/PeerClock/Examples/PeerClockDemo/PeerClockDemo.xcodeproj -scheme PeerClockDemo -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Examples/PeerClockDemo/PeerClockDemo/PeerClockViewModel.swift Examples/PeerClockDemo/PeerClockDemo/ContentView.swift
git commit -m "feat(demo): add WiFi/MC transport toggle"
```

---

## Task 7: Verification (simulator smoke + real-device note)

**Files:** No code changes. Manual verification.

**Important limitation**: iOS Simulator has **no MultipeerConnectivity over Bluetooth/WiFi-Direct** — it only supports MPC over simulated LAN, which means two simulators on the same Mac can sometimes discover each other but the flow is unreliable. Real device testing is the canonical verification for Phase 3b. The simulator test below is a smoke check for "does the app launch + do anything" in MC mode.

- [ ] **Step 1: Deploy & launch**

```bash
APP="/Users/hakaru/Library/Developer/Xcode/DerivedData/PeerClockDemo-drqkujgbdgpwfdblvgcnuecbddks/Build/Products/Debug-iphonesimulator/PeerClockDemo.app"
xcrun simctl terminate AF61223F-58C5-48A3-BF21-54F942BA3C32 net.hakaru.PeerClockDemo 2>/dev/null
xcrun simctl terminate 981BFB44-64A5-476D-88B2-9B34CF8D8762 net.hakaru.PeerClockDemo 2>/dev/null
xcrun simctl install AF61223F-58C5-48A3-BF21-54F942BA3C32 "$APP"
xcrun simctl install 981BFB44-64A5-476D-88B2-9B34CF8D8762 "$APP"
xcrun simctl launch AF61223F-58C5-48A3-BF21-54F942BA3C32 net.hakaru.PeerClockDemo
xcrun simctl launch 981BFB44-64A5-476D-88B2-9B34CF8D8762 net.hakaru.PeerClockDemo
```

- [ ] **Step 2: Simulator smoke checks (user performs)**

1. ✅ Both apps launch successfully
2. ✅ The Transport toggle UI shows "WiFi" / "MC" segmented control
3. ✅ In default (WiFi) mode, Phase 1-3a behaviour works (peers connect, sync, status, schedule)
4. ✅ Switch one or both sims to "MC" and press Start — app should not crash. Log shows "Using MultipeerTransport (MC)". Peer discovery across simulators is best-effort and may not work on all host configurations.
5. ✅ Switch back to WiFi mode → normal operation resumes

- [ ] **Step 3: Real-device verification note**

The real Phase 3b validation happens on **two physical iOS devices**:

1. Turn **WiFi off** on both devices (Bluetooth on)
2. Launch the demo app on both, switch to MC mode, press Start
3. Verify peers discover each other via MPC
4. Verify clock sync, status, heartbeat, and schedule all work through MPC

Physical device testing is out of scope for automated execution and is noted here for manual follow-up.

- [ ] **Step 4: Tag completion**

```bash
git tag -a phase-3b-complete -m "Phase 3b: MultipeerTransport implemented"
```

(don't push)

---

## Self-Review Checklist

- [x] Spec coverage:
  - Configuration MPC fields → Task 1
  - MultipeerIdentity pure helpers → Task 2
  - MCPeerID persistence → Task 3
  - MultipeerTransport implementation (init/start/stop/send/delegates) → Task 4
  - Info.plist update → Task 5
  - Demo app MC toggle → Task 6
  - Verification → Task 7
- [x] No placeholders; all code blocks contain actual code.
- [x] Type consistency: `MultipeerIdentity`, `MultipeerPeerIDStore`, `MultipeerTransport`, `MultipeerTransportError`, `mcServiceType`, `mcMaxPeers`, `invitationContextMarker` are used identically across tasks.
- [x] TDD where practical: Task 2 has tests (pure helpers). Tasks 3-4 are framework-heavy and cannot be unit-tested without extensive mocking, which is out of Phase 3b scope per spec.
- [x] Frequent commits: 7 tasks × 1 commit each.

## Known Risks

1. **`browser.invitePeer` inside `lock.withLock`** (Task 4): holding the NSLock while calling into the framework is a minor lock-inversion risk. In practice MPC is thread-safe and the lock is released immediately. If a deadlock is observed in real-device testing, split into two phases: read `session` under the lock, then call `invitePeer` outside.

2. **MCPeerID persistence race** (Task 3): If multiple processes share the same UserDefaults key (unlikely but possible), the first-write-wins semantics of UserDefaults may cause subtle mismatches. For a single-app scenario this is safe.

3. **Simulator E2E is weak for MPC** (Task 7): iOS simulators cannot use Bluetooth or real WiFi Direct for MPC. Discovery between simulators on the same Mac sometimes works via the shared LAN but is not reliable. Do not interpret simulator flakiness as a Phase 3b bug — the canonical test is real devices.

4. **`peers` stream remains empty** if MPC discovery fails silently (no error callback). Logs via `os_log` are the main debugging path. If real-device testing finds peers not discovering each other, check:
   - Info.plist `NSBonjourServices` is set correctly
   - Both devices have Bluetooth or shared WiFi
   - Both devices run the same `mcServiceType`
   - Local Network permission was granted on first run

5. **8-peer limit** is enforced in both `browser:foundPeer` and `advertiser:didReceiveInvitation`. This creates an asymmetry: if the 9th device's PeerID is smaller than all existing peers, it would try to invite and be rejected-on-the-other-side; if it's larger, it waits for invitations that never come. Either way, the 9th peer simply does not join, which is the intended Phase 3b behaviour.
