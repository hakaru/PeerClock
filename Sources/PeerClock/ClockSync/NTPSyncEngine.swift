import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - NTPSyncEngine

/// 4タイムスタンプ交換 (NTP-style) によるクロック同期エンジン。
///
/// アルゴリズム概要:
/// 1. `syncMeasurements` 回の SYNC_REQUEST を送信し SYNC_RESPONSE を収集する
/// 2. 遅延 (delay) でソートして下位50%を選別 (bestHalfFilter)
/// 3. 残った測定値の平均オフセットを計算し currentOffset に反映する
/// 4. `syncInterval` 秒待機して繰り返す
public final class NTPSyncEngine: SyncEngine, @unchecked Sendable {

    // MARK: - Properties

    private let transport: any Transport
    private let configuration: Configuration

    /// ロック保護されたクロックオフセット (秒単位)
    private let lock = NSLock()
    private var _currentOffset: TimeInterval = 0.0

    public var currentOffset: TimeInterval {
        lock.withLock { _currentOffset }
    }

    /// コーディネーターのPeerID
    private var coordinatorID: PeerID?

    /// 同期ループのタスク
    private var syncTask: Task<Void, Never>?

    /// SyncState を流す AsyncStream とその Continuation
    public let syncStateUpdates: AsyncStream<SyncState>
    private let syncStateContinuation: AsyncStream<SyncState>.Continuation

    // MARK: - Init

    public init(transport: any Transport, configuration: Configuration = .default) {
        self.transport = transport
        self.configuration = configuration

        var continuation: AsyncStream<SyncState>.Continuation!
        self.syncStateUpdates = AsyncStream { continuation = $0 }
        self.syncStateContinuation = continuation
    }

    // MARK: - SyncEngine

    public func start(coordinator: PeerID) async {
        lock.withLock { self.coordinatorID = coordinator }
        syncStateContinuation.yield(.syncing)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runSyncLoop()
        }
        lock.withLock { self.syncTask = task }
    }

    public func stop() async {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let t = syncTask
            syncTask = nil
            return t
        }
        task?.cancel()
        // タスクが終了するまで待機
        await task?.value
        syncStateContinuation.finish()
    }

    // MARK: - Core Loop

    private func runSyncLoop() async {
        while !Task.isCancelled {
            guard let coordinatorID = lock.withLock({ self.coordinatorID }) else { break }

            let measurements = await collectMeasurements(coordinator: coordinatorID)

            guard !measurements.isEmpty else {
                // 測定失敗 — 次のサイクルへ
                try? await Task.sleep(for: .seconds(configuration.syncInterval))
                continue
            }

            let filtered = NTPSyncEngine.bestHalfFilter(measurements)
            let offsetNs = NTPSyncEngine.meanOffset(filtered)
            let offsetSeconds = offsetNs / 1_000_000_000.0

            lock.withLock { self._currentOffset = offsetSeconds }

            // 代表的な quality 情報を生成 (最速の1件を使用)
            let bestDelay = filtered.min(by: { $0.delay < $1.delay })?.delay ?? 0
            let quality = SyncQuality(
                offsetNs: Int64(offsetNs),
                roundTripDelayNs: bestDelay,
                confidence: min(1.0, Double(filtered.count) / Double(configuration.syncMeasurements))
            )
            syncStateContinuation.yield(.synced(offset: offsetSeconds, quality: quality))

            do {
                try await Task.sleep(for: .seconds(configuration.syncInterval))
            } catch {
                break
            }
        }
    }

    // MARK: - Measurement Collection

    /// コーディネーターと SYNC_REQUEST/SYNC_RESPONSE を交換してオフセット測定値を収集する。
    private func collectMeasurements(coordinator: PeerID) async -> [(offset: Double, delay: UInt64)] {
        let count = configuration.syncMeasurements
        let interval = configuration.syncMeasurementInterval

        // 測定結果を蓄積するアクター
        let collector = MeasurementCollector()

        // レスポンスリスナータスク
        let listenerTask = Task { [transport] in
            for await (sender, data) in transport.unreliableMessages {
                guard sender == coordinator else { continue }
                guard let message = try? MessageCodec.decode(data),
                      message.category == .syncResponse,
                      let (t0, t1, t2) = try? MessageCodec.decodeSyncResponse(message.payload)
                else { continue }

                let t3 = NTPSyncEngine.now()
                let offset = NTPSyncEngine.calculateOffset(t0: t0, t1: t1, t2: t2, t3: t3)
                let delay = NTPSyncEngine.calculateDelay(t0: t0, t1: t1, t2: t2, t3: t3)
                await collector.add(offset: offset, delay: delay)
            }
        }

        // SYNC_REQUEST 送信ループ
        for _ in 0..<count {
            guard !Task.isCancelled else { break }
            let t0 = NTPSyncEngine.now()
            let payload = MessageCodec.encodeSyncRequest(t0: t0)
            let message = WireMessage(category: .syncRequest, payload: payload)
            let data = MessageCodec.encode(message)
            try? await transport.sendUnreliable(data, to: coordinator)

            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                break
            }
        }

        // 全レスポンスが届く余裕を少し待ってからリスナーをキャンセル
        try? await Task.sleep(for: .milliseconds(100))
        listenerTask.cancel()

        return await collector.measurements
    }

    // MARK: - Static Calculation Methods

    /// NTPオフセット計算: offset = ((t1 - t0) + (t2 - t3)) / 2 (ナノ秒)
    public static func calculateOffset(t0: UInt64, t1: UInt64, t2: UInt64, t3: UInt64) -> Double {
        let d1 = Double(Int64(bitPattern: t1 &- t0))
        let d2 = Double(Int64(bitPattern: t2 &- t3))
        return (d1 + d2) / 2.0
    }

    /// 往復遅延計算: delay = (t3 - t0) - (t2 - t1) (ナノ秒)
    public static func calculateDelay(t0: UInt64, t1: UInt64, t2: UInt64, t3: UInt64) -> UInt64 {
        let roundTrip = t3 &- t0
        let processing = t2 &- t1
        return roundTrip &- processing
    }

    /// 遅延昇順でソートし下位50%を返す (ベストハーフフィルター)
    public static func bestHalfFilter(
        _ measurements: [(offset: Double, delay: UInt64)]
    ) -> [(offset: Double, delay: UInt64)] {
        guard !measurements.isEmpty else { return [] }
        let sorted = measurements.sorted { $0.delay < $1.delay }
        let keepCount = max(1, (sorted.count + 1) / 2)
        return Array(sorted.prefix(keepCount))
    }

    /// 測定値群の平均オフセットを返す (ナノ秒)
    public static func meanOffset(_ measurements: [(offset: Double, delay: UInt64)]) -> Double {
        guard !measurements.isEmpty else { return 0.0 }
        let sum = measurements.reduce(0.0) { $0 + $1.offset }
        return sum / Double(measurements.count)
    }

    /// mach_continuous_time を利用した現在時刻 (ナノ秒)
    public static func now() -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = mach_continuous_time()
        return ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}

// MARK: - MeasurementCollector

/// 非同期コンテキストで測定値を安全に蓄積するアクター
private actor MeasurementCollector {
    var measurements: [(offset: Double, delay: UInt64)] = []

    func add(offset: Double, delay: UInt64) {
        measurements.append((offset: offset, delay: delay))
    }
}
