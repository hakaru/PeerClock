import SwiftUI

struct ConductorView: View {
    let beatsPerBar: Int
    let currentBeat: Int
    let isPlaying: Bool
    let progressProvider: @Sendable () async -> Double

    @State private var progress: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
            let _ = updateProgress()
            GeometryReader { geo in
                let size = geo.size
                let pts = ConductorPathProvider.points(for: beatsPerBar, in: size)
                let pos = ConductorPathProvider.interpolatePosition(
                    progress: progress, points: pts
                )

                Canvas { context, canvasSize in
                    drawPath(context: context, points: pts)
                    drawBeatPoints(context: context, points: pts)
                    if isPlaying {
                        drawTrackingDot(context: context, at: pos)
                    }
                }
            }
        }
    }

    private func updateProgress() {
        Task {
            progress = await progressProvider()
        }
    }

    // MARK: - Canvas Drawing

    private func drawPath(context: GraphicsContext, points: [ConductorPathProvider.BeatPoint]) {
        let count = points.count
        guard count >= 2 else { return }

        var maxAbsDy: CGFloat = 1
        for i in 0..<count {
            let dy = points[(i + 1) % count].position.y - points[i].position.y
            maxAbsDy = max(maxAbsDy, abs(dy))
        }

        for i in 0..<count {
            let from = points[i]
            let to = points[(i + 1) % count]

            var seg = Path()
            seg.move(to: from.position)
            seg.addCurve(
                to: to.position,
                control1: from.controlOut ?? from.position,
                control2: to.controlIn ?? to.position
            )

            let dy = to.position.y - from.position.y
            let weight = max(0.2, min(1.0, 0.5 + (dy / maxAbsDy) * 0.5))
            let lineWidth = 1.5 + weight * 4.5
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)

            var glowCtx = context
            glowCtx.opacity = 0.03 + weight * 0.05
            glowCtx.addFilter(.blur(radius: 3 + weight * 5))
            glowCtx.stroke(seg, with: .color(.cyan), style: StrokeStyle(lineWidth: lineWidth * 3, lineCap: .round))

            context.stroke(seg, with: .color(.cyan.opacity(0.15 + weight * 0.25)), style: style)
        }
    }

    private func drawBeatPoints(context: GraphicsContext, points: [ConductorPathProvider.BeatPoint]) {
        for point in points {
            guard let beat = point.beatIndex else { continue }
            let pt = point.position
            let isActive = isPlaying && currentBeat == beat
            let isDownbeat = beat == 0

            if isActive {
                var ringCtx = context
                ringCtx.opacity = 0.5
                ringCtx.addFilter(.blur(radius: 4))
                let ringRect = CGRect(x: pt.x - 12, y: pt.y - 12, width: 24, height: 24)
                ringCtx.stroke(Circle().path(in: ringRect), with: .color(.cyan), lineWidth: 2)
            }

            let beatCount = points.compactMap(\.beatIndex).count
            let scale: CGFloat = isDownbeat ? 1.0 : CGFloat(beatCount - beat) / CGFloat(beatCount)
            let dotSize: CGFloat = isActive ? 10 : (4 + 4 * scale)
            let color: Color = isActive ? .white : .cyan.opacity(0.2 + 0.4 * scale)
            let dotRect = CGRect(x: pt.x - dotSize / 2, y: pt.y - dotSize / 2, width: dotSize, height: dotSize)
            context.fill(Circle().path(in: dotRect), with: .color(color))

            let label = Text("\(beat + 1)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(isActive ? .white : .white.opacity(0.2))
            let yOff: CGFloat = beat == 0 ? 20 : -20
            context.draw(label, at: CGPoint(x: pt.x, y: pt.y + yOff))
        }
    }

    private func drawTrackingDot(context: GraphicsContext, at pos: CGPoint) {
        // Outer glow
        var outerCtx = context
        outerCtx.opacity = 0.15
        outerCtx.addFilter(.blur(radius: 8))
        let outerRect = CGRect(x: pos.x - 16, y: pos.y - 16, width: 32, height: 32)
        outerCtx.fill(Circle().path(in: outerRect), with: .color(.cyan))

        // Mid glow
        var midCtx = context
        midCtx.opacity = 0.4
        midCtx.addFilter(.blur(radius: 4))
        let midRect = CGRect(x: pos.x - 8, y: pos.y - 8, width: 16, height: 16)
        midCtx.fill(Circle().path(in: midRect), with: .color(.cyan))

        // Core
        let coreRect = CGRect(x: pos.x - 4, y: pos.y - 4, width: 8, height: 8)
        context.fill(Circle().path(in: coreRect), with: .color(.white))
    }
}
