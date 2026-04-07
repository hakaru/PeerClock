# PeerClock v2 Design — Peer-Equal Architecture

## Overview

PeerClock は Apple デバイス間の対等ピアツーピア連携基盤。クロック同期・汎用コマンドチャネル・ステータス共有を提供し、任意のアプリがデバイス間の協調動作を構築できるインフラ層となる。

**差別化**: iOS/macOS エコシステムに「対等ピア・クロック同期 + コマンド/ステータス統合基盤」は存在しない（2026-04 時点の調査結果）。既存の NTP クライアント（TrueTime, Kronos）は外部サーバー向け、P2P フレームワーク（PeerKit, sReto）はクロック同期なし。

## Design Principles

- **全ノード対等**: Role の概念を公開 API に露出しない。どのデバイスからでもコマンド送信・ステータス監視が可能
- **内部 coordinator は透過的**: クロック同期に必要な基準時計は自動選出。アプリは意識しない
- **インフラに徹する**: PeerClock はコマンドのセマンティクスを知らない。アプリが定義する
- **境界に Protocol、即座に実装**: テスタビリティと将来の差し替えを確保。実装のないプロトコルは作らない

## Design Decisions

| 決定事項 | 選択 | 理由 |
|---|---|---|
| パッケージ構成 | 1パッケージ | 現段階では分離の必要なし |
| トポロジ | 対等ピア（公開 API に role なし） | 尖った設計。競合なし。最初から対等 |
| Coordinator 選出 | 自動（Phase 1: 最小 PeerID） | 公開 API に露出しない内部メカニズム |
| コマンドチャネル | 汎用（アプリがセマンティクス定義） | 1Take 以外のアプリにも使える |
| ステータス共有 | プッシュ + プル両対応 | 共通ステータス（`pc.*`）+ カスタムステータス |
| ステータス鮮度管理 | 世代番号（monotonic counter） | 再接続時の新旧判定に使用 |
| ワイヤプロトコル | トランスポート非依存の論理メッセージ | reliable / unreliable チャネルで抽象化 |
| ハートビート | Configuration で調整可能 + degraded 状態 | デフォルト値は実機テストで決定 |
| request/response 相関 | 2-byte 相関 ID | Codex レビュー指摘を反映 |

---

## Component Architecture

```
PeerClock (Public Facade — role-free)
│
├── Protocols/
│   ├── Transport          (reliable + unreliable チャネル)
│   ├── SyncEngine         (クロック同期)
│   ├── CommandHandler     (コマンド処理)
│   └── StatusProvider     (ステータス提供)
│
├── Transport/
│   ├── Discovery          (Bonjour: 全ノードが browse + advertise)
│   └── WiFiTransport      (impl: Transport — UDP unreliable, TCP reliable)
│
├── Coordination/
│   ├── CoordinatorElection(自動選出 — 最小 PeerID)
│   └── ElectionProtocol   (選出・降格・昇格メッセージ)
│
├── ClockSync/
│   ├── NTPSyncEngine      (impl: SyncEngine — 4-timestamp + best-half)
│   └── DriftMonitor       (周期再同期、ジャンプ検出)
│
├── Command/
│   ├── CommandRouter      (impl: CommandHandler — 送信/受信/ルーティング)
│   └── CommandCodec       (シリアライズ/デシリアライズ)
│
├── Status/
│   ├── StatusRegistry     (impl: StatusProvider — 共通+カスタム管理)
│   └── StatusBroadcaster  (変化検知 + ブロードキャスト + リクエスト応答)
│
└── EventScheduler/        (Phase 2)
    └── mach_absolute_time ベースの精密発火
```

### File Structure

```
Sources/PeerClock/
├── PeerClock.swift
├── Types.swift
├── Protocols/
│   ├── Transport.swift
│   ├── SyncEngine.swift
│   ├── CommandHandler.swift
│   └── StatusProvider.swift
├── Transport/
│   ├── Discovery.swift
│   └── WiFiTransport.swift
├── Coordination/
│   ├── CoordinatorElection.swift
│   └── ElectionProtocol.swift
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

## Coordinator Election（内部メカニズム）

対等ピアでも、クロック同期には「基準時計」が1つ必要。これを内部で自動選出する。

### 選出ルール（Phase 1）

```
1. 各ピアがユニークな PeerID を持つ（UUID ベース、セッション内で固定）
2. 接続確立時に全ピアが PeerID を交換
3. 最小 PeerID のノードが sync coordinator に
4. Coordinator が離脱 → 残りの中で最小 PeerID が自動昇格
5. 新ノード参加 → PeerID が最小なら coordinator 交代
```

### 公開 API への影響

**なし。** アプリは coordinator の存在を知らない。`PeerClock.now` は誰が coordinator かに関係なく同期済み時刻を返す。

### 将来の進化（Phase 4+）

- 合議ベースの同期（全ペア間で相互測定、中央値を基準）
- ネットワーク品質ベースの選出（最も安定した接続のノードが coordinator）
- 選出アルゴリズムは `CoordinatorElection` に閉じ込められているため差し替え可能

---

## Core Protocols

```swift
protocol Transport: Sendable {
    /// 低レイテンシ、ロス許容（クロック同期用）
    func sendUnreliable(_ data: Data, to peer: PeerID) async throws
    var unreliableMessages: AsyncStream<(PeerID, Data)> { get }

