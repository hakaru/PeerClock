import SwiftUI

struct TimeSignaturePicker: View {
    let selection: TimeSignature
    let onSelect: (TimeSignature) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
            ForEach(TimeSignature.allCases, id: \.rawValue) { ts in
                Button {
                    onSelect(ts)
                } label: {
                    Text(ts.displayName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(ts == selection ? .white : .white.opacity(0.35))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            if ts == selection {
                                Capsule()
                                    .fill(Color.cyan.opacity(0.35))
                                    .overlay(
                                        Capsule().strokeBorder(Color.cyan.opacity(0.6), lineWidth: 1)
                                    )
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        }
    }
}
