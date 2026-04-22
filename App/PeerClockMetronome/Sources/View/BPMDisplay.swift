import SwiftUI

struct BPMDisplay: View {
    let bpm: Int
    let onAdjust: (Int) -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 2) {
            Text("\(bpm)")
                .font(.system(size: 96, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .scaleEffect(isDragging ? 1.05 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isDragging)
            Text("BPM")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .tracking(4)
                .foregroundStyle(.white.opacity(0.4))
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    isDragging = true
                    let delta = Int(-value.translation.height / 10) - Int(-dragOffset / 10)
                    if delta != 0 { onAdjust(delta) }
                    dragOffset = value.translation.height
                }
                .onEnded { _ in
                    isDragging = false
                    dragOffset = 0
                }
        )
        .onTapGesture(count: 2) {
            onAdjust(120 - bpm)
        }
    }
}