    /// 到達保証（コマンド・ステータス用）
    func sendReliable(_ data: Data, to peer: PeerID) async throws
    var reliableMessages: AsyncStream<(PeerID, Data)> { get }

    /// 接続ライフサイクル
    var connectionEvents: AsyncStream<ConnectionEvent> { get }
}

enum ConnectionEvent: Sendable {
    case peerJoined(PeerID)
    case peerLeft(PeerID)
    case transportDegraded(PeerID)
    case transportRestored(PeerID)
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
    /// 対等ピアとして初期化。Role の指定は不要。
    public init(configuration: Configuration = .default)

    // --- 接続ライフサイクル ---
    public func start() async throws    // Discovery + 接続 + 自動 coordinator 選出 + 同期開始
    public func stop() async

    // --- クロック同期 ---
    public var now: UInt64 { get }                      // 同期済みナノ秒タイムスタンプ
    public var syncState: AsyncStream<SyncState> { get } // idle → syncing → synced → ...

    // --- ピア情報 ---
    public var peers: AsyncStream<[Peer]> { get }       // 接続中ピア一覧（フラット、階層なし）

    // --- コマンド（汎用チャネル） ---
    public func send(_ command: Command, to peer: PeerID) async throws
    public func broadcast(_ command: Command) async throws
    public var commands: AsyncStream<(PeerID, Command)> { get }

    // --- ステータス ---
    // Codable 版（内部で binary plist エンコード。エンコード失敗時は throws）
    public func setStatus<T: Codable & Sendable>(_ value: T, forKey key: String) async throws
    // Raw 版（アプリが自前でシリアライズ）
    public func setStatus(_ data: Data, forKey key: String) async
    // 切断後も最後の既知値を返す。stale 判定は peer.status.connectionState == .disconnected で行う
    public func status(of peer: PeerID) -> PeerStatus?
    // ピア単位、受信側 debounce で集約
    public var statusUpdates: AsyncStream<(PeerID, PeerStatus)> { get }
}
```

### Types

```swift
public struct PeerID: Hashable, Sendable, Comparable {
    public let rawValue: UUID
}

public struct Command: Sendable {
    public let type: String     // アプリが定義する任意の識別子（例: "com.1take.record.start"）
    public let payload: Data    // アプリが定義する任意のペイロード
}

public struct PeerStatus: Sendable {
    public let peerID: PeerID
    public let connectionState: ConnectionState
    public let syncQuality: SyncQuality?
    public let deviceInfo: DeviceInfo
    public let custom: [String: Data]           // アプリ定義のカスタムステータス
    public let generation: UInt64               // 世代番号（新旧判定用）
}

public struct Peer: Sendable, Identifiable {
    public let id: PeerID
    public let name: String
    public let status: PeerStatus
    // role なし — 全ピアが対等
}

public enum ConnectionState: Sendable {
    case connected
    case degraded       // ハートビート不安定
    case disconnected
}

public enum SyncState: Sendable {
    case idle
    case discovering
    case syncing
    case synced(offset: TimeInterval, quality: SyncQuality)
    case error(String)
}

public struct SyncQuality: Sendable {
    public let offsetNs: Int64          // ナノ秒
    public let roundTripDelayNs: UInt64 // ナノ秒
    public let confidence: Double       // 0.0 - 1.0
}

public struct DeviceInfo: Sendable {
    public let name: String
    public let platform: Platform       // .iOS, .macOS
    public let batteryLevel: Double?    // 0.0 - 1.0, macOS は nil
    public let storageAvailable: UInt64 // bytes
}

public enum Platform: Sendable {
    case iOS
    case macOS
}

