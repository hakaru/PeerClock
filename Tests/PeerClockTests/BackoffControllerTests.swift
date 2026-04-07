import Testing
@testable import PeerClock

@Suite("BackoffController")
struct BackoffControllerTests {

    @Test("初期状態は stage 0")
    func initialStage() {
        let b = BackoffController(stages: [5, 10, 20, 30], promoteAfter: 3)
        #expect(b.stageIndex == 0)
        #expect(b.currentInterval == 5)
    }

    @Test("連続 promoteAfter 回成功で昇格")
    func promoteOnSuccess() {
        var b = BackoffController(stages: [5, 10, 20, 30], promoteAfter: 3)
        b.recordSuccess(); b.recordSuccess()
        #expect(b.stageIndex == 0)
        b.recordSuccess()
        #expect(b.stageIndex == 1)
        #expect(b.currentInterval == 10)
        b.recordSuccess(); b.recordSuccess(); b.recordSuccess()
        #expect(b.stageIndex == 2)
        #expect(b.currentInterval == 20)
    }

    @Test("最終段で頭打ち")
    func saturateAtLastStage() {
        var b = BackoffController(stages: [5, 10], promoteAfter: 2)
        b.recordSuccess(); b.recordSuccess()
        #expect(b.stageIndex == 1)
        b.recordSuccess(); b.recordSuccess(); b.recordSuccess()
        #expect(b.stageIndex == 1)
        #expect(b.currentInterval == 10)
    }

    @Test("失敗は stage を維持し streak のみリセット")
    func failureKeepsStage() {
        var b = BackoffController(stages: [5, 10, 20], promoteAfter: 3)
        b.recordSuccess(); b.recordSuccess(); b.recordSuccess()
        b.recordSuccess(); b.recordSuccess()
        b.recordFailure()
        #expect(b.stageIndex == 1)
        b.recordSuccess(); b.recordSuccess()
        #expect(b.stageIndex == 1)
        b.recordSuccess()
        #expect(b.stageIndex == 2)
    }

    @Test("reset で初期段階へ")
    func resetReturnsToStageZero() {
        var b = BackoffController(stages: [5, 10, 20, 30], promoteAfter: 2)
        b.recordSuccess(); b.recordSuccess()
        b.recordSuccess(); b.recordSuccess()
        #expect(b.stageIndex == 2)
        b.reset()
        #expect(b.stageIndex == 0)
        #expect(b.currentInterval == 5)
    }

    @Test("単一段では昇格しない")
    func singleStage() {
        var b = BackoffController(stages: [5], promoteAfter: 3)
        b.recordSuccess(); b.recordSuccess(); b.recordSuccess(); b.recordSuccess()
        #expect(b.stageIndex == 0)
        #expect(b.currentInterval == 5)
    }
}
