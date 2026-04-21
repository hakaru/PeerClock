import SwiftUI

struct ClockView: View {
    @State private var viewModel = ClockViewModel()
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
                stratum: viewModel.stratum
            )
            .padding()

            SparklineView(values: viewModel.offsetHistory)
                .frame(height: 60)
                .padding(.horizontal)
                .padding(.bottom)
        }
        .background(.black)
        .task {
            await viewModel.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            Task {
                if newPhase == .active {
                    await viewModel.start()
                } else if newPhase == .background {
                    await viewModel.stop()
                }
            }
        }
    }
}