public struct Configuration: Sendable {
    public var heartbeatInterval: TimeInterval = 1.0
    public var degradedAfter: TimeInterval = 2.0       // 最終受信からの経過時間で判定
    public var disconnectedAfter: TimeInterval = 5.0   // AWDL/BG 瞬断に耐えるため緩め
    public var statusSendDebounce: TimeInterval = 0.1  // 送信側 debounce
    public var statusReceiveDebounce: TimeInterval = 0.05 // 受信側 statusUpdates 集約
    public var syncInterval: TimeInterval = 5.0
    public var syncMeasurements: Int = 40
    public var syncMeasurementInterval: TimeInterval = 0.03
    public var serviceName: String = "_peerclock._udp"

    public static let `default` = Configuration()
}
```

### Usage Example (1Take)

```swift
// 全デバイスで同じコード — role の区別なし
let clock = PeerClock()
try await clock.start()

// ピアが見つかるのを待つ
for await peers in clock.peers {
    if peers.count >= 2 { break }
}

// 全デバイスに録音開始コマンド
try await clock.broadcast(
    Command(type: "com.1take.record.start", payload: config.encoded())
)

// 同期済み時刻で録音タイムスタンプを記録
let timestamp = clock.now

// 各デバイスのカスタムステータスを監視
for await (peerID, status) in clock.statusUpdates {
    if let storage = status.custom["com.1take.storage.remaining"] {
        // ストレージ残量を UI に表示
    }
}
```

---

## Wire Protocol

### 論理メッセージフォーマット（トランスポート非依存）

```
┌─────────┬──────────┬──────────┬──────────┬─────────────┐
│ Version │ Category │ Flags    │ Length   │ Payload     │
│ 1 byte  │ 1 byte   │ 1 byte   │ 2 bytes  │ N bytes     │
└─────────┴──────────┴──────────┴──────────┴─────────────┘
```

- **Version**: プロトコルバージョン（初期値 `0x01`）
- **Category**: メッセージ種別
- **Flags**: 拡張用予約（Codex レビュー指摘を反映。初期値 `0x00`）
- **Length**: ペイロード長（2 bytes, big-endian, 最大 65535 bytes）
- **Payload**: 可変長。整数は全て big-endian。文字列は UTF-8。

#### Unreliable チャネル（クロック同期 + ハートビート）

方向非依存 — どのピアからでも送受信可能。

| Category | 名前 | 用途 |
|---|---|---|
| 0x01 | SYNC_REQUEST | 同期要求（t0 を含む） |
| 0x02 | SYNC_RESPONSE | 同期応答（t0, t1, t2 を含む） |
| 0x03 | HEARTBEAT | 生存通知（各ピアが broadcast、fire-and-forget） |

**ハートビートは unreliable チャネル**（UDP / MCSession `.unreliable`）を使う。理由: TCP 再送・バッファ滞留により「切断検知」が逆に遅延するのを避けるため。順序性・到達保証は不要で「最新が最良」。1 発ロスは次の間隔で即座に補填される。

ペイロード: 24 bytes（UInt64 × 3 タイムスタンプ、mach_continuous_time ナノ秒、big-endian）

Coordinator が SYNC_REQUEST を受け取り SYNC_RESPONSE を返す。どのノードが coordinator かはアプリから不可視。

#### Reliable チャネル（コマンド・ステータス・選出）

| Category | 名前 | 用途 |
|---|---|---|
| 0x10 | SYSTEM_COMMAND | DISCONNECT, DEVICE_INFO（HEARTBEAT は unreliable に移動） |
| 0x11 | ELECTION | Coordinator 選出メッセージ |
| 0x20 | APP_COMMAND | 汎用コマンド |
| 0x30 | STATUS_PUSH | ステータスブロードキャスト |
| 0x31 | STATUS_REQUEST | ステータスリクエスト（相関 ID 付き） |
| 0x32 | STATUS_RESPONSE | ステータス応答（相関 ID 付き） |

#### APP_COMMAND ペイロード

```
┌────────────┬──────────────┬──────────────┐
│ type.len   │ type (UTF-8) │ payload      │
│ 2 bytes    │ N bytes      │ 残り全部     │
└────────────┴──────────────┴──────────────┘
```

- `type.len`: 2 bytes, big-endian
- `type`: UTF-8 文字列
- `payload`: 残りバイト列（アプリが自由に定義）

#### STATUS_REQUEST / STATUS_RESPONSE ペイロード

```
┌──────────────┬──────────────┐
│ correlation  │ body         │
│ 2 bytes      │ 残り全部     │
└──────────────┴──────────────┘
```

- `correlation`: 2 bytes, big-endian。リクエストとレスポンスの紐付け用。

#### STATUS_PUSH / STATUS_RESPONSE body

```
┌──────────┬────────────┬───────────────────────────────────────────────┐
│ entries  │ generation │ [key.len(2) + key(UTF-8) + value.len(2) + value] │
│ 2 bytes  │ 8 bytes    │ 繰り返し                                      │
└──────────┴────────────┴───────────────────────────────────────────────┘
```

- `entries`: エントリ数（2 bytes, big-endian）
- `generation`: 世代番号（8 bytes, big-endian, monotonic counter）
- 各エントリ: `key.len`(2) + `key`(UTF-8) + `value.len`(2) + `value`(bytes)

### ステータスキー名前空間

- `pc.*` — PeerClock 予約（共通ステータス）
  - **Phase 2a で自動プッシュ**: `pc.sync.offset`, `pc.sync.quality`, `pc.device.name`
  - **将来追加候補**: `pc.device.battery`, `pc.device.storage`（Phase 3+）
  - **廃止**: `pc.connection` — 接続状態は `Peer.status.connectionState` のみで公開（観察者視点の情報であり「自分が公開する情報」というステータス層の意味づけと分離するため）
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
- 共通ステータス（`pc.*`）: PeerClock が自動プッシュ
- カスタムステータス: アプリが `setStatus(_:forKey:)` を呼ぶたびにプッシュ
- **送信側 debounce（100ms, 調整可）**: `setStatus` は「dirty」マークだけ付けて即座には送信しない。100ms の flush タイマーでまとめて1つの STATUS_PUSH にする。flush 時に `generation` を +1 して現在の全ローカルステータスのスナップショットを送信
- **generation の進め方**: ピア単位の monotonic counter、**送信スナップショット単位で increment**（キー単位ではない）。受信側は `(peerID, generation)` で古い/重複 push を弾く
- **受信側 debounce（50ms, 調整可）**: `statusUpdates` AsyncStream への配信は同一ピアの連続更新を 50ms 窓で集約し、UI の過剰発火を抑える

### Actor 境界（Swift 6 strict concurrency）

```
[App] ──setStatus──▶ [StatusRegistry: actor] ──push──▶ [Transport]
                          │ (local state + 100ms flush timer)
                          │
