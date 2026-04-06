# PeerClock v2 Design — Transport-First Architecture

## Overview

PeerClock を「クロック同期ライブラリ」から「ピアツーピア・デバイス連携基盤」に進化させる。クロック同期に加え、汎用コマンドチャネルとステータス共有を提供し、1Take をはじめとする任意のアプリがデバイス間の協調動作を構築できるインフラ層となる。

## Design Decisions

| 決定事項 | 選択 | 理由 |
|---|---|---|
| パッケージ構成 | 1パッケージ | 現段階では分離の必要なし。必要になったら分割 |
| アーキテクチャ | トランスポートファースト（B） | 全機能が同じ基盤に自然に載る |
| プロトコル抽象 | 境界にだけ Protocol、即座に実装 | テスタビリティ + 将来の差し替え。YAGNI を守る |
| マスター/スレーブ vs 対等ピア | マスター/スレーブで開始、最終形は対等ピア | Phase 4 で探索。進化の余地を残す |
| コマンドチャネル | 汎用（アプリがセマンティクス定義） | 1Take 以外のアプリにも使える |
| ステータス共有 | プッシュ + プル両対応 | 共通ステータス（`pc.*`）+ カスタムステータス |
| ワイヤプロトコル | トランスポート非依存の論理メッセージ | reliable / unreliable チャネルで抽象化 |
| ハートビート | Configuration で調整可能 + degraded 状態 | デフォルト値は実機テストで決定 |

---

## Component Architecture

```
PeerClock (Public Facade)
│
├── Protocols/
│   ├── Transport        (reliable + unreliable チャネル)
│   ├── SyncEngine       (クロック同期)
│   ├── CommandHandler   (コマンド処理)
│   └── StatusProvider   (ステータス提供)
│
├── Transport/
│   ├── Discovery        (Bonjour: NWBrowser / NWListener)
│   └── WiFiTransport    (impl: Transport — UDP unreliable, TCP reliable)
│
├── ClockSync/
│   ├── NTPSyncEngine    (impl: SyncEngine — 4-timestamp + best-half)
│   └── DriftMonitor     (周期再同期、ジャンプ検出)
│
├── Command/
│   ├── CommandRouter    (impl: CommandHandler — 送信/受信/ルーティング)
│   └── CommandCodec     (シリアライズ/デシリアライズ)
│
├── Status/
│   ├── StatusRegistry   (impl: StatusProvider — 共通+カスタム管理)
│   └── StatusBroadcaster(変化検知 + ブロードキャスト + リクエスト応答)
│
└── EventScheduler/      (Phase 2)
    └── mach_absolute_time ベースの精密発火
```

### File Structure

```
Sources/PeerClock/
├── PeerClock.swift
├── Protocols/
│   ├── Transport.swift
│   ├── SyncEngine.swift
│   ├── CommandHandler.swift
│   └── StatusProvider.swift
├── Transport/
│   ├── Discovery.swift
│   └── WiFiTransport.swift
├── ClockSync/
│   ├── NTPSyncEngine.swift
│   └── DriftMonitor.swift
├── Command/
│   ├── CommandRouter.swift
│   └── CommandCodec.swift
├── Status/
│   ├── StatusRegistry.swift
│   └── StatusBroadcaster.swift
└── EventScheduler/
```

---

## Core Protocols

```swift
protocol Transport: Sendable {
    func sendUnreliable(_ data: Data, to peer: PeerID) async throws
    var unreliableMessages: AsyncStream<(PeerID, Data)> { get }
    
    func sendReliable(_ data: Data, to peer: PeerID) async throws
    var reliableMessages: AsyncStream<(PeerID, Data)> { get }
}

protocol SyncEngine: Sendable {
    var currentOffset: TimeInterval { get }
    func start() async
    func stop()
}

protocol CommandHandler: Sendable {
    func handle(_ command: Command, from peer: PeerID) async
}

protocol StatusProvider: Sendable {
    var localStatus: PeerStatus { get }
    func status(of peer: PeerID) -> PeerStatus?
}
```

---

## Public API

```swift
public final class PeerClock: Sendable {
    // 初期化
    public init(role: Role, configuration: Configuration = .default)
    
    // 接続ライフサイクル
    public func start() async throws
    public func stop() async
    
    // クロック同期
    public var now: UInt64 { get }
    public var syncState: AsyncStream<SyncState> { get }
    
    // ピア情報
    public var peers: AsyncStream<[Peer]> { get }
    
    // コマンド（汎用チャネル）
    public func send(_ command: Command, to: PeerID) async throws
    public func send(_ command: Command, toAll: Bool) async throws
    public var commands: AsyncStream<(PeerID, Command)> { get }
    
    // ステータス
    public func registerStatus(_ value: any Codable & Sendable, forKey: String)
    public func status(of peer: PeerID) -> PeerStatus?
    public var statusUpdates: AsyncStream<(PeerID, PeerStatus)> { get }
}
```

### Types

```swift
public enum Role: Sendable { case master, slave }

public struct Command: Sendable {
    public let type: String
    public let payload: Data
}

public struct PeerStatus: Sendable {
    public let peerID: PeerID
    public let connectionState: ConnectionState
    public let syncQuality: SyncQuality?
    public let deviceInfo: DeviceInfo
    public let custom: [String: Data]
}

public struct Peer: Sendable {
    public let id: PeerID
    public let name: String
    public let role: Role
    public let status: PeerStatus
}

public enum ConnectionState: Sendable {
    case connected
    case degraded    // ハートビート不安定
    case disconnected
}

public struct Configuration: Sendable {
    public var heartbeatInterval: TimeInterval = 1.0
    public var disconnectThreshold: Int = 3
    // その他パラメータは実装時に追加
    
    public static let `default` = Configuration()
}
```

