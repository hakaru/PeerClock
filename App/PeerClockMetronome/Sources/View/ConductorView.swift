import SwiftUI

struct ConductorView: View {
    let beatsPerBar: Int
    let currentBeat: Int
    let progress: Double
    let isPlaying: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let conductorPath = ConductorPathProvider.path(for: beatsPerBar, in: size)
            let points = ConductorPathProvider.points(for: beatsPerBar, in: size)
            let pos = ConductorPathProvider.interpolatePosition(
                progress: progress, size: size, beatsPerBar: beatsPerBar
            )

            ZStack {
                conductorPath
                    .stroke(Color.cyan.opacity(0.15), lineWidth: 2)

                ForEach(0..<points.count, id: \.self) { i in
                    let pt = points[i].position
                    let isActive = isPlaying && currentBeat == i
                    Circle()
                        .fill(isActive ? Color.cyan : Color.cyan.opacity(0.4))
                        .frame(width: isActive ? 18 : 10, height: isActive ? 18 : 10)
                        .shadow(color: isActive ? .cyan : .clear, radius: isActive ? 14 : 0)
                        .position(pt)
                    Text("\(i + 1)")
                        .font(.caption2.bold())
                        .foregroundStyle(isActive ? .white : .gray)
                        .position(x: pt.x, y: pt.y + (i == 0 ? 16 : -16))
                }

                if isPlaying {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .cyan, radius: 8)
                        .shadow(color: .cyan, radius: 16)
                        .position(pos)
                }
            }
        }
    }
}