[Transport] ──recv──▶ [StatusReceiver: actor] ──debounce──▶ [AsyncStream]
                          │ (remote store + 50ms debounce timer)
                          │
                      [MainActor] ◀── Observation snapshot (facade 経由)
```

- `StatusRegistry` (actor): ローカルステータス保持、送信側 debounce タイマー、generation 発番
- `StatusReceiver` (actor): リモートステータスストア、受信側 debounce タイマー、`statusUpdates` AsyncStream 生成
- `PeerClock` facade: `status(of:)` / `statusUpdates` は `StatusReceiver` から取得。UI 用の Observation スナップショットは将来検討

### プル（オンデマンド）

`status(of:)` 呼び出し時、キャッシュがあればそれを返す。キャッシュの鮮度は `generation` で判定。STATUS_REQUEST に `correlation` ID を付与し、STATUS_RESPONSE で紐付ける。

### 切断検知

```
connected ──(1回ミス)──→ degraded ──(閾値超え)──→ disconnected
    ↑                        │
    └──(応答復帰)─────────────┘
```

- `degraded`: アプリに通知、切断はしない（アプリ側で判断可能）
- `disconnected`: 再接続フローに入る。coordinator だった場合は自動で再選出
- RemoteStatusStore のエントリは保持（最後の既知状態）、stale フラグ付き
- 再接続時にフルステータス交換（`generation` 比較で新旧判定）
- **ハートビート方式（Phase 2a 確定）**: 各ピアが `heartbeatInterval`（既定 1.0s）おきに `HEARTBEAT` を **unreliable broadcast**（片方向、fire-and-forget）。TCP 再送バッファによる検知遅延を避けるため reliable は使わない。受信側は「最後に受信した時刻」を記録し、`degradedAfter`（既定 2.0s）・`disconnectedAfter`（既定 5.0s）で状態遷移。AWDL チャネルホッピングや iOS バックグラウンドの瞬断（〜1s）に耐えるよう保守的に設定。実機テストで調整可能。

---

## Phases

### Phase 1: トランスポート + クロック同期 + コマンド

- `Transport` プロトコル + `WiFiTransport` 実装（reliable / unreliable + connectionEvents）
- Bonjour ディスカバリ（全ノードが browse + advertise）
- `CoordinatorElection`: 最小 PeerID 自動選出
- `NTPSyncEngine`: 4-timestamp exchange + best-half filtering + 周期再同期
- `CommandChannel`: 汎用コマンド送受信（broadcast 含む）
- `PeerClock` facade（role-free API）
- `MockTransport` によるユニットテスト
- 実機2台で動作確認

### Phase 2a: ステータス共有 + ハートビート

- `StatusRegistry` + `StatusBroadcaster`（世代番号、送信側 100ms debounce、受信側 50ms debounce）
- `setStatus` は Codable 版（内部 binary plist）と Raw `Data` 版を並置
- 自動プッシュする共通ステータス: `pc.sync.offset`, `pc.sync.quality`, `pc.device.name`
- `HeartbeatMonitor`: 片方向 HEARTBEAT broadcast + 時間ベース状態遷移
- 接続状態は `Peer.status.connectionState` で公開（`pc.connection` は廃止）
- 切断後も RemoteStatusStore のエントリは保持（最後の既知値）
- 実機テストでハートビートのデフォルト値を調整

### Phase 2b: イベントスケジューリング

#### スコープ
- `EventScheduler` actor + facade 直下の `schedule` API
- `ScheduledEventHandle`（cancel + state 問い合わせ）
- ジャンプ通知用の `schedulerEvents: AsyncStream<SchedulerEvent>`

#### 含まないもの (YAGNI)
- 繰り返し実行（v1 では単発のみ）
- `SyncedInstant` 型ラッパ（命名と doc で防御、必要なら overload 追加可）
- sub-ms 精度（mach_wait_until 二段階化は将来最適化）
- AVAudioSession / Background Tasks 統合
- ドリフト中の動的再照準（決定論的優先、ジャンプ時は警告のみ）

#### 公開 API

```swift
extension PeerClock {
    /// 同期済み時刻で action を発火する。
    /// - parameter atSyncedTime: clock.now と同じ time base (mach_continuous_time + sync offset, ナノ秒)
    /// - 過去時刻は即発火 (state == .missed)
    /// - stop() 時には保留中イベントは全て .cancelled になる
    /// - precision target: ±5ms (1Take の同時録音想定で吸収可能なレンジ)
    /// - **フォアグラウンド前提**。バックグラウンドでの精度は保証しない。
    ///   AVAudioSession 起動中または Background Modes (Audio) 有効時のみ
    ///   `Task.sleep` が継続する。
    /// - **オーディオ用途のアドバイス**: AVAudioEngine 起動には数十 ms 以上
    ///   かかるため、`schedule` で叩く action は「録音開始そのもの」ではなく
    ///   「プリロール完了後のフラグ反転」「書き込み有効化」「サンプルカウント
    ///   同期」など、軽量で即実行可能な処理にすることを推奨する。
    public func schedule(
        atSyncedTime: UInt64,
        _ action: @Sendable @escaping () -> Void
    ) async -> ScheduledEventHandle

