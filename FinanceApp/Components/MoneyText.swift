import SwiftUI

/// A monetary figure, sized for reading at a glance.
///
/// Scales with Dynamic Type through `@ScaledMetric`, and reads its value to
/// VoiceOver as one amount rather than as loose digits.
struct MoneyText: View {
    let amount: Amount
    var size: CGFloat = 34
    var weight: Font.Weight = .semibold
    var showsSign = false
    /// Tints the figure by direction. Off by default: most numbers on the
    /// screen are neither good nor bad.
    var colorBySign = false

    @ScaledMetric(relativeTo: .largeTitle) private var scale: CGFloat = 1

    var body: some View {
        Text(amount.formatted(showsSign: showsSign))
            .font(.money(size * scale, weight: weight))
            .monospacedDigit()
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityLabel(amount.accessibleDescription())
    }

    private var tint: Color {
        guard colorBySign else { return .primary }
        if amount.isNegative { return Theme.Role.negative }
        if amount.isPositive { return Theme.Role.positive }
        return .secondary
    }
}

/// The small uppercase caption that sits above a figure.
struct Eyebrow: View {
    let text: String
    var tint: Color = .secondary

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text.uppercased())
            .font(.eyebrow)
            .kerning(0.6)
            .foregroundStyle(tint)
            .accessibilityLabel(text)
    }
}

/// A compact pill for a status, a certainty level or an account name.
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2)
            }
            Text(text).font(.caption).fontWeight(.medium)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// A labelled row of the form `label ............ value`.
struct LedgerRow: View {
    let label: String
    let value: Amount
    var caption: String?
    var emphasis: Bool = false
    var colorBySign = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(emphasis ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(.primary)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            MoneyText(amount: value, size: emphasis ? 19 : 17,
                      weight: emphasis ? .semibold : .regular,
                      colorBySign: colorBySign)
        }
        .accessibilityElement(children: .combine)
    }
}
