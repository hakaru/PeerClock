# Demo Apps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PeerClock Phase 1 の実機検証用に、macOS CLI デモと iOS ダッシュボードアプリを構築する。

**Architecture:** macOS CLI は Package.swift に `executableTarget` として追加、ライブラリと同じリポジトリ内で `swift run` で即実行可能。iOS アプリは `Examples/PeerClockDemo/` に独立した Xcode プロジェクトとして作成、ライブラリを local package として参照。SwiftUI + `@Observable` ViewModel。

**Tech Stack:** Swift 6.0, Swift Package Manager, SwiftUI, Xcode, Network.framework (PeerClock 経由)

**Spec:** `docs/superpowers/specs/2026-04-07-demo-apps-design.md`

---

## File Map

| ファイル | 責務 | Task |
|---|---|---|
| `Package.swift` | CLI executable target 追加 | 1 |
| `Sources/PeerClockCLI/main.swift` | CLI エントリ、stdin ループ、ログ出力 | 1 |
| `Examples/PeerClockDemo/PeerClockDemo.xcodeproj` | Xcode プロジェクト | 2 |
| `Examples/PeerClockDemo/PeerClockDemo/PeerClockDemoApp.swift` | App エントリ | 2 |
| `Examples/PeerClockDemo/PeerClockDemo/PeerClockViewModel.swift` | `@Observable` ステート管理 | 3 |
| `Examples/PeerClockDemo/PeerClockDemo/ContentView.swift` | ダッシュボード UI | 4 |
| `Examples/PeerClockDemo/PeerClockDemo/Info.plist` | Bonjour + Local Network permission | 2 |

---

### Task 1: macOS CLI (`PeerClockCLI`)

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PeerClockCLI/main.swift`

- [ ] **Step 1: Package.swift に executable target を追加**

`Package.swift` の `targets:` 配列に追加（既存の `.target(name: "PeerClock", ...)` の後ろ、`.testTarget(...)` の前）:

```swift
.executableTarget(
    name: "PeerClockCLI",
    dependencies: ["PeerClock"],
    path: "Sources/PeerClockCLI"
),
```

そして `products:` 配列に追加:

```swift
.executable(name: "PeerClockCLI", targets: ["PeerClockCLI"]),
```

最終的な Package.swift は次の形:

```swift
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
        .executable(name: "PeerClockCLI", targets: ["PeerClockCLI"]),
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
```

- [ ] **Step 2: main.swift を作成**

```swift
// Sources/PeerClockCLI/main.swift
import Foundation
import PeerClock

@main
struct PeerClockCLI {
    static func main() async {
        let clock = PeerClock()

        log("Local peer: \(clock.localPeerID)")
        log("Starting...")

        do {
            try await clock.start()
        } catch {
            log("ERROR: failed to start: \(error)")
            return
        }

        log("Discovering peers on local network (_peerclock._tcp)...")

        // Monitor sync state
        Task {
            for await state in clock.syncState {
                switch state {
                case .idle:
                    log("Sync state: idle")
                case .discovering:
                    log("Sync state: discovering")
                case .syncing:
                    log("Sync state: syncing")
                case .synced(let offset, let quality):
                    let offsetMs = offset * 1000
                    let rttMs = Double(quality.roundTripDelayNs) / 1_000_000
                    log(String(
                        format: "Synced: offset=%+.2fms, RTT=%.2fms, confidence=%.2f",
                        offsetMs, rttMs, quality.confidence
                    ))
                case .error(let message):
                    log("Sync error: \(message)")
                }
            }
        }

        // Monitor peers
        Task {
            for await peers in clock.peers {
                let names = peers.map { "\($0.id)" }.joined(separator: ", ")
                log("Peers (\(peers.count)): [\(names)]")
            }
        }

        // Monitor incoming commands
        Task {
            for await (sender, command) in clock.commands {
                let payloadStr = String(data: command.payload, encoding: .utf8) ?? "<binary>"
                log("Received: \(command.type) \"\(payloadStr)\" from \(sender)")
            }
        }

        // stdin command loop
        log("Type 'help' for commands.")
        while let line = readLine() {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let cmd = parts.first else { continue }

            switch cmd {
            case "help":
                print("Commands: send <message>, peers, status, quit")
            case "send":
                let message = parts.count > 1 ? parts[1] : ""
                let command = Command(
                    type: "com.demo.message",
                    payload: Data(message.utf8)
                )
                do {
                    try await clock.broadcast(command)
                    log("Broadcast: com.demo.message \"\(message)\"")
                } catch {
                    log("ERROR: broadcast failed: \(error)")
                }
            case "peers":
                // Snapshot would require a peers getter; we rely on the stream above.
                log("(peers are reported continuously above)")
            case "status":
                if let coord = clock.coordinatorID {
                    let isSelf = coord == clock.localPeerID
                    log("Coordinator: \(coord)\(isSelf ? " (self)" : "")")
                } else {
                    log("Coordinator: none")
                }
                log("Current now: \(clock.now) ns")
            case "quit":
                log("Stopping...")
                await clock.stop()
                log("Stopped.")
                return
            default:
                print("Unknown command: \(cmd). Type 'help'.")
            }
        }

        await clock.stop()
    }

