import AVFoundation
import Darwin

actor MetronomeEngine {
    private let synthesizer = ClickSynthesizer()
    private var config = MetronomeConfig()
    private var isPlaying = false
    private var schedulerTask: Task<Void, Never>?
    private var currentSubBeat: Int = 0
    private var nextBeatHostTime: UInt64 = 0
    private var onTick: (@Sendable (TickType, Int) -> Void)?

    // Pending config change to apply at a future synced time
    private var pendingConfig: MetronomeConfig?
    private var pendingApplyAtHost: UInt64 = 0

    // P2P sync: provide synced nanoseconds from PeerClock
    var syncedNowProvider: (@Sendable () -> UInt64)?

    private static let machTimebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    func setOnTick(_ handler: @escaping @Sendable (TickType, Int) -> Void) {
        onTick = handler
    }

    func setSyncProvider(_ provider: @escaping @Sendable () -> UInt64) {
        syncedNowProvider = provider
    }

    func start() throws {
        guard !isPlaying else { return }
        try synthesizer.start()
        isPlaying = true
        currentSubBeat = 0

        if syncedNowProvider != nil {
            calculateNextBeatFromSyncedClock()
        } else {
            nextBeatHostTime = mach_absolute_time() + nsToMach(50_000_000)
        }

        startSchedulerLoop()
    }

    func stop() {
        isPlaying = false
        schedulerTask?.cancel()
        schedulerTask = nil
        synthesizer.stop()
    }

    func updateConfig(_ newConfig: MetronomeConfig) {
        config = newConfig
        if syncedNowProvider != nil {
            calculateNextBeatFromSyncedClock()
        } else {
            currentSubBeat = 0
        }
    }

    func updateConfigAt(_ newConfig: MetronomeConfig, applyAtNs: UInt64) {
        if let provider = syncedNowProvider {
            let syncedNow = provider()
            let hostNow = mach_absolute_time()
            if applyAtNs > syncedNow {
                let deltaNs = applyAtNs - syncedNow
                pendingConfig = newConfig
                pendingApplyAtHost = hostNow + nsToMach(deltaNs)
            } else {
                config = newConfig
                currentSubBeat = 0
                calculateNextBeatFromSyncedClock()
            }
        } else {
            config = newConfig
            currentSubBeat = 0
        }
    }

    func getConfig() -> MetronomeConfig {
        config
    }

    /// Calculate applyAtNs: next downbeat after now + 500ms
    func nextDownbeatApplyTime() -> UInt64 {
        guard let provider = syncedNowProvider else { return 0 }
        let now = provider()
        let beatIntervalNs = UInt64(config.beatIntervalSeconds * 1_000_000_000)
        let barIntervalNs = beatIntervalNs * UInt64(config.beatsPerBar)
        let target = now + 500_000_000 // 500ms from now
        let nextBar = ((target / barIntervalNs) + 1) * barIntervalNs
        return nextBar
    }

    private func calculateNextBeatFromSyncedClock() {
        guard let provider = syncedNowProvider else { return }
        let syncedNow = provider()
        let hostNow = mach_absolute_time()
        let subIntervalNs = UInt64(config.subIntervalSeconds * 1_000_000_000)

        guard subIntervalNs > 0 else { return }

        // Find next sub-beat boundary in synced clock
        let nextSubBeatSynced = ((syncedNow / subIntervalNs) + 1) * subIntervalNs
        let deltaNs = nextSubBeatSynced - syncedNow

        nextBeatHostTime = hostNow + nsToMach(deltaNs)

        // Calculate which sub-beat we're at
        let totalSubsPerBar = UInt64(config.beatsPerBar * config.subdivision.rawValue)
        currentSubBeat = Int((nextSubBeatSynced / subIntervalNs) % totalSubsPerBar)
    }

    private func startSchedulerLoop() {
        schedulerTask?.cancel()
        schedulerTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let playing = await self.isPlaying
                guard playing else { return }
                await self.scheduleUpcoming()
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    private func scheduleUpcoming() {
        let now = mach_absolute_time()
        let lookaheadNs: UInt64 = 150_000_000
        let horizon = now + nsToMach(lookaheadNs)

        // Apply pending config if its time has arrived
        if let pending = pendingConfig, now >= pendingApplyAtHost {
            config = pending
            pendingConfig = nil
            currentSubBeat = 0
            if syncedNowProvider != nil {
                calculateNextBeatFromSyncedClock()
            } else {
                nextBeatHostTime = pendingApplyAtHost
            }
        }

        let subIntervalNs = UInt64(config.subIntervalSeconds * 1_000_000_000)
        let subIntervalMach = nsToMach(subIntervalNs)
        let totalSubsPerBar = config.beatsPerBar * config.subdivision.rawValue

        guard subIntervalMach > 0 else { return }

        if nextBeatHostTime < now {
            if syncedNowProvider != nil {
                calculateNextBeatFromSyncedClock()
            } else {
                nextBeatHostTime = now + nsToMach(10_000_000)
                currentSubBeat = 0
            }
        }

        while nextBeatHostTime <= horizon {
            // Stop scheduling past the pending config boundary
            if pendingConfig != nil, nextBeatHostTime >= pendingApplyAtHost {
                break
            }

            let tickType = tickTypeFor(subBeat: currentSubBeat)
            let audioTime = AVAudioTime(hostTime: nextBeatHostTime)

            synthesizer.scheduleClick(tickType, at: audioTime)

            let beatIndex = (currentSubBeat / config.subdivision.rawValue) % config.beatsPerBar
            onTick?(tickType, beatIndex)

            currentSubBeat = (currentSubBeat + 1) % totalSubsPerBar
            nextBeatHostTime += subIntervalMach
        }
    }

    private func tickTypeFor(subBeat: Int) -> TickType {
        let subsPerBeat = config.subdivision.rawValue
        if subBeat == 0 {
            return .downbeat
        } else if subBeat % subsPerBeat == 0 {
            return .beat
        } else {
            return .subdivision
        }
    }

    private func nsToMach(_ ns: UInt64) -> UInt64 {
        UInt64(Double(ns) / Self.machTimebase)
    }
}
