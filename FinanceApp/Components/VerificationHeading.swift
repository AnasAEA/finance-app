import SwiftUI

/// A completed check is a distinct visual state, not a differently tinted warning.
/// The state is always supplied by the existing checkpoint presentation.
struct VerificationHeading: View {
    let state: CheckpointVerificationState
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var symbol: String {
        switch state {
        case .verified: "checkmark"
        case .changedSinceVerification: "arrow.triangle.2.circlepath"
        case .notVerified: "circle.dotted"
        case .unavailable: "questionmark"
        }
    }

    var body: some View {
        let tone = FinanceTone.verification(state)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.md))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Theme.Space.md))
        layout {
            Image(systemName: symbol)
                .font(.title2.weight(.medium))
                .foregroundStyle(state == .verified ? Theme.Surface.onFinancialHeader : tone.color)
                .frame(width: 52, height: 52)
                .background(state == .verified ? Theme.Surface.financialHeader : .clear, in: Circle())
                .overlay { Circle().strokeBorder(tone.color.opacity(state == .verified ? 0 : 0.35)) }
                .contentTransition(.opacity)
                .accessibilityHidden(true)
            Text(title).font(Theme.TypeStyle.editorial)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: state)
        .accessibilityElement(children: .combine)
    }
}
