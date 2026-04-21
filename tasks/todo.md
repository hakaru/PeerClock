# PeerClock NTP — iOS ショーケースアプリ計画

## 概要

PeerClock ライブラリの価値を「3秒で伝える」iOS アプリ。
NTP をフック（わかりやすいキーワード）、P2P Sync を差別化の魔法とする。

**コンセプト**: 「NTP アプリの進化形。ネットがなくても、隣のデバイスと時間が揃う唯一の時計」

**目的**: PeerClock OSS の営業資料 / ショーケース（課金不要）

**差別化**: Prime Time NTP / Emerald Time / AtomicClock は全てインターネット必須。PeerClock NTP だけが Offline + P2P で動く。

## プロダクトストーリー

1. アプリ起動 → NTP サーバーに自動接続（最適サーバー自動選択）→ 正確な時刻表示
2. インターネットが切れる → 「Offline — Peer Sync Active」と表示が変わる → ミリ秒時計は動き続ける
3. 2 台を近づける → ローカル P2P で同期継続、相対精度 ±2ms を維持
4. → 「NTP がなくても、隣のデバイスと時間が揃う」が一目でわかる

## 動作モード

| 状態 | 時刻ソース | 精度表示 |
|------|-----------|---------|
| NTP + Peer | NTP 絶対時刻 + P2P 相対同期 | ±0.5ms |
| NTP のみ（1台） | NTP 絶対時刻 | ±数ms（ネットワーク依存） |
| Peer のみ（Offline） | P2P 相対同期 | ±2ms（PeerClock の本領） |
| 単独 + Offline | デバイスクロック + ドリフト推定 | ±数十ms〜（不確実性を明示） |

## 画面構成（1画面、設定なし）

```
┌─────────────────────────────┐
│                             │
│      12:34:56.789           │  ← ミリ秒時計（120fps）
│                             │
├─────────────────────────────┤
│  Status: NTP + Peer Sync    │  ← 接続状態
│  NTP Server: ntp.nict.jp    │  ← 自動選択されたサーバー
│  NTP Offset: +0.342ms       │  ← サーバーとの誤差
│  Peer Offset: 0.127ms       │  ← ピアとの相対誤差（2台時）
│  RTT: 12.4ms ───────────    │  ← スパークライン
│  Peers: 1 connected         │  ← ピア接続数
├─────────────────────────────┤
│                             │
│        [ TAP SYNC ]         │  ← タップで全端末同時フラッシュ
│                             │
└─────────────────────────────┘
```

- 2台並べた時: ミリ秒の数字が完全に一致して流れる
- TAP SYNC: タップすると全ピアの背景色が同時に変わる

## NTP サーバー自動選択

```
起動時:
1. 候補プール並列 ping:
   - time.apple.com
   - ntp.nict.jp (日本)
   - pool.ntp.org
   - time.google.com
   - time.cloudflare.com
2. RTT 最小のサーバーを自動選択
3. ネットワーク変更時に再評価
```

## 技術スタック

- SwiftUI（iOS 17+）
- 自前 SNTPClient（RFC 5905、外部依存なし）
- PeerClock ライブラリ（Phase 2 以降、ローカル SPM 依存）
- xcodegen（プロジェクト生成）
- ターゲット: iPhone（iPad 互換）

## 設計判断（確定）

| 項目 | 採用方針 |
|------|---------|
| アーキテクチャ | `@Observable` + `actor` + `@MainActor` |
| 120fps 表示 | `TimelineView(.animation(minimumInterval: 1/120))` |
| NTP 複数サーバー | `withTaskGroup` で 5 サーバー並列 → 最小 RTT 選択 |
| ネットワーク監視 | `NWPathMonitor`（Network.framework） |
| Phase 1 依存 | 外部依存なし（自前 SNTPClient、PeerClock は Phase 2 で追加） |
| データ保持 | actor 内リングバッファ（60秒 × 1Hz = 60サンプル） |

## ファイル構成

