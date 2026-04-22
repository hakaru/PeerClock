import SwiftUI

struct SyncStatusPanel: View {
    let peerCount: Int
    let syncState: PeerSyncState

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .shadow(color: statusColor.opacity(0.8), radius: 4)

            Text(statusText)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(statusColor)

            if case .synced(let offsetMs, _) = syncState {
                Text(String(format: "±%.1fms", offsetMs))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }

            Spacer()

            if peerCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 10))
                    Text("\(peerCount)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.cyan.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private var statusColor: Color {
        switch syncState {
        case .disconnected: .white.opacity(0.25)
        case .searching: .yellow
        case .synced: .green
        }
    }

    private var statusText: String {
        switch syncState {
        case .disconnected: "Standalone"
        case .searching: "Searching…"
        case .synced: "Synced"
        }
    }
}
