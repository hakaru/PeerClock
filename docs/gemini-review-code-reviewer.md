Checking build status...
Build is up-to-date.
(node:80133) Warning: `--localstorage-file` was provided without a valid path
(Use `node --trace-warnings ...` to show where the warning was created)
YOLO mode is enabled. All tool calls will be automatically approved.
YOLO mode is enabled. All tool calls will be automatically approved.
プロジェクトコンテキストを把握するため、まずは `GEMINI.md` の確認と既存の GitHub Issue のリストアップを行います。その後、指定された各ファイルのコードレビューを実施します。

`GEMINI.md` が存在しないため、プロジェクトの規約やコンテキストを把握するために `CLAUDE.md` を確認します。併せて、既存の GitHub Issue を取得します。

プロジェクトの基本方針と同期アルゴリズムの仕様を確認しました。レビュー対象のファイル数が多い構成のため、まずはプロジェクト設定とコアとなる NTP 実装（Model および Service）から順次読み込み、詳細なコードレビューを進めます。

ここまでの確認内容に基づき、プロジェクト設定および NTP 関連のコアロジックについて初期レビューを行います。

### 1. `project.yml` および `NTPServerResult.swift`
- Swift 6 の厳密な並行性チェックが有効化されており、`NTPServerResult` も `Sendable` 準拠で問題ありません。

### 2. `NTPClient.swift` (Actor)
- `actor` による状態保護と `withTaskGroup` を用いた並列クエリは適切です。
- `best-half filtering` の実装もプロジェクトのアルゴリズム方針に沿っています。

### 3. `SNTPClient.swift` (Struct)
- **タイムスタンプ計算**: RFC 5905 準拠のオフセット計算式およびエポックオフセット値は正確です。
- **並行性の懸念**: `withCheckedThrowingContinuation` 内で、タイムアウト時に `connection.cancel()` を呼ぶだけでは、必ずしも `continuation` が適切に再開（resume）されないリスクがあります。接続が `ready` に至らないケースや、特定の状態で停止した場合のハンドリングを精査する必要があります。

### 4. `NetworkMonitor.swift` (Actor)
- **ストリーム管理の懸念**: `AsyncStream` の `continuation` をプロパティとして保持していますが、`lazy var` プロパティへの複数回アクセスにより `continuation` が上書きされ、古いストリームが終了できなくなる（リークする）可能性があります。

続いて、UI 層である ViewModel および View の実装を確認します。

全ファイルのコードレビューを完了しました。Swift 6 strict concurrency への対応、NTP アルゴリズムの正確性、リアルタイム安全性、および iOS 固有のライフサイクル管理の観点から詳細な分析を行いました。

分析の結果、重要度 High の問題 1 件、Medium 2 件を特定しました。以下にレビュー結果のサマリーと、特定された問題の詳細をまとめます。

### コードレビュー・サマリー

| 観点 | 評価 | 備考 |
| :--- | :--- | :--- |
| **Swift 6 Concurrency** | **良好** | `actor` と `@MainActor` を適切に使用。データ競合のリスクは最小化されています。 |
| **NTP 実装の正確性** | **優秀** | RFC 5905 準拠のオフセット計算。`best-half filtering` による精度向上も実装済み。 |
| **リアルタイム安全性** | **良好** | `TimelineView` と非同期通信の分離ができており、メインスレッドの負荷は低いです。 |
| **バグリスク** | **注意** | `continuation` のライフサイクル管理に一部懸念があります。 |
| **iOS 固有の問題** | **注意** | バックグラウンド遷移時のリソース管理に改善の余地があります。 |

---

### 特定された問題と提案

#### 1. [High] SNTPClient における Continuation の安全な解決
`SNTPClient.query` 内で `withCheckedThrowingContinuation` を使用していますが、タイムアウト発生時に `connection.cancel()` を呼び出すだけでは、必ずしも `continuation` が再開（resume）されない、あるいは実行パスによっては重複して再開されるリスクがあります。
- **リスク**: スレッドのハング、またはアプリのクラッシュ。
- **提案**: タイムアウト時に明示的に `continuation.resume(throwing:)` を行い、かつ状態管理フラグ等で二重解決を防ぐ構造に改善する必要があります。

#### 2. [Medium] NetworkMonitor の AsyncStream リークと不安定性
`AsyncStream` の `continuation` を単一のプロパティとして保持しているため、複数の呼び出し元が `pathUpdates` にアクセスした場合、古い `continuation` が上書きされ、以前のストリームが終了できなくなります。
- **リスク**: メモリリーク、およびネットワーク状態通知の不達。
- **提案**: `pathUpdates` を `lazy var` ではなく、適切なマルチキャスト（例：`AsyncChannel` や `Observation`）に置き換えるか、呼び出しを制限する必要があります。

#### 3. [Medium] App のライフサイクル（バックグラウンド遷移）への未対応
`ClockViewModel` は `scenePhase` を監視しておらず、アプリがバックグラウンドに移行しても NTP 同期タスクが走り続けようとします。
- **リスク**: バックグラウンドでの UDP 通信失敗によるエラーログの蓄積、およびバッテリー消費。
- **提案**: `View` 側で `scenePhase` を監視し、バックグラウンド移行時に `viewModel.stop()`、復帰時に `viewModel.start()` を呼び出すように修正すべきです。

---

重要度 High および Medium の問題について、GitHub Issue を起票します。

Bash command parsing error detected for command: gh issue create --title "Improve SNTPClient timeout handling and continuation safety" --label "bug" --body "## 概要
`SNTPClient.query` において `withCheckedThrowingContinuation` が使用されていますが、タイムアウトやエラー発生時の `continuation` の解決が不完全である可能性があります。

