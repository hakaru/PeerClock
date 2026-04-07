# Demo Apps Design — macOS CLI + iOS Dashboard

## Overview

PeerClock Phase 1 の実機検証用デモアプリ。macOS CLI で素早くロジック検証、iOS アプリでダッシュボード表示付きの実機テスト。

## Pre-requisite Library Changes (Codex レビュー指摘の反映)

デモ実装前に、ライブラリ側に以下の変更を入れる：

1. **Bonjour サービス型の修正**: `_peerclock._udp` → `_peerclock._tcp`。Discovery は TCP listener を使うため、プロトコル suffix は `._tcp` でなければ Bonjour 発見が動作しない。`Configuration.serviceName` のデフォルト値を更新
2. **`PeerClock.coordinatorID: PeerID?` を公開**: ダッシュボードに現在の coordinator を表示するため。内部の `currentCoordinator` への read-only アクセサ
3. **`Peer.platform` の正確化（Phase 2 で対応）**: 現在 hardcoded `.iOS` になっているため、macOS と区別できない。本スペックの範囲では対応しない

## 1. macOS CLI (`PeerClockCLI`)

Package.swift に executable ターゲットとして追加。ターミナル2つで同時実行。

### 機能

- 起動時に `PeerClock()` を初期化して `start()`
- ピア発見・同期状態・コマンド受信をリアルタイムにログ出力
- stdin から対話コマンド: `send <message>`, `peers`, `status`, `quit`（`sync` は対応 API なしのため削除。`status` は coordinator とオフセットを表示）

### ファイル

- `Sources/PeerClockCLI/main.swift` — エントリポイント、stdin ループ、ログ出力

### 出力例

```
[PeerClock CLI] Local peer: 3a4b5c6d
[PeerClock CLI] Discovering peers...
[PeerClock CLI] Peer joined: 7e8f9a0b
[PeerClock CLI] Coordinator elected: 3a4b5c6d (self)
[PeerClock CLI] Synced: offset=+0.42ms, RTT=1.2ms, confidence=0.85
> send hello
[PeerClock CLI] Broadcast: com.demo.message "hello"
[PeerClock CLI] Received: com.demo.message "hello" from 7e8f9a0b
> peers
[PeerClock CLI] Connected peers: 3a4b5c6d (self), 7e8f9a0b
> status
[PeerClock CLI] Coordinator: 3a4b5c6d (self)
[PeerClock CLI] Sync: synced, offset=+0.42ms
> quit
[PeerClock CLI] Stopped.
```

## 2. iOS App (`PeerClockDemo`)

`Examples/PeerClockDemo/` に Xcode プロジェクト。PeerClock を local package として参照。SwiftUI、1画面構成。

### 画面構成

**Sync Status セクション:**
- 接続状態インジケーター（idle/discovering/syncing/synced を色で表示）
- オフセット値（ms）
- Confidence（%）
- 現在の coordinator PeerID

**Peers セクション:**
- 接続中ピアのリスト（PeerID + 自分のマーク）

**Commands セクション:**
- Broadcast ボタン（タップで `com.demo.ping` コマンドを全ピアに送信、payload は現在時刻文字列）
- 送受信コマンドのログ（タイムスタンプ + 方向 + 内容）

Command 生成ルール: `Command(type: "com.demo.ping", payload: Data("<ISO8601 timestamp>".utf8))`

**Log セクション:**
- 全イベントの時系列ログ（スクロール可能）

**ナビゲーションバー:**
- Start/Stop トグルボタン

### ファイル

- `PeerClockDemoApp.swift` — App エントリポイント
- `ContentView.swift` — 1画面のダッシュボード UI
- `PeerClockViewModel.swift` — PeerClock の状態を @Observable で管理
- `Info.plist` — `NSLocalNetworkUsageDescription`, `NSBonjourServices`

### Info.plist 設定

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>PeerClock uses the local network to discover and synchronize with nearby devices.</string>
<key>NSBonjourServices</key>
<array>
    <string>_peerclock._tcp</string>
</array>
```

## Package.swift 変更

```swift
targets: [
    .target(name: "PeerClock", path: "Sources/PeerClock"),
    .executableTarget(
        name: "PeerClockCLI",
        dependencies: ["PeerClock"],
        path: "Sources/PeerClockCLI"
    ),
    .testTarget(...)
]
```

## 検証シナリオ

### ポジティブケース

1. **macOS 2プロセス**: ターミナル2つで `swift run PeerClockCLI` → 相互発見 → 同期 → コマンド送受信
2. **iOS 2台**: 同一 Wi-Fi に接続 → アプリ起動 → ダッシュボードで同期状態とピア確認 → Broadcast テスト
3. **macOS + iOS**: CLI と iOS アプリの混在テスト

### ネガティブ / エッジケース

4. **iOS Local Network permission 拒否**: アプリ初回起動でダイアログを拒否 → `start()` のエラー表示を確認
5. **ピア離脱**: 2台接続済みの状態で片方を停止 → もう片方で `peerLeft` が検知され、peers リストから消えることを確認
6. **Coordinator 再選出**: coordinator 役のピアを停止 → 残ったピアが新 coordinator になり、同期が継続することを確認
7. **Start → Stop → Start 往復**: ライフサイクルの繰り返しが破綻しないことを確認
8. **同時起動レース**: 2台をほぼ同時に起動 → 両方で coordinator が正しく収束することを確認

### 観測ポイント

- `clock.now` の値を両デバイスで同時にログ出力し、差分が ±2ms 以内か確認
- `SyncQuality.confidence` が 0.5 以上で安定しているか
- CPU 使用率・バッテリー影響（数分間の実行）
