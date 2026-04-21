# Claude Worklog 2026-04-20


## 19:45 - 作業ログ（自動記録）
- PeerClockの競合調査を行います。Web検索で小規模プロジェクトも含めて調べます。

## 19:48 - 作業ログ（自動記録）
- ファイルはJSON形式のログです。最後の方にまとめがあるはずなので確認します。

## 19:59 - 作業ログ（自動記録）
- 調査結果が得られました。以下が全21件の競合・代替ライブラリの調査レポートです。 --- ## PeerClock 競合・代替ライブラリ 調査レポート（2026-04-20） ### カテゴリ 1: Swift/iOS 向け NTP クライアント（8件） | # | 名前 | Stars | 最終更新 | 状態 | |---|------|-------|----------|------| | 1 | [TrueTime.swift](https://github.com/instacart/TrueTime.swift) | 634 | 2023-11 | 停止 | | 2 | [Kronos](https://github.com/MobileNativeFoundation/Kronos) | 692 | 2025-06 | 現役 | | 3 | [apple/swift-ntp](https://github.com/apple/swift-ntp) | 98 | 2026-01 | 現役 | | 4 | [ios-ntp](https://github.com/jbenet/ios-ntp) | 375 | 2021-03 | 停止 | | 5 | [NHNetworkTime](https://github.com/huynguyencong/NHNetworkTime) | 119 | 2021-05 | 停止 | | 6 | [MHSNTP](https://github.com/scottrhoyt/MHSNTP) | 0 | 2017-04 | 放棄 | | 7 | [NTP.swift](https://github.com/danielepantaleone/NTP.swift) | 4 | 2025-09 | 個人 | | 8 | [ServerSync-iOS](https://github.com/skylovely/ServerSync-iOS) | 10 | 2016-11 | 放棄 | 全てインターネット上の NTP サーバーとの同期専用。**デバイス間 P2P 同期・コマンドチャネル・ステータス共有は一切なし。** --- ### カテゴリ 2: P2P 通信フレームワーク（7件） | # | 名前 | Stars | 最終更新 | 状態 | |---|------|-------|----------|------| | 9 | [MultipeerKit](https://github.com/insidegui/MultipeerKit) | 1,130 | 2024-04 | 活発 | | 10 | [PeerKit](https://github.com/jpsim/PeerKit) | 868 | 2018-12 | 停止 | | 11 | [sReto](https://github.com/ls1intum/sReto) (TU Munich) | 95 | 2025-12 | 継続 | | 12 | [P2PShareKit](https://github.com/dobster/P2PShareKit) | 65 | 2020-12 | 停止 | | 13 | [MultiPeer](https://github.com/dingwilson/MultiPeer) | 245 | 2021-05 | 停止 | | 14 | [MultipeerHelper](https://github.com/maxxfrazer/MultipeerHelper) | 106 | 2023-04 | 停止 | | 15 | [CocoaMultipeer](https://github.com/manavgabhawala/CocoaMultipe

## 20:26 - 作業ログ（自動記録）
- Plan エージェントが計画のフルテキストを返却しなかったため、直接 `tasks/todo.md` に書き出すよう再依頼します。

## 21:12 - 作業ログ（自動記録）
- Codex から重要な指摘を受けました。並行で Gemini にもレビュー依頼します。

## 21:26 - 作業ログ（自動記録）
- 3者会議を始めます。まず私の意見を述べ、次に Codex と Gemini に独立した意見を並行で求めます。 ## 私（Claude）の意見 **結論: 3機能の実装は現時点では優先度が低い。** ### 理由 1. **競合が存在しない=勝つ対象がいない** 競合調査の結論は「PeerClock のニッチは空白地帯」だった。差別化すべき相手がいないのに精度を一桁改善しても、それを必要とするユーザーが現れる保証はない。 2. **±2ms が足りないユースケースは限定的** - 1Take（マルチデバイス録音）の現実的要求: 人間の知覚限界は ~10ms、プロ音声編集でも ~1ms。**現状の ±2ms で足りる** - ±200µs を要求する領域: 科学計測、ビームフォーミング、マルチカメラ映画撮影——この層は商用プロ機材を使う 3. **OSS として優先すべきは精度ではなく別の軸** - 採用障壁の低減（ドキュメント、チュートリアル、サンプルアプリ） - 安定性（再接続、バックグラウンド、エラー回復） - フットプリント（依存なし、Swift 6 完全対応は既達成） 4. **実装コストに対する得るものが少ない** Codex レビューで機能1は技術的に成立せず、機能2は Apple API 性質と不整合。機能3だけが筋が良いが、それも「潜在的に必要かもしれない」レベル。 ### 実装するなら何か - **機能3 だけは着手する価値あり**: `mach_timebase_info()` キャッシュ化だけでも低リスクで CPU 削減効果あり - **機能1/2 は「将来の誰かが要求してから」で十分** --- では Codex と Gemini に独立意見を求めます。

## 21:50 - 作業ログ（自動記録）
- はい、わかりやすい iOS アプリが鍵です。Codex の意見も「PeerClock の価値を3秒で伝える実証デモ」として賛成でした。Gemini の意見も取ってから統合します。

## 22:26 - 作業ログ（自動記録）
- 「単純なNTPアプリ」について3者討論します。まず私の意見から。 ## 私（Claude）の意見 **反対寄り。PeerClock の差別化を殺すリスクが高い。** ### 反対理由 1. **PeerClock の差別化は P2P、NTP クライアントではない** 「単純な NTP アプリ」= サーバーから正確な時刻を取る時計アプリ。これなら Kronos や TrueTime で作れる。**PeerClock である必要がない**。 2. **競合調査で出た NTP アプリは既に大量に存在** - Emerald Time, Atomic Clock, ClockSync, NTPClock 等、App Store に多数 - 新規参入しても埋もれる - PeerClock の「独占ニッチ」という資産を活かせない 3. **「3秒で伝わる価値」にならない** - 時計アプリは単体デバイスで動く → 複数端末の同期という PeerClock の魔法が見えない - 前回合意した「複数 iPhone 並べて同時発火→本能的インパクト」が失われる 4. **誤ったブランド認知のリスク** 「PeerClock = NTP クライアント」と誤認され、**Kronos/TrueTime と同カテゴリに分類される**。空白ニッチから紅海に飛び込むことになる ### ただし別解釈なら賛成もあり得る もし「単純な NTP アプリ」が以下を意味するなら話は違う: - **A: PeerClock の P2P 同期をバックエンドに使った時刻表示アプリ** → それは実質 FlashSync/Synced Stopwatch と同じ - **B: iPhone を NTP サーバーにして他デバイスに配信するアプリ** → ニッチだが PeerClock の特徴を活かせる、一部開発者には刺さる - **C: サーバーNTP＋ピア間同期を両方持つハイブリッド** → 複雑化してデモ性が下がる 「単純な NTP アプリ」が単なる時計アプリを指すなら反対。PeerClock の価値を削る。 --- Codex と Gemini に聞きます。
