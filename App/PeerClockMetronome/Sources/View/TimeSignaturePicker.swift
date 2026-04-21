import SwiftUI

struct TimeSignaturePicker: View {
    let selection: TimeSignature
    let onSelect: (TimeSignature) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(TimeSignature.allCases, id: \.rawValue) { ts in
                    Button {
                        onSelect(ts)
                    } label: {
                        Text(ts.displayName)
                            .font(.title3.bold())
                            .foregroundStyle(ts == selection ? .white : .gray)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(ts == selection ? Color.cyan.opacity(0.3) : Color.clear)
                            )
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}
