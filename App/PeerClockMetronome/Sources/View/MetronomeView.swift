import SwiftUI

struct MetronomeView: View {
    @State private var viewModel = MetronomeViewModel()
    @State private var conductorProgress: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let _ = updateProgress()
            VStack(spacing: 16) {
                Text(viewModel.debugStatus)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.gray)
                    .padding(.top, 8)

                BPMDisplay(bpm: viewModel.bpm) { delta in
                    Task { await viewModel.setBPM(viewModel.bpm + delta) }
                }

                TimeSignaturePicker(selection: viewModel.timeSignature) { ts in
                    Task { await viewModel.setTimeSignature(ts) }
                }

                ConductorView(
                    beatsPerBar: viewModel.timeSignature.conductorBeats,
                    currentBeat: viewModel.currentBeat,
                    progress: conductorProgress,
                    isPlaying: viewModel.isPlaying
                )
                .frame(height: 220)
                .padding(.horizontal, 24)

                Button {
                    Task { await viewModel.togglePlay() }
                } label: {
                    Image(systemName: viewModel.isPlaying ? "stop.fill" : "play.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                        .frame(width: 80, height: 80)
                        .background(.cyan, in: Circle())
                }

                SyncStatusPanel(
                    peerCount: viewModel.peerCount,
                    syncState: viewModel.syncState
                )
                .padding(.horizontal)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Color.cyan.opacity(viewModel.flashIntensity * 0.3)
            )
            .background(.black)
        }
        .task {
            await viewModel.setup()
        }
    }

    private func updateProgress() {
        Task {
            conductorProgress = await viewModel.getBarProgress()
        }
    }
}
