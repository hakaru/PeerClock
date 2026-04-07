# Demo Apps Design — macOS CLI + iOS Dashboard

## Overview

PeerClock Phase 1 の実機検証用デモアプリ。macOS CLI で素早くロジック検証、iOS アプリでダッシュボード表示付きの実機テスト。

## 1. macOS CLI (`PeerClockCLI`)

Package.swift に executable ターゲットとして追加。ターミナル2つで同時実行。

### 機能

- 起動時に `PeerClock()` を初期化して `start()`
- ピア発見・同期状態・コマンド受信をリアルタイムにログ出力
- stdin から対話コマンド: `send <message>`, `peers`, `sync`, `quit`

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
- Broadcast ボタン（タップで ping コマンドを全ピアに送信）
- 送受信コマンドのログ（タイムスタンプ + 方向 + 内容）

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
    <string>_peerclock._udp</string>
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

1. **macOS 2プロセス**: ターミナル2つで `swift run PeerClockCLI` → 相互発見 → 同期 → コマンド送受信
2. **iOS 2台**: 同一 Wi-Fi に接続 → アプリ起動 → ダッシュボードで同期状態とピア確認 → Broadcast テスト
3. **macOS + iOS**: CLI と iOS アプリの混在テスト
