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
    /// An explicit tint, for a figure whose meaning is not its sign — "short
    /// by 256,00 €" is a bad number written as a positive one. Wins over
    /// `colorBySign`; nil leaves both off.
    var tint: Color?

    @ScaledMetric(relativeTo: .largeTitle) private var scale: CGFloat = 1

    var body: some View {
        Text(amount.formatted(showsSign: showsSign))
            .font(.money(size * scale, weight: weight))
            .monospacedDigit()
            .foregroundStyle(resolvedTint)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .accessibilityLabel(amount.accessibleDescription())
    }

    private var resolvedTint: Color {
        if let tint { return tint }
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
    /// See `MoneyText.tint`.
    var valueTint: Color?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.sm))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Space.md))
        layout {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(emphasis ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(.primary)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: Theme.Space.md) }
            MoneyText(amount: value, size: emphasis ? 19 : 17,
                      weight: emphasis ? .semibold : .regular,
                      colorBySign: colorBySign, tint: valueTint)
        }
        .accessibilityElement(children: .combine)
    }
}