    static func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        print("[\(timestamp)] \(message)")
    }
}
```

- [ ] **Step 3: ビルド確認**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete!

- [ ] **Step 4: テストが引き続き通ることを確認**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with 37 tests in 7 suites passed`

- [ ] **Step 5: CLI の起動確認（単一プロセス、すぐ quit で終了）**

Run: `echo "quit" | swift run PeerClockCLI 2>&1 | tail -10`
Expected: CLI が起動してログを出力し、`Stopped.` で正常終了する。エラーが出なければ OK。Bonjour permission ダイアログが出る可能性があるので、初回は `swift run PeerClockCLI` を直接実行して許可してから再テスト。

- [ ] **Step 6: コミット**

```bash
git add Package.swift Sources/PeerClockCLI/
git commit -m "feat(cli): add PeerClockCLI executable target for macOS verification"
```

---

### Task 2: iOS Xcode プロジェクトの作成（手動ステップ）

注意: Xcode プロジェクトの作成はコマンドラインから完全自動化することが難しいため、このタスクは **ユーザーに Xcode GUI で実施してもらうステップ + エージェントが書くファイル** の混成構成。

**Files:**
- Create: `Examples/PeerClockDemo/PeerClockDemo.xcodeproj` (Xcode GUI 経由で作成)
- Create: `Examples/PeerClockDemo/PeerClockDemo/PeerClockDemoApp.swift`
- Create: `Examples/PeerClockDemo/PeerClockDemo/Info.plist`

- [ ] **Step 1: Examples ディレクトリを作る**

```bash
mkdir -p Examples
```

- [ ] **Step 2: Xcode で新規プロジェクト作成（手動）**

**ユーザーが Xcode で実施:**
1. Xcode を開く
2. File → New → Project
3. iOS → App を選択
4. Product Name: `PeerClockDemo`
5. Interface: SwiftUI
6. Language: Swift
7. Storage: None
8. 保存先: `/Volumes/Dev/DEVELOP/PeerClock/Examples/` を選択（`Create Git repository` は**オフ**にする — 親リポジトリに含める）
9. 作成後、プロジェクトを開いたまま次のステップへ

**期待される結果:** `Examples/PeerClockDemo/PeerClockDemo.xcodeproj` と `Examples/PeerClockDemo/PeerClockDemo/` ディレクトリが作成される。

- [ ] **Step 3: PeerClock を local package として追加（手動）**

**ユーザーが Xcode で実施:**
1. Xcode のプロジェクトナビゲーター → プロジェクト名をクリック
2. Package Dependencies タブ → `+` ボタン
3. 左下の "Add Local..." をクリック
4. `/Volumes/Dev/DEVELOP/PeerClock` を選択 → Add Package
5. ターゲット `PeerClockDemo` にチェックを入れて Add Package
6. 左側のプロジェクトナビゲーターで Target `PeerClockDemo` → General → Frameworks, Libraries, and Embedded Content に `PeerClock` が追加されていることを確認

- [ ] **Step 4: Info.plist に Bonjour + Local Network permission を追加（手動）**

**ユーザーが Xcode で実施:**
1. Target `PeerClockDemo` → Info タブ
2. `Custom iOS Target Properties` で `+` をクリックして以下のキーを追加:
   - Key: `Privacy - Local Network Usage Description` (`NSLocalNetworkUsageDescription`)
     Value: `PeerClock uses the local network to discover and synchronize with nearby devices.`
   - Key: `Bonjour services` (`NSBonjourServices`)
     Type: Array
     Item 0: `_peerclock._tcp`

- [ ] **Step 5: PeerClockDemoApp.swift を置き換え**

Xcode が自動生成した `Examples/PeerClockDemo/PeerClockDemo/PeerClockDemoApp.swift` を以下の内容に置き換える:

