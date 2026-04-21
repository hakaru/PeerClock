import Foundation
import Observation

@Observable
@MainActor
final class MetronomeViewModel {
    var bpm: Int = 120
    var timeSignature: TimeSignature = .fourFour
    var isPlaying: Bool = false
    var currentBeat: Int = 0
    var flashIntensity: Double = 0
    var peerCount: Int = 0
    var syncState: PeerSyncState = .disconnected
    var debugStatus: String = ""

    private let engine = MetronomeEngine()
    private let peerService = PeerMetronomeService()

    func setup() async {
        await engine.setOnTick { [weak self] tickType, beatIndex in
            Task { @MainActor in
                guard let self else { return }
                self.currentBeat = beatIndex
                switch tickType {
                case .downbeat: self.flashIntensity = 1.0
                case .beat: self.flashIntensity = 0.6
                case .subdivision: self.flashIntensity = 0.25
                }
                try? await Task.sleep(for: .milliseconds(80))
                self.flashIntensity = 0
            }
        }

        // Connect PeerClock sync provider
        let service = peerService
        await engine.setSyncProvider {
            return service.syncedNow
        }

        // Handle incoming config from peers
        peerService.onConfigReceived = { [weak self] config, applyAtNs in
            guard let self else { return }
            self.bpm = config.bpm
            self.timeSignature = config.timeSignature
            Task {
                await self.engine.updateConfigAt(config, applyAtNs: applyAtNs)
            }
        }

        // Handle incoming play/stop from peers
        peerService.onPlayReceived = { [weak self] playing in
            guard let self else { return }
            Task {
                if playing && !self.isPlaying {
                    await self.syncConfig()
                    do {
                        try await self.engine.start()
                        self.isPlaying = true
                    } catch {}
                } else if !playing && self.isPlaying {
                    await self.engine.stop()
                    self.isPlaying = false
                    self.flashIntensity = 0
                }
            }
        }

        await peerService.start()

        // Poll peer count and sync state
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self.peerCount = self.peerService.peerCount
                self.syncState = self.peerService.syncState
                self.debugStatus = self.peerService.debugStatus
            }
        }
    }

    func togglePlay() async {
        if isPlaying {
            await engine.stop()
            isPlaying = false
            flashIntensity = 0
            if peerService.hasPeers {
                await peerService.broadcastPlay(false)
            }
        } else {
            await syncConfig()
            do {
                try await engine.start()
                isPlaying = true
                if peerService.hasPeers {
                    await peerService.broadcastPlay(true)
                }
            } catch {
                isPlaying = false
            }
        }
    }

    func setBPM(_ newBPM: Int) async {
        let clamped = max(30, min(300, newBPM))
        bpm = clamped
        let config = makeConfig()
        let applyAt = await engine.nextDownbeatApplyTime()
        await engine.updateConfigAt(config, applyAtNs: applyAt)
        if peerService.hasPeers {
            await peerService.broadcastConfig(config, applyAtNs: applyAt)
        }
    }

    func setTimeSignature(_ ts: TimeSignature) async {
        timeSignature = ts
        let config = makeConfig()
        let applyAt = await engine.nextDownbeatApplyTime()
        await engine.updateConfigAt(config, applyAtNs: applyAt)
        if peerService.hasPeers {
            await peerService.broadcastConfig(config, applyAtNs: applyAt)
        }
    }

    private func syncConfig() async {
        await engine.updateConfig(makeConfig())
    }

    func getBarProgress() async -> Double {
        await engine.barProgress()
    }

    private func makeConfig() -> MetronomeConfig {
        MetronomeConfig(bpm: bpm, timeSignature: timeSignature)
    }
}
