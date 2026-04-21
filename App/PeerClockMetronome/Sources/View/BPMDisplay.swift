import SwiftUI

struct BPMDisplay: View {
    let bpm: Int
    let onAdjust: (Int) -> Void

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 4) {
            Text("\(bpm)")
                .font(.system(size: 72, weight: .thin, design: .monospaced))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text("BPM")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    let delta = Int(-value.translation.height / 10) - Int(-dragOffset / 10)
                    if delta != 0 {
                        onAdjust(delta)
                    }
                    dragOffset = value.translation.height
                }
                .onEnded { _ in
                    dragOffset = 0
                }
        )
        .onTapGesture(count: 2) {
            onAdjust(120 - bpm)
        }
    }
}
