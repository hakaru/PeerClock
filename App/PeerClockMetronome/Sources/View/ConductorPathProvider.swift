import SwiftUI

struct ConductorPathProvider {
    struct BeatPoint {
        let position: CGPoint
        let controlIn: CGPoint?
        let controlOut: CGPoint?
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

    // 2拍子: 1(中央底) → 跳ね上がり → 2(上)
    // ループ: 2(上) → 振り下ろし → 1(底)
    private static func twoPattern(w: CGFloat, h: CGFloat) -> [BeatPoint] {
        [
            BeatPoint(
                position: p(0.50, 0.88, w, h),       // 拍1: 中央底
                controlIn: p(0.50, 0.45, w, h),      // 上から真下に振り下ろし
                controlOut: p(0.60, 0.55, w, h)       // 跳ね上がり右へ
            ),
            BeatPoint(
                position: p(0.55, 0.18, w, h),       // 拍2: 上
                controlIn: p(0.68, 0.30, w, h),      // 右カーブから上へ
                controlOut: p(0.50, 0.15, w, h)       // 上→下の振り下ろし準備
            ),
        ]
    }

    // 3拍子: 1(中央底) → 跳ね上がり → 2(右底) → 跳ね上がり → 3(上)
    // ループ: 3(上) → 振り下ろし → 1(底)
    private static func threePattern(w: CGFloat, h: CGFloat) -> [BeatPoint] {
        [
            BeatPoint(
                position: p(0.45, 0.88, w, h),       // 拍1: 中央底
                controlIn: p(0.45, 0.45, w, h),      // 上から真下に振り下ろし
                controlOut: p(0.55, 0.50, w, h)       // 跳ね上がり→右下へ
            ),
            BeatPoint(
                position: p(0.75, 0.82, w, h),       // 拍2: 右底
                controlIn: p(0.70, 0.65, w, h),      // 上から右下に着地
                controlOut: p(0.72, 0.50, w, h)       // 跳ね上がり→左上へ
            ),
            BeatPoint(
                position: p(0.45, 0.18, w, h),       // 拍3: 上
                controlIn: p(0.58, 0.22, w, h),      // 右上からカーブ
                controlOut: p(0.42, 0.15, w, h)       // 上→下の振り下ろし準備
            ),
        ]
    }

    // 4拍子: 1(中央底) → 跳ね上がり → 2(左底) → 跳ね上がり → 3(右底) → 跳ね上がり → 4(上)
    // ループ: 4(上) → 振り下ろし → 1(底)
    private static func fourPattern(w: CGFloat, h: CGFloat) -> [BeatPoint] {
        [
            BeatPoint(
                position: p(0.48, 0.88, w, h),       // 拍1: 中央底
                controlIn: p(0.48, 0.45, w, h),      // 上から真下に振り下ろし
                controlOut: p(0.38, 0.50, w, h)       // 跳ね上がり→左下へ
            ),
            BeatPoint(
                position: p(0.20, 0.82, w, h),       // 拍2: 左底
                controlIn: p(0.25, 0.62, w, h),      // 上から左下に着地
                controlOut: p(0.28, 0.48, w, h)       // 跳ね上がり→右下へ
            ),
            BeatPoint(
                position: p(0.78, 0.78, w, h),       // 拍3: 右底
                controlIn: p(0.65, 0.58, w, h),      // 中央上からクロスして右下に着地
                controlOut: p(0.75, 0.45, w, h)       // 跳ね上がり→上へ
            ),
            BeatPoint(
                position: p(0.50, 0.18, w, h),       // 拍4: 上
                controlIn: p(0.60, 0.22, w, h),      // 右上からカーブ
                controlOut: p(0.48, 0.15, w, h)       // 上→下の振り下ろし準備
            ),
        ]
    }

    static func path(for beatsPerBar: Int, in size: CGSize) -> Path {
        let pts = points(for: beatsPerBar, in: size)
        var path = Path()
        guard pts.count >= 2 else { return path }

        path.move(to: pts[0].position)
        for i in 1..<pts.count {
            addSegment(to: &path, from: pts[i - 1], to: pts[i])
        }
        addSegment(to: &path, from: pts[pts.count - 1], to: pts[0])
        return path
    }

    static func interpolatePosition(progress: Double, size: CGSize, beatsPerBar: Int) -> CGPoint {
        let pts = points(for: beatsPerBar, in: size)
        let count = pts.count
        guard count >= 2 else { return .zero }

        let clamped = max(0, min(0.999, progress))
        let segmentProgress = clamped * Double(count)
        let index = Int(floor(segmentProgress))
        let t = segmentProgress - Double(index)

        let from = pts[index % count]
        let to = pts[(index + 1) % count]
        let cp1 = from.controlOut ?? from.position
        let cp2 = to.controlIn ?? to.position
        return cubicBezier(t: t, p0: from.position, p1: cp1, p2: cp2, p3: to.position)
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
