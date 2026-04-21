import SwiftUI

struct SyncStatusPanel: View {
    let peerCount: Int
    let syncState: PeerSyncState

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                if case .synced(let offsetMs, let rttMs) = syncState {
                    Text(String(format: "Offset: %+.2fms  RTT: %.1fms", offsetMs, rttMs))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if peerCount > 0 {
                Label("\(peerCount)", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.cyan)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusColor: Color {
        switch syncState {
        case .disconnected: .gray
        case .searching: .yellow
        case .synced: .green
        }
    }

    private var statusText: String {
        switch syncState {
        case .disconnected: "No Peers"
        case .searching: "Searching…"
        case .synced: "Synced"
        }
    }
}
