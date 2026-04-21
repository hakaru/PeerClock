import SwiftUI

struct BeatIndicator: View {
    let beatsPerBar: Int
    let currentBeat: Int
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 16) {
            ForEach(0..<beatsPerBar, id: \.self) { beat in
                Circle()
                    .fill(fillColor(for: beat))
                    .frame(width: 20, height: 20)
            }
        }
    }

    private func fillColor(for beat: Int) -> Color {
        guard isPlaying else { return .gray.opacity(0.3) }
        if beat == currentBeat {
            return beat == 0 ? .cyan : .white
        }
        return .gray.opacity(0.3)
    }
}
