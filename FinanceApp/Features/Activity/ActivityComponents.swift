import SwiftUI

/// Shared reading rhythm for the timeline and the decision queue.
struct ActivityMark: View {
    let symbol: String
    var text: String? = nil
    var tint: Color = Theme.Role.accent

    var body: some View {
        Group {
            if let text {
                Text(text).font(.system(.caption2, weight: .bold))
            } else {
                Image(systemName: symbol).font(.system(.subheadline, weight: .medium))
            }
        }
        .foregroundStyle(tint)
        .frame(width: 36, height: 36)
        .background(Theme.Surface.inset, in: RoundedRectangle(cornerRadius: 11))
        .accessibilityHidden(true)
    }
}

struct ActivityStateLabel: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = Theme.Role.supporting

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            Text(title)
        }
        .font(Theme.TypeStyle.metadata.weight(.medium))
        .foregroundStyle(tint)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ActivitySectionHeading: View {
    let title: String
    var count: Int? = nil
    var detail: String? = nil
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(compact ? Theme.TypeStyle.metadata.weight(.semibold) : Theme.TypeStyle.section)
                    .foregroundStyle(compact ? Theme.Role.supporting : Color.primary)
                if let count {
                    Text(count.formatted()).font(Theme.TypeStyle.metadata.monospacedDigit())
                        .foregroundStyle(Theme.Role.supporting)
                }
                Spacer(minLength: 8)
            }
            if let detail {
                Text(detail).font(Theme.TypeStyle.metadata).foregroundStyle(Theme.Role.supporting)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textCase(nil)
        .padding(.top, compact ? Theme.Space.sm : Theme.Space.lg)
        .padding(.bottom, compact ? Theme.Space.xs : Theme.Space.sm)
        .accessibilityAddTraits(.isHeader)
    }
}