```
App/PeerClockNTP/
├── project.yml                      xcodegen 定義
├── Sources/
│   ├── PeerClockNTPApp.swift        @main エントリポイント
│   ├── Model/
│   │   └── NTPServerResult.swift    値型: host/offset/rtt/stratum/sampledAt
│   ├── Service/
│   │   ├── SNTPClient.swift         RFC 5905 SNTP クライアント（UDP, Network.framework）
│   │   ├── NTPClient.swift          actor: 並列同期・RTT比較・履歴保持
│   │   └── NetworkMonitor.swift     actor: NWPathMonitor ラッパー
│   ├── ViewModel/
│   │   └── ClockViewModel.swift     @Observable @MainActor: UI状態集約
│   └── View/
│       ├── ClockView.swift          ルートビュー（状態ごとの分岐）
│       ├── MillisecondClockFace.swift  TimelineView 120fps ミリ秒表示
│       ├── NTPStatusPanel.swift     Server/Offset/RTT/Stratum 表示
│       └── SparklineView.swift      Canvas で 60 秒オフセット履歴
├── Resources/
│   └── (empty, for future assets)
└── Tests/
    └── SNTPClientTests.swift        パケットエンコード/デコードテスト
```

## 実装計画

### Phase 1: NTP 単体モード（詳細）

#### Step 0: プロジェクト基盤（30分）
- [ ] `project.yml` を Phase 1 用に書き直し（外部依存なし、Kronos 除去）
- [ ] `xcodegen generate` 実行 → `.xcodeproj` 生成
- [ ] `xcodebuild build` で空プロジェクトのビルド確認
- [ ] ディレクトリ構成作成（Model/Service/ViewModel/View）

#### Step 1: NTPServerResult モデル（15分）
- [ ] `NTPServerResult.swift` — `Sendable` な値型
  ```swift
  struct NTPServerResult: Sendable {
      let host: String
      var offset: TimeInterval  // 秒
      var rtt: TimeInterval     // 秒
      var stratum: Int
      var sampledAt: Date
  }
  ```

#### Step 2: SNTPClient — RFC 5905 実装（90分）
- [ ] `SNTPClient.swift` — struct（80〜150 LOC）
  - RFC 5905 48-byte NTP パケット encode/decode
  - NTP タイムスタンプ形式: 1900 epoch, 64-bit fixed point（32-bit 秒 + 32-bit 小数部）
  - Epoch 補正定数: `2,208,988,800`（NTP 1900 → Unix 1970）
  - エンディアン: `UInt32(bigEndian:)` で厳密処理
  - Network.framework `NWConnection` で UDP 宛先 port 123（送信元はエフェメラルポート）
  - 4-timestamp 交換: t0(送信時刻), t1(サーバー受信), t2(サーバー送信), t3(受信時刻)
  - t0/t3 は `Date()` で取得（NTP 絶対時刻座標系で統一）
  - offset = ((t1-t0) + (t2-t3)) / 2, delay = (t3-t0) - (t2-t1)
  - タイムアウト: 3 秒（タイムアウト時は該当サーバーをスキップ）
  - `func query(host: String) async throws -> NTPServerResult`

#### Step 3: NetworkMonitor（20分）
- [ ] `NetworkMonitor.swift` — `NWPathMonitor` ラッパー actor
  - `var isConnected: Bool { get }` — WiFi or Cellular 接続中か
  - `var pathUpdates: AsyncStream<Bool>` — 接続状態変更ストリーム
  - `init()` / `func start()` / `func stop()`

#### Step 4: NTPClient — オーケストレーション（45分）
- [ ] `NTPClient.swift` — actor
  - サーバーリスト: `["time.apple.com", "ntp.nict.jp", "pool.ntp.org", "time.google.com", "time.cloudflare.com"]`
  - `func syncAll() async` — `withTaskGroup` で全サーバーに SNTPClient.query() を並列実行
  - サーバー選択: 全サーバーの RTT を比較し最小 RTT のサーバーを採用
  - 選択後: ベストサーバーに対して 8 回連続測定 → RTT 下位 50% のオフセット平均（best-half filtering）
  - `var offsetHistory: [Double]` — 直近 60 サンプルのリングバッファ
  - `func startPeriodicSync(interval: Duration = .seconds(5))` — 5 秒周期で再同期（ベストサーバーに 4 回測定 + best-half）
  - 全サーバータイムアウト時: `syncState = .offline` に遷移、UI にフォールバック表示

#### Step 5: ClockViewModel（45分）
- [ ] `ClockViewModel.swift` — `@Observable @MainActor`
  - `var currentTime: Date` — NTP 補正済み現在時刻（表示用に高頻度更新は View 側 TimelineView で）
  - `var ntpOffset: TimeInterval?` — 現在の NTP オフセット
  - `var rtt: TimeInterval?` — 現在の RTT
  - `var serverHost: String?` — 選択されたサーバー
  - `var stratum: Int?`
  - `var isOnline: Bool`
  - `var offsetHistory: [Double]` — スパークライン用
  - `var syncState: SyncState` — `.syncing` / `.synced` / `.offline` / `.error`
  - `func start()` — NTPClient + NetworkMonitor を起動
  - NetworkMonitor の変更を observe して isOnline を更新

