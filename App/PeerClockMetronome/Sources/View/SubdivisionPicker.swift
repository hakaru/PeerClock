import SwiftUI

struct SubdivisionPicker: View {
    let selection: Subdivision
    let onSelect: (Subdivision) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Subdivision.allCases, id: \.rawValue) { sub in
                Button {
                    onSelect(sub)
                } label: {
                    Text(label(for: sub))
                        .font(.title3)
                        .frame(width: 50, height: 40)
                        .background(
                            selection == sub ? Color.cyan.opacity(0.3) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .foregroundStyle(selection == sub ? .cyan : .gray)
                }
            }
        }
    }

    private func label(for sub: Subdivision) -> String {
        switch sub {
        case .none: "♩"
        case .half: "♪♪"
        case .triplet: "♪³"
        case .quarter: "♬"
        }
    }
}
