import Foundation

/// Row identity for UI automation, derived rather than borrowed.
///
/// An accessibility identifier is read by tools, printed into trees, pasted
/// into reports and kept in logs. When a row carries none, the platform
/// synthesises one from what the row *says* — so an untagged transaction row
/// was addressable only as
/// `"<merchant>, <category> · <account> (masked ####), <date>, <amount>"`.
/// Tagging the row with its own domain identifier fixes the wording but not
/// the leak: the evidence ids underneath are backend observation handles and
/// provider account references.
///
/// So the identity a row exposes is a token derived from its domain id and
/// nothing else. It is stable — the same row keeps the same token across a
/// relaunch, a resort and a resync — and it discloses neither what was bought,
/// nor from whom, nor for how much, nor which account it touched.
///
/// FNV-1a over UTF-8, 64 bits, lowercase hex. Chosen because it is short,
/// deterministic, and reproducible in eight lines by a UI test that cannot
/// import the app. `AutomationTokenTests` pins the vectors both copies must
/// agree on.
enum AutomationToken {
    static func opaque(_ identity: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

/// Activity's addressable rows.
///
/// The four review roles are separate identifier spaces because they are
/// separate kinds of thing: a decision is work, a payment to confirm is work
/// of a different shape, a pending row is inert evidence, and a limitation is
/// something the model cannot resolve at all. An automation that means to tap
/// a decision should not be able to reach a limitation by accident.
enum ActivityID {
    static let decisionPrefix = "activity.decision."
    static let paymentPrefix = "activity.payment."
    static let pendingPrefix = "activity.pending."
    static let limitationPrefix = "activity.limitation."
    static let transactionPrefix = "activity.transaction."

    static func decision(_ id: String) -> String { decisionPrefix + AutomationToken.opaque(id) }
    static func payment(_ id: String) -> String { paymentPrefix + AutomationToken.opaque(id) }
    static func pending(_ id: String) -> String { pendingPrefix + AutomationToken.opaque(id) }
    static func limitation(_ id: String) -> String { limitationPrefix + AutomationToken.opaque(id) }
    static func transaction(_ id: String) -> String {
        transactionPrefix + AutomationToken.opaque(id)
    }

    /// The Pending section's header. Deliberately outside the row namespace:
    /// `activity.pending.section` sat under the `activity.pending.` prefix and
    /// would answer a search for a pending row.
    static let pendingSection = "activity.pending-section"

    /// Every prefix a row identity may legitimately begin with. The privacy
    /// regression test walks these.
    static let rowPrefixes = [
        decisionPrefix, paymentPrefix, pendingPrefix, limitationPrefix, transactionPrefix,
    ]
}

/// Funding Needed's semantic regions.
///
/// Roles, never contents: `funding.due` is *where the amount due is stated*,
/// and stays that whatever the amount, the day or the account happen to be.
enum FundingID {
    static let trigger = "funding.trigger"
    static let date = "funding.date"
    static let due = "funding.due"
    static let covered = "funding.covered"
    static let stillNeeded = "funding.still-needed"
    static let paymentAccount = "funding.payment-account"
    static let explanation = "funding.explanation"

    static let all = [trigger, date, due, covered, stillNeeded, paymentAccount, explanation]
}

/// Insights controls that a physical navigation has to address by name.
enum InsightsID {
    static let scopeWeek = "insights.scope.week"
    static let scopeMonth = "insights.scope.month"

    static func scope(_ scope: ReviewPeriodScope) -> String {
        switch scope {
        case .week: scopeWeek
        case .month: scopeMonth
        }
    }

    static let showDetails = "insights.show-details"
    static let verification = "insights.verification"
    static let unresolved = "insights.unresolved"

    /// The explicit acknowledgment action on the ended-month verification
    /// detail. It names the confirmation, not a close: this build has no close.
    static let acknowledge = "insights.acknowledge"
    /// Where the ended month stands after the decisions made so far.
    static let acknowledgmentState = "insights.acknowledgment-state"

    /// The explicit checkpoint write action on the ended-month verification
    /// detail. It names the durability moment: accepting a limitation is still
    /// a separate, earlier statement that stores nothing.
    static let verify = "insights.verify"
}