    /// クロックジャンプ等の警告イベントを流すストリーム
    public var schedulerEvents: AsyncStream<SchedulerEvent> { get }
}

public struct ScheduledEventHandle: Sendable, Hashable {
    public let id: UUID
    public func cancel() async
    public func state() async -> ScheduledEventState
}
// 注: ScheduledEventHandle は UUID + 内部の弱参照ラッパとして実装する。
// EventScheduler 実体は PeerClock 側が強参照し、ハンドルは UUID と
// scheduler への弱参照のみを持つ。これにより循環参照を回避する。
// cancel/state は内部で `await scheduler?.cancel(id)` / `state(id)` を呼ぶ形。

public enum ScheduledEventState: Sendable {
    case pending     // 待機中
    case fired       // 予定通り発火 (action 実行済み)
    case cancelled   // キャンセル済み (action は実行されていない)
    case missed      // 過去時刻のため即発火扱い (action は実行された、遅刻 fire)
}
// 注: .missed と .fired はどちらも action が実行されたことを示す。
// .missed は「期限切れ即発火」を区別するための情報。action が実行されなかった
// 唯一のターミナル状態は .cancelled。

public enum SchedulerEvent: Sendable {
    /// クロックジャンプ検知。eventID が予約中で、新オフセットで発火時刻が
    /// 当初予定より大きくずれる可能性がある (再照準はしない)。
    /// 用途: アプリは事後に「このイベントは旧タイムラインで発火したため、
    /// 記録タイムスタンプを (newOffsetNs - oldOffsetNs) 分補正する」など
    /// の事後処理ができる。
    case driftWarning(eventID: UUID, oldOffsetNs: Int64, newOffsetNs: Int64)
}
```

#### Time base
**統一**: spec 内で `atSyncedTime` は **常に `clock.now` と同じ time base** (`mach_continuous_time` ナノ秒 + sync offset)。`mach_absolute_time` は使わない (古い記述があれば誤記)。

#### 内部設計
- `EventScheduler` は **actor**。`[UUID: ScheduledEvent]` でイベントを管理
- **1 イベント = 1 Task**: `Task { try? await sleeper.sleep(nanoseconds: delay); await self.tryFire(id) }` の構造。`tryFire` は actor 内メソッドで、guard で state チェックしてから detached fire
- **時刻計算**: `delay = Int64(atSyncedTime) - Int64(now())`、負なら即発火・state を `.missed`

#### Cancel / Fire の race 回避

`tryFire` を **actor 内 atomic** にする:

```swift
// pseudo-code
private func tryFire(_ id: UUID) {
    guard var event = events[id], event.state == .pending else { return }
    // 起床後の現在時刻と当初予定を比較。OS スリープ復帰遅延などで
    // tolerance (例: 10ms) を超えていたら .missed として記録する
    // (action は実行する。.missed は「実用上遅刻」の情報フラグ)。
    let lateness = Int64(now()) - Int64(event.atSyncedTime)
    event.state = (lateness > toleranceNs) ? .missed : .fired
    events[id] = event
    let action = event.action
    Task.detached { action() }
}