---

## Wire Protocol

### 論理メッセージフォーマット（トランスポート非依存）

```
┌─────────┬──────────┬──────────┬─────────────┐
│ Version │ Category │ Length   │ Payload     │
│ 1 byte  │ 1 byte   │ 2 bytes  │ N bytes     │
└─────────┴──────────┴──────────┴─────────────┘
```

#### Unreliable チャネル（クロック同期）

| Category | 名前 | 方向 |
|---|---|---|
| 0x01 | PING | slave → master (carries t0) |
| 0x02 | PONG | master → slave (carries t1, t2) |

ペイロード: 24 bytes（UInt64 × 3 タイムスタンプ、mach_continuous_time ナノ秒）

#### Reliable チャネル（コマンド・ステータス）

| Category | 名前 | 用途 |
|---|---|---|
| 0x10 | SYSTEM_COMMAND | HEARTBEAT, DISCONNECT, DEVICE_INFO |
| 0x20 | APP_COMMAND | 汎用コマンド |
| 0x30 | STATUS_PUSH | ステータスブロードキャスト |
| 0x31 | STATUS_REQUEST | ステータスリクエスト |
| 0x32 | STATUS_RESPONSE | ステータス応答 |

#### APP_COMMAND ペイロード

```
┌────────────┬──────────────┬──────────────┐
│ type.len   │ type (UTF-8) │ payload      │
│ 2 bytes    │ N bytes      │ 残り全部     │
└────────────┴──────────────┴──────────────┘
```

#### STATUS ペイロード

```
┌──────────┬───────────────────────────────────┐
│ entries  │ [key.len + key + value.len + value]│
│ 2 bytes  │ 繰り返し                           │
└──────────┴───────────────────────────────────┘
```

### ステータスキー名前空間

- `pc.*` — PeerClock 予約（共通ステータス）
  - `pc.connection`, `pc.sync.offset`, `pc.sync.quality`
  - `pc.device.name`, `pc.device.battery`, `pc.device.storage`
- それ以外 — アプリ定義（例: `com.1take.recording.state`）

### Transport マッピング

| 論理チャネル | WiFiTransport | MultipeerTransport (Phase 3) |
|---|---|---|
| unreliable | UDP (NWConnection) | MCSession `.unreliable` |
| reliable | TCP (NWConnection) | MCSession `.reliable` |

---

## Status Lifecycle

### プッシュ（自動）

状態変化時に StatusBroadcaster が reliable チャネルで全ピアに STATUS_PUSH を送信。
- 共通ステータス: PeerClock が自動プッシュ
- カスタムステータス: アプリが `registerStatus(_:forKey:)` を呼ぶたびにプッシュ

### プル（オンデマンド）

`status(of:)` 呼び出し時、キャッシュが古ければ STATUS_REQUEST → STATUS_RESPONSE。

### 切断検知

```
connected ──(1回ミス)──→ degraded ──(閾値超え)──→ disconnected
    ↑                        │
    └──(応答復帰)─────────────┘
```

- `degraded`: アプリに通知、切断はしない（アプリ側で判断可能）
- `disconnected`: 再接続フローに入る
- RemoteStatusStore のエントリは保持（最後の既知状態）、stale フラグ付き
- 再接続時にフルステータス交換で同期
- **ハートビートのデフォルト値（間隔・閾値）は Phase 1 の実機テストで決定**

---

## Phases

### Phase 1: トランスポート + クロック同期 + 基本コマンド

- `Transport` プロトコル + `WiFiTransport` 実装
- Bonjour ディスカバリ（master/slave）
- `NTPSyncEngine`: 4-timestamp exchange + best-half filtering + 周期再同期
- `CommandChannel`: 汎用コマンド送受信
- `PeerClock` facade（start/stop/now/send/commands）
- `MockTransport` によるユニットテスト
- 実機2台でクロック同期 + コマンド送受信の動作確認

### Phase 2: ステータス + イベントスケジューリング

- `StatusRegistry` + `StatusBroadcaster`
- ハートビート + connected/degraded/disconnected 状態遷移
- `EventScheduler`: mach_absolute_time ベース精密発火
- 実機テストでハートビートのデフォルト値を決定

### Phase 3: レジリエンス

- `MultipeerTransport: Transport`
- 自動トランスポート切替
- 再接続ロジック
- バックグラウンドモード

### Phase 4: 対等ピア探索

- マルチマスター選出 / 対等ピアモデルの実験
- クロック品質メトリクス
- 超音波同期マーカー
- watchOS

**フェーズの境界は実装の進捗と実機テスト結果に応じて調整する。**

---

## Relation to Existing DESIGN.md

この設計は `docs/DESIGN.md` を置き換えるものではなく、拡張する。DESIGN.md のクロック同期アルゴリズム、ドリフト分析、障害モード、セキュリティ考慮、プラットフォーム要件はそのまま有効。本ドキュメントは以下を追加:

- トランスポート抽象化（Protocol ベース）
- 汎用コマンドチャネル
- ステータス共有（プッシュ + プル）
- 改訂フェーズ構成
- 拡張ワイヤプロトコル
