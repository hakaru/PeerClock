import SwiftUI

struct NTPStatusPanel: View {
    let syncState: SyncState
    let serverHost: String?
    let ntpOffset: TimeInterval?
    let rtt: TimeInterval?
    let stratum: Int?
    var peerCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            if let serverHost {
                row("Server", serverHost)
            }
            if let ntpOffset {
                row("Offset", String(format: "%+.3f ms", ntpOffset * 1000))
            }
            if let rtt {
                row("RTT", String(format: "%.1f ms", rtt * 1000))
            }
            if let stratum {
                row("Stratum", "\(stratum)")
            }
            if peerCount > 0 {
                row("Peers", "\(peerCount) connected")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.white)
        }
    }

    private var statusColor: Color {
        switch syncState {
        case .synced: .green
        case .syncing: .yellow
        case .offline: .orange
        case .error: .red
        case .idle: .gray
        }
    }

    private var statusText: String {
        switch syncState {
        case .synced: "NTP Synced"
        case .syncing: "Syncing…"
        case .offline: "Offline"
        case .error(let msg): "Error: \(msg)"
        case .idle: "Idle"
        }
    }
}
