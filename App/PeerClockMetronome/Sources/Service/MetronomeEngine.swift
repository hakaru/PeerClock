import AVFoundation
import Darwin

enum EngineMode: Sendable {
    case internalAuto
    case external
}

actor MetronomeEngine {
    private let synthesizer = ClickSynthesizer()
    private var config = MetronomeConfig()
    private var isPlaying = false
    private var mode: EngineMode = .internalAuto
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
        mode = .internalAuto
        currentSubBeat = 0

        if syncedNowProvider != nil {
            calculateNextBeatFromSyncedClock()
        } else {
            nextBeatHostTime = mach_absolute_time() + nsToMach(50_000_000)
        }

        startSchedulerLoop()
    }

    /// Enter External mode: synthesizer ready, no auto-scheduling.
    /// Conductor or remote BeatEvents drive playback via playExternalBeat.
    func startExternal() throws {
        if !isPlaying {
            try synthesizer.start()
            isPlaying = true
        }
        mode = .external
        schedulerTask?.cancel()
        schedulerTask = nil
    }

    /// Schedule a single click at the given host time. Used in External mode.
    func playExternalBeat(hostTime: UInt64, beatIndex: Int, tickType: TickType) {
        guard isPlaying, mode == .external else { return }
        let audioTime = AVAudioTime(hostTime: hostTime)
        synthesizer.scheduleClick(tickType, at: audioTime)
        onTick?(tickType, beatIndex)
    }

    /// Resume Internal auto-scheduling with phase inherited from the last external beat.
    /// - anchorHostTime: host time of the most recent played external beat
    /// - anchorBeatIndex: beat-in-bar of that beat (0-based)
    /// - beatIntervalNs: desired beat interval after resume (derived from last BPM)
    /// - resumeHostTime: current host time (future beats must be > this)
    func resumeInternalFromExternal(anchorHostTime: UInt64,
                                    anchorBeatIndex: Int,
                                    beatIntervalNs: UInt64,
                                    resumeHostTime: UInt64 = mach_absolute_time()) {
        guard beatIntervalNs > 0 else { return }

        // Derive a matching config (same time signature, new BPM from interval)
        let beatIntervalSec = Double(beatIntervalNs) / 1_000_000_000
        let bpm = max(30, min(300, Int((60.0 / beatIntervalSec).rounded())))
        config = MetronomeConfig(bpm: bpm, timeSignature: config.timeSignature)

        let subsPerBeat = config.subdivisionsPerBeat
        let totalSubs = config.totalSubsPerBar
        let beatIntervalMach = nsToMach(beatIntervalNs)
        let subIntervalMach = beatIntervalMach / UInt64(subsPerBeat)
        let schedulingBuffer = nsToMach(20_000_000) // 20ms safety

        // Next beat starts 1 beat after the anchor. Advance until future.
        var nextBeatTime = anchorHostTime + beatIntervalMach
        var nextBeatIdx = (anchorBeatIndex + 1) % config.beatsPerBar
        let minFuture = resumeHostTime + schedulingBuffer

        while nextBeatTime < minFuture {
            nextBeatTime += beatIntervalMach
            nextBeatIdx = (nextBeatIdx + 1) % config.beatsPerBar
        }

        mode = .internalAuto
        currentSubBeat = nextBeatIdx * subsPerBeat
        nextBeatHostTime = nextBeatTime
        // Suppress the "past → resync from synced clock" branch in scheduleUpcoming
        pendingConfig = nil
        _ = subIntervalMach  // silence unused warning; subInterval derived in scheduleUpcoming
        startSchedulerLoop()
    }

    func getMode() -> EngineMode { mode }

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
                calculateNextBeatFromSyncedClock()
            }
        } else if isPlaying {
            config = newConfig
        } else {
            config = newConfig
            currentSubBeat = 0
        }
    }

    func getConfig() -> MetronomeConfig {
        config
    }

    func barProgress() -> Double {
        guard isPlaying else { return 0 }
        let now = mach_absolute_time()
        let subIntervalMach = nsToMach(UInt64(config.subIntervalSeconds * 1_000_000_000))
        guard subIntervalMach > 0 else { return 0 }

        let totalSubs = config.totalSubsPerBar

        // currentSubBeat/nextBeatHostTime may be scheduled ahead of playback.
        // Compute actual playback position by subtracting the lead time.
        let subsUntilNext: Double = nextBeatHostTime > now
            ? Double(nextBeatHostTime - now) / Double(subIntervalMach)
            : 0

        var position = Double(currentSubBeat) - subsUntilNext
        if position < 0 { position += Double(totalSubs) }

        let progress = position / Double(totalSubs)
        return max(0, min(0.999, progress))
    }

    /// Calculate applyAtNs for synced BPM change: now + 200ms.
    /// Returns 0 in standalone mode.
    func nextDownbeatApplyTime() -> UInt64 {
        guard let provider = syncedNowProvider else { return 0 }
        return provider() + 200_000_000
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
        let totalSubsPerBar = UInt64(config.totalSubsPerBar)
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
        guard mode == .internalAuto else { return }
        let now = mach_absolute_time()
        let lookaheadNs: UInt64 = 150_000_000
        let horizon = now + nsToMach(lookaheadNs)

        if let pending = pendingConfig, now >= pendingApplyAtHost {
            config = pending
            pendingConfig = nil
            if syncedNowProvider != nil {
                calculateNextBeatFromSyncedClock()
            }
        }

        let subIntervalNs = UInt64(config.subIntervalSeconds * 1_000_000_000)
        let subIntervalMach = nsToMach(subIntervalNs)
        let totalSubsPerBar = config.totalSubsPerBar

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

            let beatIndex = (currentSubBeat / config.subdivisionsPerBeat) % config.beatsPerBar
            onTick?(tickType, beatIndex)

            currentSubBeat = (currentSubBeat + 1) % totalSubsPerBar
            nextBeatHostTime += subIntervalMach
        }
    }

    private func tickTypeFor(subBeat: Int) -> TickType {
        let subsPerBeat = config.subdivisionsPerBeat
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
