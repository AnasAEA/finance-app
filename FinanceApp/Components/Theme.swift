import SwiftUI

/// The visual vocabulary, in one place.
///
/// Every colour here resolves to a system semantic colour, so light and dark
/// mode, increased contrast and the accessibility tints all work without a
/// single hard-coded hex value.
enum Theme {

    // MARK: - Colour roles

    enum Role {
        /// Money arriving, a budget in hand, a solvent projection.
        static let positive = Color.green
        /// A shortfall, an overspend, a negative projection.
        static let negative = Color.red
        /// Approaching a limit; a date worth watching.
        static let caution = Color.orange
        /// The app's own tint.
        static let accent = Color.accentColor
        /// Something deliberately outside everyday life — debt recovery.
        static let recovery = Color.indigo
    }

    // MARK: - Surfaces

    enum Surface {
        static let background = Color(.systemGroupedBackground)
        static let card = Color(.secondarySystemGroupedBackground)
        static let inset = Color(.tertiarySystemGroupedBackground)
        static let separator = Color(.separator)
    }

    // MARK: - Metrics

    enum Metric {
        static let cardRadius: CGFloat = 20
        static let controlRadius: CGFloat = 12
        static let cardPadding: CGFloat = 18
        static let screenPadding: CGFloat = 18
        static let stackSpacing: CGFloat = 16
        static let tightSpacing: CGFloat = 6
        /// Extra scroll-content margin so the last List row can pass the iOS 26
        /// floating tab bar. The bar overlays the home-indicator inset; this is
        /// only that leftover overlap, not a second chrome row.
        static let floatingTabBarClearance: CGFloat = 32
    }

    enum Layout {
        /// At accessibility sizes a trailing Plan figure moves under the title
        /// so a money value is never hyphenated mid-number.
        static func planHubStacksValueBelowTitle(_ size: DynamicTypeSize) -> Bool {
            size.isAccessibilitySize
        }

        /// At accessibility sizes the Insights period title moves above its
        /// two navigation buttons instead of being squeezed between them,
        /// which otherwise wraps a short date range over four lines.
        static func insightsStacksPeriodControls(_ size: DynamicTypeSize) -> Bool {
            size.isAccessibilitySize
        }
    }
}

extension Font {
    /// Financial figures are set in rounded digits, the way a wallet sets them.
    /// Sizes are relative to a text style so Dynamic Type still scales them.
    static func money(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// The small all-caps label above a figure.
    static var eyebrow: Font {
        .system(.caption, design: .default, weight: .semibold)
    }
}

extension View {
    /// A subtle card. No shadow stack, no gradient — just a raised surface.
    func financeCard(padding: CGFloat = Theme.Metric.cardPadding) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Surface.card, in: RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous))
    }
}
