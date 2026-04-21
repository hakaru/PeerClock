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

---

# PeerClock Metronome — 同期メトロノームアプリ計画

## 概要

PeerClock ライブラリの ±2ms 同期精度を「音」で体感させるデモアプリ。
複数 iPhone を並べて同じ BPM でクリック音が鳴り、人間の耳では完全に同時に聞こえる。

**コンセプト**: 「バンドメンバー全員のメトロノームが揃う、世界初の P2P 同期メトロノーム」

**差別化**: 既存メトロノームアプリは全て単独動作。複数デバイス同期は存在しない。

## 動作モード

| 状態 | 動作 |
|------|------|
| 単独 | ローカルメトロノーム（普通のメトロノームとして動作） |
| P2P 同期 | PeerClock.now で拍タイミング計算 → 全端末同時クリック |

## 拍構造

| 種別 | クリック音 | フラッシュ |
|------|-----------|-----------|
| ダウンビート（1拍目） | 強クリック（高音 1000Hz） | 全画面フラッシュ（明るい） |
| ビート（2,3,4拍目） | 中クリック（800Hz） | 中フラッシュ |
| サブディビジョン | 弱クリック（低音 600Hz） | 小フラッシュ（薄い） |

## サブディビジョン

- なし: ♩ のみ
- 1/2: ♩ ♪ ♩ ♪（8分音符）
- 1/3: ♩ ♪♪ ♩ ♪♪（3連符）
- 1/4: ♩ ♬ ♩ ♬（16分音符）

## 画面構成（1画面）

```
┌─────────────────────────────┐
│                             │
│          120 BPM            │  ← 大きい数字（上下スワイプで調整）
│                             │
│    [ ♩ ] [♪♪] [♪♪♪] [♬]    │  ← サブディビジョン選択
│                             │
│        ●  ○  ○  ○          │  ← ビート位置インジケーター
│                             │
│       [ ▶ PLAY ]            │  ← 再生/停止
│                             │
│    Peers: 2 connected       │  ← ピア接続数
└─────────────────────────────┘
```

背景全体がビートに合わせてフラッシュ。

## 同期方式

```
全端末が同じ BPM + 同じ時計（PeerClock.now）を持つ
→ nextBeat = ceil(now / beatIntervalNs) * beatIntervalNs
→ 各端末が独立してスケジュール → 全端末同時にクリック（±2ms）

BPM/subdivision 変更:
→ 送信側が applyAtNs（= now + 500ms 以降の最初のダウンビート）を計算
→ CommandRouter.broadcast で {config, applyAtNs} を配信
→ 全端末が applyAtNs から新設定を適用（合意形成）

音響遅延補正:
→ AVAudioSession.outputLatency を取得
→ scheduleBuffer(at:) の再生時刻を outputLatency 分前倒し
→ デバイス間のハードウェア遅延差を吸収

スケジューリング:
→ AVAudioPlayerNode.scheduleBuffer(at: AVAudioTime) で拍を直接スケジュール
→ ルックアヘッド: 常に 2〜3 拍先までスケジュール（OS ジッター耐性）
→ busy-wait 不要（バッテリー節約）
```

## 技術スタック

- SwiftUI（iOS 17+）
- AVAudioEngine（低レイテンシ音声再生）
- PeerClock ライブラリ（P2P 同期 + コマンド配信）
- xcodegen（プロジェクト生成）

## ファイル構成

```
App/PeerClockMetronome/
├── project.yml                         xcodegen 定義
├── Sources/
│   ├── PeerClockMetronomeApp.swift     @main エントリポイント
│   ├── Model/
│   │   └── MetronomeConfig.swift       BPM, subdivision, beatsPerBar
│   ├── Service/
│   │   ├── ClickSynthesizer.swift      AVAudioEngine でクリック音生成・再生
│   │   ├── MetronomeEngine.swift       拍タイミング計算 + スケジューラ
│   │   └── PeerMetronomeService.swift  PeerClock 連携（BPM 同期・ピア管理）
│   ├── ViewModel/
│   │   └── MetronomeViewModel.swift    @Observable @MainActor: UI状態集約
│   └── View/
│       ├── MetronomeView.swift         ルートビュー
│       ├── BPMDisplay.swift            BPM 表示 + ジェスチャー調整
│       ├── SubdivisionPicker.swift     サブディビジョン選択 UI
│       └── BeatIndicator.swift         ビート位置ドットインジケーター
└── Resources/
    └── (empty)
```

## 実装計画

### Phase 1: 単体メトロノーム（同期なし）

#### Step 0: プロジェクト基盤（20分）
- [ ] `project.yml` 作成（PeerClock 依存含む）
- [ ] `xcodegen generate` → ビルド確認
- [ ] ディレクトリ構成作成

#### Step 1: MetronomeConfig モデル（10分）
- [ ] `MetronomeConfig.swift`
  ```swift
  struct MetronomeConfig: Sendable, Equatable {
      var bpm: Int = 120          // 30〜300
      var subdivision: Subdivision = .none
      var beatsPerBar: Int = 4
  }
  enum Subdivision: Int, Sendable, CaseIterable {
      case none = 1
      case half = 2    // 1/2（8分音符）
      case triplet = 3 // 1/3（3連符）
      case quarter = 4 // 1/4（16分音符）
  }
  ```