```swift
import SwiftUI

@main
struct PeerClockDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

(Xcode が既にこれと同じものを生成しているはず。`ContentView()` の参照はあるが、ContentView 自体は Task 4 で書き換える。)

- [ ] **Step 6: ビルド確認（手動）**

**ユーザーが Xcode で実施:**
1. Scheme を `PeerClockDemo` + 任意の iOS Simulator に設定
2. Cmd+B でビルド
3. エラーが出ないことを確認（この時点で ContentView はまだデフォルトのものなので、警告のみのはず）

- [ ] **Step 7: コミット**

```bash
git add Examples/
git commit -m "feat(demo): scaffold iOS Xcode project with PeerClock local package"
```

---

### Task 3: PeerClockViewModel (`@Observable`)

**Files:**
- Create: `Examples/PeerClockDemo/PeerClockDemo/PeerClockViewModel.swift`

- [ ] **Step 1: PeerClockViewModel.swift を作成**

```swift
// Examples/PeerClockDemo/PeerClockDemo/PeerClockViewModel.swift
import Foundation
import Observation
import PeerClock

@Observable
@MainActor
final class PeerClockViewModel {

    // MARK: - Public State

    enum RunState {
        case stopped
        case starting
        case running
        case error(String)
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
    }

    struct CommandLogEntry: Identifiable {
        enum Direction { case sent, received }
        let id = UUID()
        let timestamp: Date
        let direction: Direction
        let peerLabel: String
        let type: String
        let payload: String
    }

    private(set) var runState: RunState = .stopped
    private(set) var localPeerID: String = "-"
    private(set) var coordinatorLabel: String = "none"
    private(set) var isLocalCoordinator: Bool = false
    private(set) var syncStateLabel: String = "idle"
    private(set) var syncOffsetMs: Double = 0
    private(set) var syncConfidence: Double = 0
    private(set) var syncRoundTripMs: Double = 0
    private(set) var peers: [String] = []
    private(set) var logs: [LogEntry] = []
    private(set) var commandLog: [CommandLogEntry] = []

    // MARK: - Private

