import SwiftUI

struct ConductorPathProvider {
    struct BeatPoint {
        let position: CGPoint
        let controlIn: CGPoint?
        let controlOut: CGPoint?
        let beatIndex: Int?

        init(position: CGPoint, controlIn: CGPoint?, controlOut: CGPoint?, beatIndex: Int? = nil) {
            self.position = position
            self.controlIn = controlIn
            self.controlOut = controlOut
            self.beatIndex = beatIndex
        }
    }

    static func points(for beatsPerBar: Int, in size: CGSize) -> [BeatPoint] {
        let w = size.width
        let h = size.height
        switch beatsPerBar {
        case 2: return twoPattern(w: w, h: h)
        case 3: return threePattern(w: w, h: h)
        default: return fourPattern(w: w, h: h)
        }
    }

    private static func twoPattern(w: CGFloat, h: CGFloat) -> [BeatPoint] {
        [
            BeatPoint(
                position: p(0.50, 0.88, w, h),
                controlIn: p(0.50, 0.45, w, h),
                controlOut: p(0.60, 0.55, w, h),
                beatIndex: 0
            ),
            BeatPoint(
                position: p(0.55, 0.18, w, h),
                controlIn: p(0.68, 0.30, w, h),
                controlOut: p(0.50, 0.15, w, h),
                beatIndex: 1
            ),
        ]
    }

    private static func threePattern(w: CGFloat, h: CGFloat) -> [BeatPoint] {
        [
            BeatPoint(
                position: p(0.45, 0.88, w, h),
                controlIn: p(0.45, 0.45, w, h),
                controlOut: p(0.55, 0.50, w, h),
                beatIndex: 0
            ),
            BeatPoint(
                position: p(0.75, 0.82, w, h),
                controlIn: p(0.70, 0.65, w, h),
                controlOut: p(0.72, 0.50, w, h),
                beatIndex: 1
            ),
            BeatPoint(
                position: p(0.45, 0.18, w, h),
                controlIn: p(0.58, 0.22, w, h),
                controlOut: p(0.42, 0.15, w, h),
                beatIndex: 2
            ),
        ]
    }

    // 4拍子: 1→上→左下→2→左端ループ→底→右→下から3→内側→4→振り下ろし→1
    private static func fourPattern(w: CGFloat, h: CGFloat) -> [BeatPoint] {
        [
            BeatPoint(
                position: p(0.48, 0.92, w, h),       // 拍1: 最下部
                controlIn: p(0.48, 0.50, w, h),
                controlOut: p(0.35, 0.38, w, h),
                beatIndex: 0
            ),
            BeatPoint(
                position: p(0.30, 0.82, w, h),       // 拍2: 少し上
                controlIn: p(0.38, 0.58, w, h),
                controlOut: p(0.22, 0.95, w, h),
                beatIndex: 1
            ),
            BeatPoint(
                position: p(0.48, 0.88, w, h),       // 中間: 左ループ後の底
                controlIn: p(-0.05, 0.50, w, h),
                controlOut: p(0.65, 0.92, w, h),
                beatIndex: nil
            ),
            BeatPoint(
                position: p(0.78, 0.72, w, h),       // 拍3: 右（少し上）
                controlIn: p(0.72, 0.85, w, h),
                controlOut: p(0.78, 0.90, w, h),      // 真下へ垂れる（3より右に行かない）
                beatIndex: 2
            ),
            BeatPoint(
                position: p(0.50, 0.18, w, h),       // 拍4: 上
                controlIn: p(0.50, 0.60, w, h),      // 真下から上がる（4より左に行かない）
                controlOut: p(0.48, 0.15, w, h),
                beatIndex: 3
            ),
        ]
    }

    static func buildPath(from pts: [BeatPoint]) -> Path {
        var path = Path()
        guard pts.count >= 2 else { return path }

        path.move(to: pts[0].position)
        for i in 1..<pts.count {
            addSegment(to: &path, from: pts[i - 1], to: pts[i])
        }
        addSegment(to: &path, from: pts[pts.count - 1], to: pts[0])
        return path
    }

    static func interpolatePosition(progress: Double, points pts: [BeatPoint]) -> CGPoint {
        let count = pts.count
        guard count >= 2 else { return .zero }

        let clamped = max(0, min(0.999, progress))
        let segmentProgress = clamped * Double(count)
        let index = Int(floor(segmentProgress))
        let t = segmentProgress - Double(index)

        let eased = t * t * (3.0 - 2.0 * t)
        let from = pts[index % count]
        let to = pts[(index + 1) % count]
        let cp1 = from.controlOut ?? from.position
        let cp2 = to.controlIn ?? to.position
        return cubicBezier(t: eased, p0: from.position, p1: cp1, p2: cp2, p3: to.position)
    }

    private static func addSegment(to path: inout Path, from start: BeatPoint, to end: BeatPoint) {
        path.addCurve(
            to: end.position,
            control1: start.controlOut ?? start.position,
            control2: end.controlIn ?? end.position
        )
    }

    private static func cubicBezier(t: Double, p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint) -> CGPoint {
        let t1 = 1.0 - t
        let x = t1 * t1 * t1 * p0.x + 3 * t1 * t1 * t * p1.x + 3 * t1 * t * t * p2.x + t * t * t * p3.x
        let y = t1 * t1 * t1 * p0.y + 3 * t1 * t1 * t * p1.y + 3 * t1 * t * t * p2.y + t * t * t * p3.y
        return CGPoint(x: x, y: y)
    }

    private static func p(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPoint {
        CGPoint(x: w * x, y: h * y)
    }
}