#### Step 2: ClickSynthesizer — 音声エンジン（60分）
- [ ] `ClickSynthesizer.swift` — AVAudioEngine ベース
  - `AVAudioEngine` + `AVAudioPlayerNode` + `AVAudioPCMBuffer`
  - 3種のクリック音をメモリ上に事前生成（サイン波バースト）:
    - 強: 1000Hz, 20ms, amplitude 1.0
    - 中: 800Hz, 15ms, amplitude 0.7
    - 弱: 600Hz, 10ms, amplitude 0.4
  - `func scheduleClick(_ type: ClickType, at: AVAudioTime)` — 正確な時刻にスケジュール
  - ルックアヘッド: 2〜3 拍先までバッファスケジュール（OS ジッター耐性）
  - `outputLatency` 補正: `AVAudioSession.sharedInstance().outputLatency` を減算
  - AudioSession カテゴリ: `.playback`, mode: `.default`, options: `.mixWithOthers`
  - AudioSession interruption 通知のハンドリング（電話着信等）

#### Step 3: MetronomeEngine — 拍スケジューラ（60分）
- [ ] `MetronomeEngine.swift` — actor
  - `var config: MetronomeConfig`
  - `var isPlaying: Bool`
  - `func start()` — ルックアヘッドループ起動
  - 拍タイミング計算: `beatIntervalNs = 60_000_000_000 / bpm`
  - サブディビジョン: `subIntervalNs = beatIntervalNs / subdivision.rawValue`
  - ルックアヘッド方式: 100ms 周期で次 2〜3 拍を ClickSynthesizer にスケジュール
  - コールバック: `var onTick: ((TickType, Int) -> Void)?`（UI フラッシュ用）
    - `TickType`: `.downbeat`, `.beat`, `.subdivision`
    - `Int`: ビート番号（0-based）
  - busy-wait 不要（scheduleBuffer が正確な再生を保証）

#### Step 4: MetronomeViewModel（30分）
- [ ] `MetronomeViewModel.swift` — `@Observable @MainActor`
  - `var config: MetronomeConfig`
  - `var isPlaying: Bool`
  - `var currentBeat: Int` — 現在のビート位置（0-based）
  - `var flashIntensity: Double` — フラッシュの強さ（0〜1）
  - `var peerCount: Int`
  - `func togglePlay()`
  - `func setBPM(_ bpm: Int)`
  - `func setSubdivision(_ sub: Subdivision)`
  - Engine の onTick を受けて UI 状態を更新

#### Step 5: View レイヤー（60分）
- [ ] `MetronomeView.swift` — ルートビュー + 背景フラッシュ
- [ ] `BPMDisplay.swift` — 大きい BPM 数字 + DragGesture で調整
- [ ] `SubdivisionPicker.swift` — 4つのボタン（なし/2/3/4）
- [ ] `BeatIndicator.swift` — ドットで現在ビート位置を表示

#### Step 6: 統合確認（20分）
- [ ] 実機ビルド & 動作確認
- [ ] クリック音が正確なタイミングで鳴ること
- [ ] BPM 変更がスムーズに反映されること
- [ ] サブディビジョン切替が正しく動作すること
- [ ] バックグラウンド移行時に停止すること

### Phase 2: P2P 同期

#### Step 7: PeerMetronomeService（45分）
- [ ] `PeerMetronomeService.swift` — PeerClock 連携
  - `PeerClock()` 起動、ピア自動発見
  - `PeerClock.now` を MetronomeEngine に供給
  - BPM/subdivision 変更時:
    - `applyAtNs` を計算（now + 500ms 以降の最初のダウンビート）
    - `broadcast(Command(type: "config", payload: {config, applyAtNs}))` 
  - コマンド受信時: `applyAtNs` から新 config を適用
  - 新ピア接続時: 現在の config + 再生状態を push
  - ピア数監視

#### Step 8: 同期スケジューリング（45分）
- [ ] MetronomeEngine を PeerClock.now ベースに拡張
  - `now % beatIntervalNs` で次のビートまでの残り時間を計算
  - 全端末が同じ `now` と同じ `beatIntervalNs` を持つ → 自動同期
  - BPM 変更時: 次のダウンビートから新 BPM を適用（途中で変わらない）
  - 基準時刻: `epochNs = 0`（全端末で共通の固定基準）

#### Step 9: 統合テスト（30分）
- [ ] 2台で同時クリックが聞こえること（動画で証明）
- [ ] 片方で BPM 変更 → もう一方に即座に反映
- [ ] 途中参加: 新しいピアが接続 → 現在の BPM で即座に同期
- [ ] Offline: ピア切断後も自分のメトロノームは継続

## 技術的注意点・リスク

- [ ] **音響遅延補正**: デバイスモデルごとに `outputLatency` が 5〜20ms 異なる。`AVAudioSession.outputLatency` で補正必須（Issue #9）
- [ ] **BPM 変更の合意形成**: `applyAtNs` を絶対時刻で共有。ネットワーク遅延による解釈不一致を防止（Issue #8）
- [ ] **スケジューリング**: `scheduleBuffer(at: AVAudioTime)` + ルックアヘッド方式。busy-wait 不要
- [ ] **AudioSession**: `.playback` + `.mixWithOthers` で他アプリと共存。interruption 通知をハンドル
- [ ] **バックグラウンド再生**: Background Audio entitlement が必要な場合あり（Phase 2 以降で検討）
- [ ] **新ピア接続**: 途中参加ピアに現在の config + 再生状態を即時 push

## やらないこと

- ❌ 拍子記号のカスタマイズ（4/4 固定）
- ❌ アクセントパターン
- ❌ 音色選択
- ❌ テンポカーブ / 加速
- ❌ 録音機能
- ❌ MIDI 出力

## 成功基準

- [ ] 2台並べてクリックが完全に揃うこと（動画で証明）
- [ ] BPM 40〜240 で安定動作（ジッター <2ms）
- [ ] サブディビジョン切替が即座に反映
- [ ] PeerClock GitHub への流入
