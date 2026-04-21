import SwiftUI

struct SparklineView: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2 else { return }

            let msValues = values.map { $0 * 1000 }
            let maxAbs = max(msValues.map { abs($0) }.max() ?? 1, 0.1)

            let midY = size.height / 2
            let stepX = size.width / CGFloat(values.count - 1)

            // Zero line
            let zeroLine = Path { path in
                path.move(to: CGPoint(x: 0, y: midY))
                path.addLine(to: CGPoint(x: size.width, y: midY))
            }
            context.stroke(zeroLine, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)

            // Sparkline
            var path = Path()
            for (i, value) in msValues.enumerated() {
                let x = CGFloat(i) * stepX
                let y = midY - (value / maxAbs) * midY * 0.8
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(.cyan), lineWidth: 1.5)
        }
    }
}