    private var clock: PeerClock?
    private var syncStateTask: Task<Void, Never>?
    private var peersTask: Task<Void, Never>?
    private var commandsTask: Task<Void, Never>?
    private var coordinatorPollTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() async {
        guard case .stopped = runState else { return }
        runState = .starting

        let clock = PeerClock()
        self.clock = clock
        self.localPeerID = "\(clock.localPeerID)"
        appendLog("Starting PeerClock (peer: \(localPeerID))")

        do {
            try await clock.start()
        } catch {
            runState = .error("start failed: \(error.localizedDescription)")
            appendLog("ERROR: \(error.localizedDescription)")
            return
        }

        runState = .running
        appendLog("Running. Discovering peers...")

        syncStateTask = Task { [weak self] in
            guard let self, let clock = await self.clock else { return }
            for await state in clock.syncState {
                await self.handleSyncState(state)
            }
        }

        peersTask = Task { [weak self] in
            guard let self, let clock = await self.clock else { return }
            for await peers in clock.peers {
                await self.handlePeers(peers)
            }
        }

        commandsTask = Task { [weak self] in
            guard let self, let clock = await self.clock else { return }
            for await (sender, command) in clock.commands {
                await self.handleCommand(from: sender, command: command)
            }
        }

        coordinatorPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let clock = await self.clock else { return }
                let coord = clock.coordinatorID
                await self.updateCoordinator(coord)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() async {
        syncStateTask?.cancel()
        peersTask?.cancel()
        commandsTask?.cancel()
        coordinatorPollTask?.cancel()
        await clock?.stop()
        clock = nil
        runState = .stopped
        appendLog("Stopped.")
    }

    // MARK: - Broadcast

    func broadcastPing() async {
        guard let clock else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let command = Command(
            type: "com.demo.ping",
            payload: Data(timestamp.utf8)
        )
        do {
            try await clock.broadcast(command)
            commandLog.insert(
                CommandLogEntry(
                    timestamp: Date(),
                    direction: .sent,
                    peerLabel: "all",
                    type: command.type,
                    payload: timestamp
                ),
                at: 0
            )
            appendLog("Broadcast: \(command.type)")
        } catch {
            appendLog("ERROR: broadcast failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Handlers

    private func handleSyncState(_ state: SyncState) {
        switch state {
        case .idle:
            syncStateLabel = "idle"
        case .discovering:
            syncStateLabel = "discovering"
        case .syncing:
            syncStateLabel = "syncing"
        case .synced(let offset, let quality):
            syncStateLabel = "synced"
            syncOffsetMs = offset * 1000
            syncConfidence = quality.confidence
            syncRoundTripMs = Double(quality.roundTripDelayNs) / 1_000_000
            appendLog(String(
                format: "Synced: offset=%+.2fms, RTT=%.2fms, conf=%.2f",
                syncOffsetMs, syncRoundTripMs, syncConfidence
            ))
        case .error(let msg):
            syncStateLabel = "error"
            appendLog("Sync error: \(msg)")
        }
    }

    private func handlePeers(_ newPeers: [Peer]) {
        peers = newPeers.map { "\($0.id)" }
        appendLog("Peers: \(peers.count) connected")
    }

    private func handleCommand(from sender: PeerID, command: Command) {
        let payloadStr = String(data: command.payload, encoding: .utf8) ?? "<binary>"
        commandLog.insert(
            CommandLogEntry(
                timestamp: Date(),
                direction: .received,
                peerLabel: "\(sender)",
                type: command.type,
                payload: payloadStr
            ),
            at: 0
        )
        appendLog("Received: \(command.type) from \(sender)")
    }

    private func updateCoordinator(_ coord: PeerID?) {
        if let coord {
            coordinatorLabel = "\(coord)"
            isLocalCoordinator = (coord == clock?.localPeerID)
        } else {
            coordinatorLabel = "none"
            isLocalCoordinator = false
        }
    }

    private func appendLog(_ message: String) {
        logs.insert(LogEntry(timestamp: Date(), message: message), at: 0)
        if logs.count > 200 {
            logs.removeLast(logs.count - 200)
        }
    }
}
```

- [ ] **Step 2: ビルド確認（手動）**

**ユーザーが Xcode で Cmd+B を実行**
Expected: ビルド成功（ContentView が古いままで警告が出る可能性はあるが、ViewModel 自体はビルドできる）

- [ ] **Step 3: コミット**

```bash
git add Examples/PeerClockDemo/PeerClockDemo/PeerClockViewModel.swift
git commit -m "feat(demo): add PeerClockViewModel with @Observable state"
```

---

### Task 4: ContentView ダッシュボード UI

**Files:**
- Modify: `Examples/PeerClockDemo/PeerClockDemo/ContentView.swift` (Xcode が生成したものを全面置き換え)

- [ ] **Step 1: ContentView.swift を置き換え**

```swift
// Examples/PeerClockDemo/PeerClockDemo/ContentView.swift
import SwiftUI
import PeerClock

struct ContentView: View {
    @State private var viewModel = PeerClockViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    syncStatusSection
                    peersSection
                    commandsSection
                    logSection
                }
                .padding()
            }
            .navigationTitle("PeerClock Demo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            switch viewModel.runState {
                            case .stopped, .error:
                                await viewModel.start()
                            case .running:
                                await viewModel.stop()
                            case .starting:
                                break
                            }
                        }
                    } label: {
                        switch viewModel.runState {
                        case .stopped, .error:
                            Label("Start", systemImage: "play.circle.fill")
                        case .starting:
                            ProgressView()
                        case .running:
                            Label("Stop", systemImage: "stop.circle.fill")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var syncStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sync Status")
                .font(.headline)

            HStack {
                Circle()
                    .fill(syncColor)
                    .frame(width: 12, height: 12)
                Text(viewModel.syncStateLabel)
                    .font(.body)
                Spacer()
                if viewModel.syncStateLabel == "synced" {
                    Text(String(format: "%+.2fms", viewModel.syncOffsetMs))
                        .font(.system(.body, design: .monospaced))
                    Text(String(format: "%.0f%%", viewModel.syncConfidence * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Coordinator:")
                    .foregroundStyle(.secondary)
                Text(viewModel.coordinatorLabel)
                    .font(.system(.caption, design: .monospaced))
                if viewModel.isLocalCoordinator {
                    Text("(self)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack {
                Text("Local:")
                    .foregroundStyle(.secondary)
                Text(viewModel.localPeerID)
                    .font(.system(.caption, design: .monospaced))
                Spacer()
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var syncColor: Color {
        switch viewModel.syncStateLabel {
        case "synced": return .green
        case "syncing": return .yellow
        case "discovering": return .blue
        case "error": return .red
        default: return .gray
        }
    }

    private var peersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Peers (\(viewModel.peers.count))")
                .font(.headline)

            if viewModel.peers.isEmpty {
                Text("No peers connected")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(viewModel.peers, id: \.self) { peer in
                    HStack {
                        Image(systemName: "iphone")
                        Text(peer)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var commandsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Commands")
                    .font(.headline)
                Spacer()
                Button("Broadcast Ping") {
                    Task { await viewModel.broadcastPing() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!isRunning)
            }

            if viewModel.commandLog.isEmpty {
                Text("No commands yet")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(viewModel.commandLog.prefix(10)) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: entry.direction == .sent
                              ? "arrow.up.circle.fill"
                              : "arrow.down.circle.fill")
                            .foregroundStyle(entry.direction == .sent ? .blue : .green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.type)
                                .font(.caption.bold())
                            Text(entry.payload)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(entry.peerLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Log")
                .font(.headline)

            if viewModel.logs.isEmpty {
                Text("No log entries")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(viewModel.logs.prefix(20)) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text(Self.timeFormatter.string(from: entry.timestamp))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.caption)
                        Spacer()
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var isRunning: Bool {
        if case .running = viewModel.runState { return true }
        return false
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

#Preview {
    ContentView()
}
```

- [ ] **Step 2: ビルド確認（手動）**

**ユーザーが Xcode で Cmd+B を実行**
Expected: ビルド成功。プレビューが表示される（実際のピア接続はシミュレーターで限定的）

- [ ] **Step 3: シミュレーター起動テスト（手動）**

**ユーザーが Xcode で Cmd+R を実行**
Expected: アプリが起動、Start ボタンを押すと `.discovering` 状態になる。シミュレーター単体ではピアは見つからないが、エラーなく動くこと。

- [ ] **Step 4: コミット**

```bash
git add Examples/PeerClockDemo/PeerClockDemo/ContentView.swift
git commit -m "feat(demo): add SwiftUI dashboard with sync status, peers, commands, log"
```

---

### Task 5: 実機検証

注意: このタスクは実機 2 台が必要な手動検証。コード変更はなく、観測結果の記録のみ。

- [ ] **Step 1: macOS 2 プロセステスト**

ターミナルを 2 つ開いて:

```bash
# Terminal 1
swift run PeerClockCLI

# Terminal 2
swift run PeerClockCLI
```

**観測ポイント:**
- 両プロセスが相互にピアを発見する（初回は Bonjour permission ダイアログが出る可能性あり）
- Coordinator が片方に収束する
- `Synced: offset=...` ログが両プロセスで出力される
- Terminal 1 で `send hello` → Terminal 2 で `Received: com.demo.message "hello"` が出る
- `quit` で正常終了

- [ ] **Step 2: iOS 2 台テスト**

2 台の iPhone を同じ Wi-Fi に接続し、Xcode から `PeerClockDemo` をそれぞれビルド＆インストール（デバイスを切り替えて Run）:

```bash
# Xcode で device 1 を選択 → Cmd+R
# Xcode で device 2 を選択 → Cmd+R
```

**観測ポイント:**
- 初回起動時に Local Network permission ダイアログを許可
- Start ボタンを押す → `discovering` → `synced` に遷移
- Peers セクションに相手のデバイスが表示される
- Coordinator が片方に収束し、両デバイスで同じ値が表示される
- Broadcast Ping ボタンで相手デバイスの Commands ログに受信が現れる

- [ ] **Step 3: macOS + iOS 混在テスト**

macOS CLI と iOS デバイスを同じ Wi-Fi で同時起動。相互発見を確認。

- [ ] **Step 4: ネガティブ・エッジケース**

以下を順に試して挙動を観測:
- **Permission 拒否**: iOS 初回起動で Local Network permission を拒否 → Start 後にエラーログが出ること
- **ピア離脱**: 2 台接続済みで片方のアプリを停止 → もう片方で peers カウントが減ること
- **Coordinator 再選出**: coordinator 役のピアを停止 → 残ったピアが新 coordinator になること
- **Start→Stop→Start 往復**: Stop ボタンを押して再度 Start → 問題なく再接続すること
- **同時起動レース**: 2 台をほぼ同時に Start → 両方で同じ coordinator に収束すること

- [ ] **Step 5: 観測結果のメモを追加（任意）**

実機テストで気づいた点があれば `docs/superpowers/specs/2026-04-07-demo-apps-design.md` に "Real-Device Observations" セクションを追加してメモする。

- [ ] **Step 6: 検証完了コミット（テスト結果メモがあれば）**

```bash
git add docs/superpowers/specs/2026-04-07-demo-apps-design.md
git commit -m "docs(demo): add real-device verification observations"
```

---

## Post-Implementation

### 全テスト最終確認

```bash
swift test
```

Expected: `Test run with 37 tests in 7 suites passed`

### ビルド最終確認

```bash
swift build
```

Expected: Build complete!

### リポジトリ状態

```bash
git log --oneline | head -10
```

Expected: 上から順に Task 5 → Task 4 → Task 3 → Task 2 → Task 1 のコミットが並ぶ。
