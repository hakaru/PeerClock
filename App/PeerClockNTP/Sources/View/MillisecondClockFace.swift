import SwiftUI

struct MillisecondClockFace: View {
    let ntpOffset: TimeInterval?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0)) { context in
            let now = context.date.addingTimeInterval(ntpOffset ?? 0)
            let components = Calendar.current.dateComponents(
                [.hour, .minute, .second, .nanosecond], from: now
            )
            let ms = (components.nanosecond ?? 0) / 1_000_000

            Text(String(
                format: "%02d:%02d:%02d.%03d",
                components.hour ?? 0,
                components.minute ?? 0,
                components.second ?? 0,
                ms
            ))
            .font(.system(size: 48, weight: .light, design: .monospaced))
            .foregroundStyle(.white)
            .contentTransition(.numericText())
        }
    }
}