## 詳細
- `DispatchQueue.global().asyncAfter` で `connection.cancel()` を呼ぶだけでは、`stateUpdateHandler` が必ずしも `cancelled` に遷移して `continuation` が解決される保証がありません（特に `ready` 以前の状態でハングした場合）。
- 接続のライフサイクルと `continuation` の解決が 1:1 で対応していないため、二重解決によるクラッシュや、未解決によるリソースリーク（タスクのハング）のリスクがあります。

## 修正案
- タイムアウト発生時に明示的に `continuation.resume(throwing: SNTPError.timeout)` を呼び出す。
- `CheckedContinuation` をアトミックに管理するか、一度だけ解決されることを保証する構造に改善する。" && \
gh issue create --title "Fix NetworkMonitor AsyncStream continuation leak" --label "bug" --body "## 概要
`NetworkMonitor` において、`AsyncStream.Continuation` を単一のプロパティで保持しているため、複数のオブザーバーが存在する場合に正常に動作しません。

## 詳細
- `pathUpdates` (lazy var) が複数回アクセスされると、`continuation` プロパティが上書きされます。これにより、古いストリームは `finish()` を受け取ることができなくなり、リークします。

## 修正案
- 複数の呼び出し元に対応できるよう `TaskGroup` や `Observation` を検討するか、ストリームの生成を一度に制限する。
- actor 内での状態管理をより堅牢にする。" && \
gh issue create --title "Handle app lifecycle (background/foreground) in ClockViewModel" --label "enhancement" --body "## 概要
アプリがバックグラウンドに移行した際の NTP 同期タスクの停止処理が実装されていません。

## 詳細
- iOS ではバックグラウンドでの通信が制限されるため、アプリが非アクティブな状態でも `periodicRefresh` が実行され続けると、通信エラーが多発したり、不必要なバッテリー消費を招く可能性があります。

## 修正案
- `ClockView` で `@Environment(\.scenePhase)` を監視し、`.background` 遷移時に `viewModel.stop()`、`.active` 復帰時に `viewModel.start()` を呼び出すように変更する。" Syntax Errors: [
  'Error node: "()" at 4:23',
  'Error node: "()" at 4:58',
  'Error node: "()" at 14:91',
  'Error node: ""## 概要\n' +
    'アプリがバックグラウンドに移行した際の NTP 同期タスクの停止処理が実装されていません。\n' +
    '\n' +
    '## 詳細\n' +
    '- iOS ではバックグラウンドでの通信が制限されるため、アプリが非アクティブな状態でも `periodicRefresh` が実行され続けると、通信エラーが多発したり、不必要なバッテリー消費を招く可能性があります。\n' +
    '\n' +
    '## 修正案\n' +
    '- `ClockView` で `@Environment(\\.scenePhase)` を監視し、`.background` 遷移時に `viewModel.stop()`、`.active` 復帰時に `viewModel.start()` を呼び出すように変更する。"" at 19:118',
  'Error node: "()`" at 26:84'
]
レビューを完了し、特定された重要度の高い問題について GitHub Issue を起票しました。

### 起票した GitHub Issue
1. **[Issue #3] Improve SNTPClient timeout handling and continuation safety**
   - タイムアウトやエラー発生時に `CheckedContinuation` が適切に解決されない、または二重解決されるリスクを指摘。
2. **[Issue #4] Fix NetworkMonitor AsyncStream continuation leak**
   - `AsyncStream.Continuation` をプロパティで保持していることによるメモリリークと、複数オブザーバー時の不安定さを指摘。
3. **[Issue #5] Handle app lifecycle (background/foreground) in ClockViewModel**
   - iOS のバックグラウンド移行時に NTP 同期タスクを停止し、バッテリー消費とエラーを抑制する改善を提案。

### 詳細レビュー結果

#### 1. Swift 6 Strict Concurrency
- `NTPClient` が `actor` として実装されており、`offsetHistory` などの可変状態へのアクセスはスレッドセーフです。
- `ClockViewModel` は `@MainActor` であり、SwiftUI との連携における並行性の安全性は確保されています。
- `SNTPClient` は `Sendable` 構造体として実装されています。

#### 2. NTP 実装の正確性
- `SNTPClient.parseResponse` の計算式（4-timestamp, RFC 5905）および `ntpEpochOffset` (`2,208,988,800`) は正確です。
- `NTPClient.refine` における `best-half filtering` （RTT 下位 50% の平均）は、ネットワークの揺らぎを排除する優れた実装です。

#### 3. リアルタイム安全性
- クロック表示に `TimelineView` (120fps) を使用しており、UI の滑らかさが確保されています。
- NTP クエリはバックグラウンドキュー (`NWConnection`) および actor で行われるため、UI のメインスレッドをブロックしません。

#### 4. バグリスクと改善点
- **`SNTPClient`**: `NWConnection` のキャンセルと `continuation` の解決タイミングをより厳密に同期させる必要があります。
- **`ClockViewModel`**: `start()` メソッドが複数回呼ばれた際、既存の `monitorTask` がキャンセルされずに上書きされる可能性があるため、開始前のキャンセル処理を追加することが望ましいです。
- **`SparklineView`**: `Canvas` を用いた描画は軽量ですが、`values` が空の場合のエッジケース処理が既に入っており（`guard values.count >= 2`）、堅牢です。

#### 5. iOS 固有の問題
- `NSLocalNetworkUsageDescription` および `NSBonjourServices` が `project.yml` に正しく定義されており、iOS 17+ でのローカルネットワーク通信に必要な要件を満たしています。
- 前述の通り、バックグラウンド遷移時のタスク管理が追加されれば、より実用的なアプリとなります。
