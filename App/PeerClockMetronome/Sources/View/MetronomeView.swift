import SwiftUI

struct MetronomeView: View {
    @State private var viewModel = MetronomeViewModel()

    var body: some View {
        VStack(spacing: 24) {
            Text(viewModel.debugStatus)
                .font(.caption2.monospaced())
                .foregroundStyle(.gray)
                .padding(.top, 8)

            Spacer()

            BPMDisplay(bpm: viewModel.bpm) { delta in
                Task { await viewModel.setBPM(viewModel.bpm + delta) }
            }

            SubdivisionPicker(selection: viewModel.subdivision) { sub in
                Task { await viewModel.setSubdivision(sub) }
            }

            BeatIndicator(
                beatsPerBar: 4,
                currentBeat: viewModel.currentBeat,
                isPlaying: viewModel.isPlaying
            )

            Button {
                Task { await viewModel.togglePlay() }
            } label: {
                Image(systemName: viewModel.isPlaying ? "stop.fill" : "play.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                    .frame(width: 80, height: 80)
                    .background(.cyan, in: Circle())
            }

            Spacer()

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
        .animation(.easeOut(duration: 0.08), value: viewModel.flashIntensity)
        .task {
            await viewModel.setup()
        }
    }
}
