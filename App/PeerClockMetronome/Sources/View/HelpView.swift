import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // About
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PeerClock Metronome")
                            .font(.title2.bold())
                            .foregroundStyle(.cyan)
                        Text("P2P同期メトロノーム。複数のAppleデバイスを同じWiFiに接続するだけで、サーバーなしで自動的にクロック同期（±2ms精度）し、全デバイスが完全に同期した拍を刻みます。")
                            .foregroundStyle(.white.opacity(0.8))
                    }

                    Divider().background(.white.opacity(0.1))

                    // Features
                    VStack(alignment: .leading, spacing: 12) {
                        Text("特徴")
                            .font(.headline.bold())
                            .foregroundStyle(.cyan)

                        FeatureRow(icon: "person.2", text: "対等ピアツーピア — マスター/スレーブなし、全デバイスが対等")
                        FeatureRow(icon: "clock", text: "±2ms クロック同期 — NTP風4タイムスタンプ交換")
                        FeatureRow(icon: "wifi", text: "WiFi経由 — 外部サーバー不要、ローカルネットワークのみ")
                        FeatureRow(icon: "arrow.triangle.2.circlepath", text: "自動同期 — 同じWiFiに接続するだけで自動発見・同期")
                    }

                    Divider().background(.white.opacity(0.1))

                    // Usage
                    VStack(alignment: .leading, spacing: 12) {
                        Text("使い方")
                            .font(.headline.bold())
                            .foregroundStyle(.cyan)

                        UsageRow(number: "1", text: "複数のデバイスでアプリを起動")
                        UsageRow(number: "2", text: "同じWiFiに接続 → 自動的にピアを発見")
                        UsageRow(number: "3", text: "画面下部の「Synced」表示を確認")
                        UsageRow(number: "4", text: "どちらのデバイスからでもPlay/BPM変更可能 — 全デバイスに同期")
                    }
                }
                .padding(24)
            }
            .background {
                LinearGradient(
                    colors: [
                        Color(red: 0.02, green: 0.02, blue: 0.06),
                        Color(red: 0.04, green: 0.06, blue: 0.12),
                        Color(red: 0.02, green: 0.02, blue: 0.06)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
            .navigationTitle("ヘルプ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.cyan)
                .frame(width: 20)
            Text(text)
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

private struct UsageRow: View {
    let number: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan)
                .frame(width: 20)
            Text(text)
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}