#### Step 6: View レイヤー（90分）
- [ ] `ClockView.swift` — ルートビュー
  - `@State var viewModel = ClockViewModel()`
  - `.task { await viewModel.start() }`
  - VStack: MillisecondClockFace + NTPStatusPanel + SparklineView
- [ ] `MillisecondClockFace.swift`
  - `TimelineView(.animation(minimumInterval: 1.0/120.0))` で 120fps
  - `Date() + ntpOffset` から時:分:秒.ミリ秒 を表示
  - モノスペースフォント、大きい数字
- [ ] `NTPStatusPanel.swift`
  - Status badge（Synced / Offline / Syncing）
  - Server, Offset (ms), RTT (ms), Stratum を縦に表示
- [ ] `SparklineView.swift`
  - `Canvas` で offsetHistory を折れ線グラフ描画
  - 中央線 = 0ms、上下にスケール
  - 直近 60 秒分

#### Step 7: 統合確認（30分）
- [ ] 実機ビルド & 動作確認
- [ ] NTP 同期が 3 秒以内に完了すること
- [ ] 機内モードで「Offline」表示に切り替わること
- [ ] ミリ秒表示が滑らかに更新されること（120fps）
- [ ] スパークラインにオフセット履歴が描画されること

### Phase 2: Peer Sync 統合（3日）

- [ ] PeerClock ライブラリ統合（SPM ローカルパッケージ依存）
- [ ] 自動ピア発見 & 接続（Bonjour）
- [ ] Peer Offset リアルタイム表示
- [ ] 接続状態表示（Peers: N connected）
- [ ] Offline + Peer モード: NTP 不達時に P2P のみで継続
- [ ] TAP SYNC: 全ピア同時フラッシュ（CommandRouter 使用）

### Phase 3: ポリッシュ & TestFlight（2日）

- [ ] UI ポリッシュ（ダークモード、大きい数字、視認性）
- [ ] 状態遷移アニメーション（NTP → Offline → Peer）
- [ ] App Icon / Launch Screen
- [ ] TestFlight 内部テスト配信
- [ ] README 用スクリーンショット & 動画撮影

### Phase 4: 公開準備（2日）

- [ ] TestFlight パブリックリンク公開
- [ ] PeerClock README に TestFlight リンク & デモ動画埋め込み
- [ ] Swift Package Index 整備
- [ ] SNS 投稿用 Vertical Video 撮影（3台並べて同期）
- [ ] （オプション）App Store 申請

## やらないこと

- ❌ 設定画面
- ❌ NTP サーバー手動選択 UI
- ❌ 課金 / Pro 機能
- ❌ 機能追加（デモ純度維持）
- ❌ 精度向上3機能（前回合意で棚上げ済み）

## 成功基準

- [ ] 2台の iPhone を並べた時にミリ秒が揃って流れること（動画で証明）
- [ ] Offline（機内モード）でも P2P 同期が継続すること
- [ ] NTP サーバー自動選択が 3 秒以内に完了すること
- [ ] TestFlight インストール → 体験まで 30 秒以内
- [ ] PeerClock GitHub への流入が計測できること

## リスク

- [x] NTP クライアント実装: → 自前 SNTPClient（RFC 5905, ~100 LOC）で解決。外部依存なし
- [ ] UDP port 123: iOS はクライアント送信のみなので問題なし（bind しない）
- [ ] Info.plist: `NSLocalNetworkUsageDescription` + `NSBonjourServices` が必要（Phase 2 PeerClock 利用時）
- [ ] PrivacyInfo.xcprivacy: Phase 2 で PeerClock 統合時に mach_continuous_time 申告が必要
- [ ] 120fps 表示: DisplayLink + SwiftUI の組み合わせでパフォーマンス確認必要
- [ ] App Store 審査: 「NTP 時計」カテゴリで機能が少なすぎると Reject リスク → TestFlight 先行で回避

## App Store メタデータ（将来用）

- **名前**: PeerClock NTP
- **サブタイトル**: NTP & Peer Sync — Works Offline
- **カテゴリ**: Utilities
- **キーワード**: NTP, clock, sync, peer, time, millisecond, offline, precision
- **説明文 1行目**: 「ネットがなくても、隣のデバイスと時間が揃う唯一の時計」
