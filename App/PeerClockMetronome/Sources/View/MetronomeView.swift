import SwiftUI

struct MetronomeView: View {
    @State private var viewModel = MetronomeViewModel()
    @State private var showHelp = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !viewModel.debugStatus.isEmpty {
                    Text(viewModel.debugStatus)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.2))
                }
                Spacer()
                Button {
                    showHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer(minLength: 8)

            BPMDisplay(bpm: viewModel.bpm) { delta in
                Task { await viewModel.setBPM(viewModel.bpm + delta) }
            }

            Spacer().frame(height: 12)

            TimeSignaturePicker(selection: viewModel.timeSignature) { ts in
                Task { await viewModel.setTimeSignature(ts) }
            }

            Spacer(minLength: 12)

            ConductorView(
                beatsPerBar: viewModel.timeSignature.conductorBeats,
                currentBeat: viewModel.currentBeat,
                isPlaying: viewModel.isPlaying,
                progressProvider: { await viewModel.getBarProgress() }
            )
            .frame(maxHeight: 280)
            .padding(.horizontal, 20)

            Spacer(minLength: 16)

            PlayButton(isPlaying: viewModel.isPlaying) {
                Task { await viewModel.togglePlay() }
            }

            Spacer(minLength: 16)

            SyncStatusPanel(
                peerCount: viewModel.peerCount,
                syncState: viewModel.syncState
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.02, green: 0.02, blue: 0.06),
                        Color(red: 0.04, green: 0.06, blue: 0.12),
                        Color(red: 0.02, green: 0.02, blue: 0.06)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Color.cyan.opacity(viewModel.flashIntensity * 0.15)
                RadialGradient(
                    colors: [
                        Color.cyan.opacity(viewModel.isPlaying ? 0.03 : 0),
                        .clear
                    ],
                    center: .center,
                    startRadius: 20,
                    endRadius: 300
                )
            }
        }
        .sheet(isPresented: $showHelp) {
            HelpView()
        }
        .task {
            await viewModel.setup()
        }
    }
}

private struct PlayButton: View {
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.cyan.opacity(isPlaying ? 0.3 : 0.15), lineWidth: 2)
                    .frame(width: 80, height: 80)
                    .shadow(color: .cyan.opacity(isPlaying ? 0.4 : 0), radius: 12)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.cyan.opacity(isPlaying ? 0.4 : 0.2),
                                Color.cyan.opacity(isPlaying ? 0.15 : 0.05)
                            ],
                            center: .center,
                            startRadius: 5,
                            endRadius: 40
                        )
                    )
                    .frame(width: 72, height: 72)

                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white)
                    .offset(x: isPlaying ? 0 : 2)
            }
        }
        .buttonStyle(.plain)
    }
}
