import SwiftUI

/// A small visual vocabulary: paper, ink, restrained status, and readable money.
enum Theme {
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum TypeStyle {
        static let screen = Font.system(.title2, weight: .bold)
        static let section = Font.system(.headline, weight: .semibold)
        static let card = Font.system(.headline, weight: .semibold)
        static let body = Font.body
        static let supporting = Font.subheadline
        static let metadata = Font.caption
        static let action = Font.system(.subheadline, weight: .semibold)
        static let numeric = Font.system(.title3, design: .rounded, weight: .semibold).monospacedDigit()
        static let heroSize: CGFloat = 56
        static let editorial = Font.system(.title2, design: .serif, weight: .semibold)
    }

    enum Role {
        /// Every secondary line in the app: captions, labels, dates, accounts,
        /// states, section footers and quiet indicators. System secondary text
        /// blends to about 3.3:1 on the paper background; this stays at 6.2:1
        /// or more on page, card and inset surfaces in both appearances and
        /// darkens further under Increase Contrast. It is still visibly
        /// quieter than primary text, so hierarchy survives.
        static let supporting = adaptive(0x4B5953, dark: 0xB9CBC2, contrast: 0x34433B)
        static let positive = adaptive(0x216650, dark: 0x8ACCB2, contrast: 0x124735)
        static let negative = adaptive(0xAD343B, dark: 0xFFABA9, contrast: 0x8A1623)
        static let caution = adaptive(0x895414, dark: 0xEBC182, contrast: 0x673A04)
        static let accent = adaptive(0x245C4D, dark: 0x9CD3BE, contrast: 0x123D30)
        static let information = adaptive(0x365F87, dark: 0xA6C9EC, contrast: 0x1B4369)
        static let recovery = adaptive(0x675689, dark: 0xCBB8EE, contrast: 0x49376C)
    }

    enum Surface {
        // A constant ink field keeps white text and native dark navigation chrome consistent.
        static let financialHeader = adaptive(0x183C30, dark: 0x183C30)
        static let onFinancialHeader = Color.white
        static let supportingOnHeader = Color.white.opacity(0.78)
        static let background = adaptive(0xF6F5F0, dark: 0x131B19)
        static let card = adaptive(0xFFFFFF, dark: 0x202B27)
        static let inset = adaptive(0xEAEDE6, dark: 0x2B3731)
        static let separator = Color(.separator)
    }

    enum Metric {
        static let cardRadius: CGFloat = 20
        static let controlRadius: CGFloat = 12
        static let cardPadding = Space.lg
        static let screenPadding = Space.xl
        static let stackSpacing = Space.xl
        static let tightSpacing = Space.xs
        static let floatingTabBarClearance: CGFloat = 40
        static let minimumTarget: CGFloat = 44
        static let statusIcon: CGFloat = 20
    }

    enum Layout {
        static func planHubStacksValueBelowTitle(_ size: DynamicTypeSize) -> Bool { size.isAccessibilitySize }
        static func insightsStacksPeriodControls(_ size: DynamicTypeSize) -> Bool { size.isAccessibilitySize }
    }

    /// High-contrast colors are darker in light mode; dark colors are already
    /// light enough to remain legible. No status depends on its tint alone.
    private static func adaptive(_ light: UInt32, dark: UInt32, contrast: UInt32? = nil) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark
                : (traits.accessibilityContrast == .high ? contrast ?? light : light)
            return UIColor(red: Double((rgb >> 16) & 255) / 255,
                           green: Double((rgb >> 8) & 255) / 255,
                           blue: Double(rgb & 255) / 255, alpha: 1)
        })
    }
}

extension Font {
    static func money(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static var eyebrow: Font { .system(.caption, weight: .semibold) }
}

extension View {
    func financeCard(padding: CGFloat = Theme.Metric.cardPadding) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Surface.card, in: RoundedRectangle(cornerRadius: Theme.Metric.cardRadius))
    }

    /// Native lists remain appropriate for settings, editors and long queues.
    func financeList() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Theme.Surface.background)
            .contentMargins(.bottom, Theme.Metric.floatingTabBarClearance, for: .scrollContent)
    }
}

