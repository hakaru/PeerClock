import SwiftUI

struct ClockView: View {
    @State private var viewModel = ClockViewModel()
    @State private var peerService = PeerSyncService()
    @State private var flashActive = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            MillisecondClockFace(ntpOffset: viewModel.ntpOffset)
                .frame(maxHeight: .infinity)

            NTPStatusPanel(
                syncState: viewModel.syncState,
                serverHost: viewModel.serverHost,
                ntpOffset: viewModel.ntpOffset,
                rtt: viewModel.rtt,
                stratum: viewModel.stratum,
                peerCount: peerService.peerCount
            )
            .padding()

            SparklineView(values: viewModel.offsetHistory)
                .frame(height: 60)
                .padding(.horizontal)

            Button {
                Task { await peerService.sendFlash() }
            } label: {
                Text("TAP SYNC")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.cyan, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        }
        .background(flashActive ? Color.cyan : Color.black)
        .animation(.easeOut(duration: 0.15), value: flashActive)
        .task {
            await viewModel.start()
            peerService.onFlash = { triggerFlash() }
            await peerService.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            Task {
                if newPhase == .active {
                    await viewModel.start()
                    await peerService.start()
                } else if newPhase == .background {
                    await viewModel.stop()
                    await peerService.stop()
                }
            }
        }
    }

    private func triggerFlash() {
        flashActive = true
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            flashActive = false
        }
    }
}