public func cancel(_ id: UUID) {
    guard var event = events[id], event.state == .pending else { return }
    event.state = .cancelled
    events[id] = event
    event.task?.cancel()  // sleeper を起こす
}
```

**保証**: actor isolation により、`tryFire` と `cancel` は逐次化される。先に `cancel` が走れば state が `.cancelled` になり、後続の `tryFire` の guard で弾かれる。逆も同じ。`detached` で起動した action は actor 外で動くが、起動の決定自体が actor 内で atomic なので「action 実行された後で state == .cancelled」は発生しない。

#### DriftMonitor 連携

**現状の問題**: 既存 `DriftMonitor.recordOffset()` は `.jumpDetected` を戻り値で返すだけで購読 API なし。`PeerClock` も結果を捨てている。

**Phase 2b で追加**:
1. `DriftMonitor` に `var jumps: AsyncStream<JumpEvent>` を追加 (`recordOffset` 内で yield)
2. `JumpEvent` 型: `oldOffsetNs: Int64`, `newOffsetNs: Int64`
3. `PeerClock.start()` で `DriftMonitor.jumps` を `EventScheduler` に橋渡し
4. `EventScheduler` は jump 受信時、保留中イベントごとに `schedulerEvents` に `.driftWarning` を yield + `os_log` に warning ログ

#### stop と再起動
- **stop**: 全 Task キャンセル、全ハンドル state を `.cancelled` に
- **schedulerEvents continuation**: 既存 facade の `peers` / `syncState` ストリームに合わせ、**init 時に固定保持し stop でも finish しない**。再 start 時にそのまま再利用可

#### 待機実装
- **`Sleeper` プロトコルで sleep を抽象化** (`func sleep(nanoseconds: UInt64) async throws`)
- 本番実装 `RealSleeper`: `Task.sleep(nanoseconds:)` を呼ぶだけ
- テスト実装 `MockSleeper`: イベントを enqueue して、テスト側から `advance(by:)` で進める (HeartbeatMonitor の VirtualClock と同じ思想を sleep に拡張したもの)
- 将来精度要求が上がれば `RealSleeper` を「coarse sleep + 短い mach_wait_until」の二段階に差し替え可能

#### Wire Protocol
- 追加なし。EventScheduler はローカル動作のみ。同期時刻の peer 間共有が必要な場合はアプリが既存の `Command` チャネルで時刻値を送る

#### テスト戦略

**EventScheduler は `now: () -> UInt64` と `Sleeper` を両方注入する。** これによりユニットテストは仮想時計で完全制御可能になる。

- **ユニット (MockSleeper + 仮想 now)**: 実時間を消費しない決定論的テスト
  - 順序: 異なる時刻でスケジュールした複数イベントが指定順で発火
  - cancel: 待機中ハンドルを cancel → MockSleeper を進めても action は呼ばれない
  - state 遷移: pending → fired / cancelled / missed (各遷移を仮想時刻で観測)
  - 期限切れ: schedule 時点で過去時刻 → state == .missed、action 即実行
  - ジャンプ通知: 注入した DriftMonitor から jump イベント注入 → schedulerEvents に `.driftWarning` が届く
  - stop: 保留イベント全て .cancelled、対応する Task もキャンセル
  - cancel/fire race: 同時に cancel と sleeper 完了を起こしても、actor isolation により action が二重実行や cancelled-but-fired にならない
- **統合 (RealSleeper, 短い実時間)**: ms オーダーの実時間で actor + Task.sleep + facade 統合の挙動を検証
  - facade 経由で `clock.schedule(at: clock.now + 100_000_000) { ... }` → 100ms 後に action 実行
  - cancel が実時間でも効く
- **MockNetwork での 2 台統合**: 両 PeerClock が同じ synced time に schedule → ほぼ同時に action 実行 (clock 同期誤差 + scheduler ジッタの合算)
- **実機**: Demo app に「3秒後にビープ」ボタンを追加し、両端の発火タイミングを目視/ログで確認

### Phase 3: レジリエンス

4 サブフェーズに分割して順次実装する:

#### Phase 3a: 再接続 + Coordinator 再選出 (WiFi 単体で完結)

2 層防御アーキテクチャでピアの一時切断からの自動復帰を実現する。

**レイヤ 1: Transport 層の短期リトライ**
- `WiFiTransport` が `NWConnection.stateUpdateHandler` で `.failed` / `.cancelled` を即検知
- `reconnectRetryInterval` (既定 500ms) × `reconnectMaxAttempts` (既定 3) = 最大 1.5s のリトライウィンドウ
- **旧 connection は `cancel()` で完全破棄**し新 connection のみ利用 (並存しない)
- **受信側の Last-In-Win**: Listener が同一 PeerID から新しい inbound connection を受け取った場合、既存の connection を即座に `cancel()` して新しいものに差し替える。これにより dialer 側が旧を破棄しても listener 側に half-open が残る問題を回避する
- **再接続時のハンドシェイク**: 新 connection 確立後、既存と同じ 16-byte PeerID 生送信ハンドシェイクを再実行する。`Message.hello` は現状未使用の残骸で Phase 3a では触らない
- **In-flight メッセージ**: リトライ中の送信要求はエラーを返す (バッファリングしない)。Command は欠落しうる — アプリ側が idempotency を担保する前提。Status は再接続後の `flushNow()` で自動救済される
- リトライ成功時は `peers` ストリームに変化を流さない (同じ PeerID のまま透過復帰)
- リトライ失敗時は `peers` から削除して disconnect イベントを上位へ

**レイヤ 2: 上位層の受動復帰**
- `HeartbeatMonitor` が 5s 無音で `disconnected` 判定 (既存 Phase 2a)
- `Discovery` の Bonjour browser は **常時継続中** なので、ピアが再 advertise すれば `peers` ストリームに自動再登場
- 永久に失われる扱いはしない。タイムアウトなし
- バックストップ: Transport 層がキャッチしそこねた TCP half-open ケースを HeartbeatMonitor がカバー
- **2 層の race 許容**: Transport 層の 1.5s retry 中に heartbeat の 2s degraded / 5s disconnected が進むことは許容する。retry 成功なら HEARTBEAT 受信で自然に `connected` に戻り、retry 失敗ならそのまま disconnected で正しい状態になる。特別な抑止ロジックは不要

**Coordinator 再選出**
- 既存の `CoordinatorElection.updatePeers()` + `runCoordinationLoop` が peer リスト変更を検知して `coordinatorUpdates` に流す仕組みは Phase 1 で実装済み
- **問題点**: 現実装は `transport.peers` の変化だけを起点に再選出する。Phase 2a で追加した `HeartbeatMonitor` の `.disconnected` イベントは election に入っていない。TCP half-open で transport 層が peer を残したまま heartbeat だけが死んだ場合、再選出が走らない
- **Phase 3a の修正**: `runCoordinationLoop` を拡張し、`HeartbeatMonitor.events` の `.disconnected` イベントも `CoordinatorElection.updatePeers()` の入力として使う。具体的には transport.peers と heartbeat state の両方を反映した「effective peer set」を計算して election に渡す
- 再選出パスを**精査 + テスト追加**し、以下を保証:
  - 旧 coordinator が `.disconnected` になった時、新 coordinator 選出が走る (transport.peers 経由でも heartbeat 経由でも)
  - 新 coordinator が自分の場合、`syncEngine.stop()` → `startSyncResponder` に切替
  - 新 coordinator が他 peer の場合、`syncEngine.start(coordinator: newID)` で再同期開始
  - 過渡状態で古い `syncResponderTask` が残らないよう cancel 徹底
- **NTPSyncEngine のステートリセット**: `syncEngine.start(coordinator:)` を呼ぶ時、内部の統計バッファ (RTT 履歴・直前 offset・drift 推定) を**必ず完全リセット**する。これにより follower → coordinator、または異なる coordinator 相手への切替時に古いデータが混入しない。現実装の `stop()` は task を止めるだけなので、Phase 3a でリセットロジックを追加する必要あり

**再接続後のフル同期**

再接続は「ピアの新規参加」として既存 join フローを流用する。peer が再出現した時点で自動的に:

1. `CoordinatorElection.updatePeers()` で coordinator 再計算
2. 新 coordinator 相手に `NTPSyncEngine.start(coordinator:)` で clock sync 再開 (内部統計はリセット済み)
3. **`StatusRegistry.flushNow()` を呼んで** ローカル全ステータスを STATUS_PUSH (Phase 3a で追加する配線)
4. `HeartbeatMonitor.peerJoined(id)` で自動的に `connected` 状態に戻る

「新規参加」と「再接続」の区別は不要。追加実装は `StatusRegistry.flushNow()` 呼び出しのみ。

**flushNow() の呼び出し位置 (N 重複防止)**: `runCoordinationLoop` 内で `for p in added { ... }` の**外**で、`if !added.isEmpty { await statusRegistry.flushNow() }` として 1 回だけ呼ぶ。`flushNow()` は全 peer 向け broadcast なので 1 回で十分で、N 件の join があっても N 回呼んではいけない。必要なら 0-100ms のランダムジッターを挟んでトラフィック集中を避ける

**Configuration 追加項目**
```swift
public var reconnectRetryInterval: TimeInterval = 0.5
public var reconnectMaxAttempts: Int = 3
```

**MockNetwork 拡張** (テスト用)
```swift
public func simulateDisconnect(peer: PeerID)
public func simulateReconnect(peer: PeerID)
```

**テスト戦略**
- ユニット (MockNetwork 拡張): Transport リトライ、重複メッセージ排除、coordinator 再選出 (3 台)、フル再同期、heartbeat 状態復帰
- 実機: シミュレータ 2 台で WiFi OFF/ON、3 台で coordinator を Stop して再選出確認

#### Phase 3b: MultipeerConnectivity トランスポート

- `MultipeerTransport: Transport` 実装
- reliable / unreliable / unicast / broadcast の全経路を MCSession でサポート
- 既存 `Transport` プロトコルに準拠、facade は差し替え可能
- iOS/macOS 共通 API

#### Phase 3c: 自動トランスポート切替

- WiFi → MC フォールバック (ネットワーク非対応環境で MC 有効化)
- トランスポート品質モニタリング (packet loss, RTT)
- 切替判断ロジック
- 切替時のステート引き継ぎ

#### Phase 3d: バックグラウンドモード

- iOS Background Modes (Audio, Voice over IP) との統合
- `Task.sleep` vs `DispatchSourceTimer` の交換が必要か判断
- AVAudioSession 起動中の精度維持
- PeerClock 起動/停止 vs バックグラウンド遷移のライフサイクル

### Phase 4: 高度な同期

- 合議ベースの同期アルゴリズム（全ペア間相互測定）
- ネットワーク品質ベースの coordinator 選出
- クロック品質メトリクス
- 超音波同期マーカー
- watchOS

**フェーズの境界は実装の進捗と実機テスト結果に応じて調整する。**

---

## Clock Sync Algorithm（DESIGN.md より継承）

- NTP 風 4 タイムスタンプ交換: offset = (t1-t0 + t2-t3) / 2
- 30ms 間隔で 40 回測定（初期同期 ~1.2 秒）
- RTT でソートし上位 50% を採用（best-half filtering）
- 5 秒ごとに再同期（水晶発振子ドリフト 20-50ppm 対策）
- オフセット差 >10ms で完全再同期
- 対等ピアでは coordinator がタイムスタンプ応答を担当

## Security

- ローカルネットワーク限定（インターネット非露出）
- v1 では暗号化なし（信頼できるローカルネットワーク前提）
- iOS Local Network permission 必要（`NSLocalNetworkUsageDescription`）
- `NSBonjourServices: ["_peerclock._udp"]`

## Platform Requirements

- iOS 17.0+ / macOS 14+
- Swift 6.0+（strict concurrency）
- Network.framework

## Competitive Landscape (2026-04)

| カテゴリ | プロジェクト | PeerClock との違い |
|---|---|---|
| NTP クライアント | TrueTime, Kronos, swift-ntp | 外部サーバー向け。ピア間同期なし |
| P2P 通信 | PeerKit, sReto, P2PShareKit | 通信のみ。クロック同期なし |
| 音楽向け同期 | TheSpectacularSyncEngine | MIDI 特化、マスター/スレーブ固定 |
| **PeerClock** | — | **対等ピア + クロック同期 + コマンド/ステータス統合。唯一。** |
