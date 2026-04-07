import Foundation

/// 同期成功の連続回数に応じて sync interval を段階的に延長する純粋ロジック。
///
/// stages の先頭から順に進む。各段階で `promoteAfter` 回連続成功で次段へ昇格。
/// 失敗時は段階維持、successStreak のみリセット (頻繁な降格を避ける)。
/// jump 検出時など外部から `reset()` で初期段階に戻す。
struct BackoffController {
    let stages: [TimeInterval]
    let promoteAfter: Int

    private(set) var stageIndex: Int = 0
    private var successStreak: Int = 0

    init(stages: [TimeInterval], promoteAfter: Int) {
        precondition(!stages.isEmpty, "BackoffController.stages must not be empty")
        precondition(promoteAfter > 0, "BackoffController.promoteAfter must be > 0")
        self.stages = stages
        self.promoteAfter = promoteAfter
    }

    var currentInterval: TimeInterval { stages[stageIndex] }

    mutating func recordSuccess() {
        guard stageIndex < stages.count - 1 else {
            successStreak = 0
            return
        }
        successStreak += 1
        if successStreak >= promoteAfter {
            stageIndex += 1
            successStreak = 0
        }
    }

    mutating func recordFailure() {
        successStreak = 0
    }

    mutating func reset() {
        stageIndex = 0
        successStreak = 0
    }
}
