import Darwin
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
    private var streamTasks: [Task<Void, Never>] = []

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

        await peerService.start()

        if let timebase = await peerService.getTimebase() {
            await engine.setSyncProvider {
                timebase.syncedNow()
            }
        }

        let snapshots = peerService.snapshots
        streamTasks.append(Task { [weak self] in
            for await snap in snapshots {
                await MainActor.run {
                    guard let self else { return }
                    self.peerCount = snap.peerCount
                    self.syncState = snap.syncState
                    self.debugStatus = snap.debugStatus
                }
            }
        })

        let configEvents = peerService.configEvents
        streamTasks.append(Task { [weak self] in
            for await (config, applyAtNs) in configEvents {
                guard let self else { return }
                await self.engine.updateConfigAt(config, applyAtNs: applyAtNs)
                await MainActor.run {
                    self.bpm = config.bpm
                    self.timeSignature = config.timeSignature
                }
            }
        })

        let playEvents = peerService.playEvents
        streamTasks.append(Task { [weak self] in
            for await playing in playEvents {
                guard let self else { return }
                await self.handleRemotePlay(playing)
            }
        })
    }

    private func handleRemotePlay(_ playing: Bool) async {
        let currentlyPlaying = await MainActor.run { self.isPlaying }
        if playing && !currentlyPlaying {
            await syncConfig()
            do {
                try await engine.start()
                await MainActor.run { self.isPlaying = true }
            } catch {}
        } else if !playing && currentlyPlaying {
            await engine.stop()
            await MainActor.run {
                self.isPlaying = false
                self.flashIntensity = 0
            }
        }
    }

    func togglePlay() async {
        if isPlaying {
            await engine.stop()
            isPlaying = false
            flashIntensity = 0
            if await peerService.hasPeers {
                await peerService.broadcastPlay(false)
            }
        } else {
            await syncConfig()
            do {
                try await engine.start()
                isPlaying = true
                if await peerService.hasPeers {
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
        if await peerService.hasPeers {
            await peerService.broadcastConfig(config, applyAtNs: applyAt)
        }
    }

    func setTimeSignature(_ ts: TimeSignature) async {
        timeSignature = ts
        let config = makeConfig()
        let applyAt = await engine.nextDownbeatApplyTime()
        await engine.updateConfigAt(config, applyAtNs: applyAt)
        if await peerService.hasPeers {
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