/// Reading surfaces use a document rhythm, without a box around every fact.
struct FinancePage<Content: View>: View {
    var spacing: CGFloat = Theme.Space.xl
    var topInset: CGFloat = Theme.Space.lg
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Metric.screenPadding)
                .padding(.top, topInset)
                .padding(.bottom, Theme.Metric.floatingTabBarClearance)
        }
        .background(Theme.Surface.background)
        .labeledContentStyle(FinanceLabeledStyle())
    }
}

/// A section in a reading surface. Editors continue using native Section.
struct FinanceSection<Content: View, Header: View, Footer: View>: View {
    let content: Content
    let header: Header
    let footer: Footer

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header,
         @ViewBuilder footer: () -> Footer) {
        self.content = content(); self.header = header(); self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            header.font(Theme.TypeStyle.section).foregroundStyle(.primary)
                .textCase(nil).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Theme.Space.md) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
            footer.font(Theme.TypeStyle.metadata).foregroundStyle(Theme.Role.supporting)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
extension FinanceSection where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}
extension FinanceSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}
extension FinanceSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}
extension FinanceSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}

/// Visual tone is selected from a mapped status, never inferred from money.
enum FinanceTone {
    case calm, caution, deficit, information
    var color: Color {
        switch self {
        case .calm: Theme.Role.positive
        case .caution: Theme.Role.caution
        case .deficit: Theme.Role.negative
        case .information: Theme.Role.information
        }
    }
    var symbol: String {
        switch self {
        case .calm: "checkmark.circle"
        case .caution: "exclamationmark.triangle"
        case .deficit: "exclamationmark.circle.fill"
        case .information: "info.circle"
        }
    }
    static func verification(_ state: CheckpointVerificationState) -> Self {
        switch state {
        case .verified: .calm
        case .notVerified, .changedSinceVerification, .unavailable: .information
        }
    }
    static func plan(_ kind: PlanStatusKind) -> Self {
        switch kind {
        case .funded: .calm
        case .fundingGap: .deficit
        case .reserveWarning: .caution
        case .unavailable: .information
        }
    }
}

struct StatusSurface<Content: View>: View {
    let tone: FinanceTone
    var filled = true
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.sm))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Space.md))
        layout {
            Image(systemName: tone.symbol)
                .font(.system(size: Theme.Metric.statusIcon, weight: .semibold)).foregroundStyle(tone.color)
                .padding(.top, 2).accessibilityHidden(true)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, filled ? Theme.Space.lg : Theme.Space.sm)
        .padding(.horizontal, filled ? Theme.Space.lg : 0)
        .background(tone.color.opacity(filled ? (contrast == .increased ? 0.14 : 0.07) : 0),
                    in: RoundedRectangle(cornerRadius: Theme.Metric.controlRadius))
        .overlay(alignment: .leading) {
            if filled {
                RoundedRectangle(cornerRadius: 2).fill(tone.color).frame(width: 3)
                    .padding(.vertical, Theme.Space.md)
            }
        }
    }
}

struct FinancePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minHeight: Theme.Metric.minimumTarget)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct ActionLabel: View {
    let title: String
    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(title).font(Theme.TypeStyle.action)
            Spacer(minLength: Theme.Space.sm)
            Image(systemName: "arrow.right").font(.subheadline.weight(.semibold)).accessibilityHidden(true)
        }
        .foregroundStyle(Theme.Role.accent)
        .frame(minHeight: Theme.Metric.minimumTarget, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct FinanceLabeledStyle: LabeledContentStyle {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    func makeBody(configuration: Configuration) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Space.md))
        layout {
            configuration.label.font(Theme.TypeStyle.supporting).foregroundStyle(Theme.Role.supporting)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: Theme.Space.sm) }
            configuration.content.font(Theme.TypeStyle.supporting).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
