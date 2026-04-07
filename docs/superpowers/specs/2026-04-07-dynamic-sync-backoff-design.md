# Dynamic Sync Interval Backoff — Design

**Date:** 2026-04-07
**Status:** Draft
**Phase:** 3.5 (between Phase 3c and Phase 4)

## Background

`NTPSyncEngine` は現在、固定 5 秒間隔で再同期を続ける。長尺録音 (1Take 等) では SoC への継続負荷で熱ダレを誘発し、音飛びの原因になりうる (Gemini レビュー指摘)。

水晶発振子のドリフトは 20–50ppm 程度で、5 秒に 1 度の補正は安定運用ではオーバーキル。同期が安定したら間隔を段階的に延ばしたい。一方、ジャンプ検出時には即座に短い間隔へ戻す必要がある。

## Goals

- 同期成功が連続したら sync interval を段階的に延長 (最大 30s)
- ジャンプ検出 (DriftMonitor) や coordinator 再選出時に即座に短い間隔へリセット
- デフォルト ON。既存ユーザー (テスト含む) への影響を Configuration 経由で吸収
- 単体テスト可能な純粋ロジックとして分離

## Non-Goals

- 適応型 (測定品質ベース) の連続バックオフ — 段階固定で十分
- ネットワーク品質に応じた選出変更 — Phase 4 領域
- DriftMonitor の閾値変更

## Architecture

```
PeerClock (Facade)
  ├─ DriftMonitor.jumps  ──────────► syncEngine.resetBackoff()
  └─ NTPSyncEngine
       └─ BackoffController (private struct, lock 配下)
            stages: [TimeInterval]
            promoteAfter: Int
            stageIndex, successStreak
```

`BackoffController` は純粋データ構造。NTPSyncEngine 内部の `lock` で保護し、sync ループの各イテレーションで `recordSuccess` / `recordFailure` を呼んで次の sleep 時間を取得する。外部からは `NTPSyncEngine.resetBackoff()` 経由でリセット可能。

## Components

### BackoffController

```swift
struct BackoffController {
    let stages: [TimeInterval]      // e.g., [5, 10, 20, 30]
    let promoteAfter: Int           // e.g., 3

    private(set) var stageIndex: Int = 0
    private var successStreak: Int = 0

    var currentInterval: TimeInterval { stages[stageIndex] }

    mutating func recordSuccess()  // 連続成功で stageIndex++
    mutating func recordFailure()  // successStreak のみリセット、stage 維持
    mutating func reset()          // stageIndex=0, successStreak=0
}
```

**設計判断**:

- **失敗時に降格しない**: 一時的なパケットロスで毎回降格すると振動する。本当に異常なケースは DriftMonitor の jump 検出 → `reset()` で対処する二段構え。
- **最終段で頭打ち**: `stageIndex < stages.count - 1` のときのみ昇格。
- **immutable な stages**: init 時に固定。実行中変更は不可 (YAGNI)。
- **precondition**: `stages` が空、`promoteAfter <= 0` は init で fatalError。

### NTPSyncEngine 統合

`runSyncLoop` の sleep 部を BackoffController 経由に置換する。

```swift
private var backoff: BackoffController  // lock 配下

private func runSyncLoop() async {
    while !Task.isCancelled {
        guard let coordinatorID = lock.withLock({ self.coordinatorID }) else { break }
        let measurements = await collectMeasurements(coordinator: coordinatorID)

        let interval: TimeInterval
        if measurements.isEmpty {
            interval = lock.withLock {
                backoff.recordFailure()
                return backoff.currentInterval
            }
        } else {
            // 既存の filter / offset 計算 / yield
            interval = lock.withLock {
                backoff.recordSuccess()
                return backoff.currentInterval
            }
        }

        do { try await Task.sleep(for: .seconds(interval)) } catch { break }
    }
}

public func resetBackoff() {
    lock.withLock { backoff.reset() }
}
```

