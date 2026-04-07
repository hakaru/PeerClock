// Examples/PeerClockDemo/PeerClockDemo/ContentView.swift
import SwiftUI
import PeerClock

struct ContentView: View {
    @State private var viewModel = PeerClockViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    syncStatusSection
                    peersSection
                    commandsSection
                    scheduledEventSection
                    logSection
                }
                .padding()
            }
            .navigationTitle("PeerClock Demo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            switch viewModel.runState {
                            case .stopped, .error:
                                await viewModel.start()
                            case .running:
                                await viewModel.stop()
                            case .starting:
                                break
                            }
                        }
                    } label: {
                        switch viewModel.runState {
                        case .stopped, .error:
                            Label("Start", systemImage: "play.circle.fill")
                        case .starting:
                            ProgressView()
                        case .running:
                            Label("Stop", systemImage: "stop.circle.fill")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var syncStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sync Status")
                .font(.headline)

            HStack {
                Circle()
                    .fill(syncColor)
                    .frame(width: 12, height: 12)
                Text(viewModel.syncStateLabel)
                    .font(.body)
                Spacer()
                if viewModel.syncStateLabel == "synced" {
                    Text(String(format: "%+.2fms", viewModel.syncOffsetMs))
                        .font(.system(.body, design: .monospaced))
                    Text(String(format: "%.0f%%", viewModel.syncConfidence * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Coordinator:")
                    .foregroundStyle(.secondary)
                Text(viewModel.coordinatorLabel)
                    .font(.system(.caption, design: .monospaced))
                if viewModel.isLocalCoordinator {
                    Text("(self)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack {
                Text("Local:")
                    .foregroundStyle(.secondary)
                Text(viewModel.localPeerID)
                    .font(.system(.caption, design: .monospaced))
                Spacer()
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var syncColor: Color {
        switch viewModel.syncStateLabel {
        case "synced": return .green
        case "syncing": return .yellow
        case "discovering": return .blue
        case "error": return .red
        default: return .gray
        }
    }

    private var peersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Peers (\(viewModel.remotePeers.count))")
                .font(.headline)

            if viewModel.remotePeers.isEmpty {
                Text("No peers connected")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(viewModel.remotePeers) { peer in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "iphone")
                            Text(peer.name)
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Text(connectionLabel(peer.connectionState))
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(connectionColor(peer.connectionState).opacity(0.2))
                                .foregroundStyle(connectionColor(peer.connectionState))
                                .clipShape(Capsule())
                        }
                        if peer.statusSummary != "-" && !peer.statusSummary.isEmpty {
                            Text(peer.statusSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 22)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var commandsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Commands")
                    .font(.headline)
                Spacer()
                Button("Broadcast Ping") {
                    Task { await viewModel.broadcastPing() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!isRunning)
            }

            if viewModel.commandLog.isEmpty {
                Text("No commands yet")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(viewModel.commandLog.prefix(10)) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: entry.direction == .sent
                              ? "arrow.up.circle.fill"
                              : "arrow.down.circle.fill")
                            .foregroundStyle(entry.direction == .sent ? .blue : .green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.type)
                                .font(.caption.bold())
                            Text(entry.payload)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(entry.peerLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var scheduledEventSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scheduled Events")
                .font(.headline)
            HStack {
                Button("Schedule +3s") {
                    Task { await viewModel.scheduleBeepIn3Seconds() }
                }
                .buttonStyle(.bordered)
                .disabled(!isRunning)

                Button("Cancel") {
                    Task { await viewModel.cancelScheduledBeep() }
                }
                .buttonStyle(.bordered)
                .disabled(!isRunning)
            }
            Text(viewModel.lastScheduledFireLog)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Log")
                .font(.headline)

            if viewModel.logs.isEmpty {
                Text("No log entries")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(viewModel.logs.prefix(20)) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text(Self.timeFormatter.string(from: entry.timestamp))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.caption)
                        Spacer()
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func connectionLabel(_ state: ConnectionState) -> String {
        switch state {
        case .connected: return "connected"
        case .degraded: return "degraded"
        case .disconnected: return "disconnected"
        }
    }

    private func connectionColor(_ state: ConnectionState) -> Color {
        switch state {
        case .connected: return .green
        case .degraded: return .orange
        case .disconnected: return .red
        }
    }

    private var isRunning: Bool {
        if case .running = viewModel.runState { return true }
        return false
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

#Preview {
    ContentView()
}