**`start(coordinator:)` での reset**: 既存の `_currentOffset = 0` リセットと同じ場所で `backoff.reset()` も呼ぶ。新しい coordinator では必ず初期段階から再スタート。

### PeerClock Facade からの reset 連携

PeerClock は DriftMonitor の `jumps` AsyncStream を購読し、jump 検出時に完全再同期をトリガする責務を持つ (既存)。そこに 1 行追加:

```swift
for await _ in driftMonitor.jumps {
    await syncEngine.resetBackoff()
    // 既存の完全再同期トリガ処理
}
```

実装時に該当コードの構造を確認し、購読がなければ新設する。

### Configuration 変更

```swift
public let syncBackoffStages: [TimeInterval]
public let syncBackoffPromoteAfter: Int

public init(
    // ... 既存 ...
    syncInterval: TimeInterval = 5.0,             // deprecated, 内部では未使用
    syncBackoffStages: [TimeInterval] = [5, 10, 20, 30],
    syncBackoffPromoteAfter: Int = 3,
    // ...
)
```

**互換性方針**:

- `syncInterval` パラメータは API 互換のため残すが、`NTPSyncEngine` 内部では参照しない (DocC で deprecated 注記)。
- 既存テストで `syncInterval: 0.1` のような小さい値を渡しているケースは、テスト実行を高速化する目的なので `syncBackoffStages: [0.1]` に置換する。実装時に grep で全箇所を洗い出す。

## Data Flow

```
[sync loop iter] ──► collectMeasurements
                          │
                  ┌───────┴────────┐
                  ▼                ▼
              empty?           not empty
                  │                │
       backoff.recordFailure   backoff.recordSuccess
                  │                │
                  └────┬───────────┘
                       ▼
              currentInterval
                       │
                       ▼
              Task.sleep(interval)

[DriftMonitor jump] ──► PeerClock ──► syncEngine.resetBackoff()
[start(coordinator:)] ──► backoff.reset()
```

## Testing

新規 `BackoffControllerTests` (純粋ロジック単体テスト):

1. **昇格**: stages=[1,2,4,8], promoteAfter=3 で連続 3 回成功 → stageIndex 0→1、さらに 3 回 → 1→2、… 最終段で頭打ち
2. **失敗時の挙動**: stage 1 で failure → stage 維持、successStreak のみ 0、再度 success 3 回で stage 2 へ
3. **reset**: stage 2 から `reset()` で stage 0、successStreak 0
4. **edge case**: stages=[5] (1 段のみ) → 常に 5s、昇格なし
5. **precondition**: stages=[] や promoteAfter=0 で fatalError (precondition test は省略可)

`NTPSyncEngineTests` 追加:

6. **start で reset**: stop 後に `start()` を呼ぶと stage 0 から再開 (既存 reset テストの拡張)
7. **resetBackoff() public API**: stage を進めた状態から `resetBackoff()` で stage 0
8. **integration**: ThrowingMockTransport で測定失敗 → 段階維持 / 成功復帰 → 昇格再開

## Error Handling

- `stages.isEmpty`: `BackoffController.init` で `precondition(!stages.isEmpty)`
- `promoteAfter <= 0`: `precondition(promoteAfter > 0)`
- スレッド安全性: NTPSyncEngine 既存の `NSLock` を再利用

## Migration

1. PeerClock 内部のテストで `syncInterval` を渡しているものを `syncBackoffStages` に置換
2. Demo アプリは Configuration デフォルトを使うので変更不要
3. `Configuration.syncInterval` パラメータは残置 (deprecated)、将来 Phase 4 で削除検討

## Open Questions

なし (設計レビュー通過済み)。

## Risks

- **テストの実行時間**: バックオフが効くと高速テストでの sync interval が大きくなる可能性。影響を受ける既存テストは `syncBackoffStages: [0.05]` 等の単段で対処。
- **PeerClock Facade の DriftMonitor 購読**: 既存実装の有無を実装時に要確認。なければ購読を新設する追加作業が発生。
