import Foundation

/// A second copy of the app's `AutomationToken`, kept honest by shared vectors.
///
/// A UI test runs in its own process and cannot import the app, so the only way
/// to address a row by identity is to derive the same token independently.
/// `AutomationTokenVectors` is asserted against the real implementation in
/// `FinanceAppTests/DeviceAccessibilityHygieneTests` and against this copy in
/// `AutomationTokenMirrorTests`, so a change to either side fails one of the
/// two suites rather than quietly drifting.
enum AutomationTokenMirror {
    static func opaque(_ identity: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    static func decision(_ id: String) -> String { "activity.decision." + opaque(id) }
    static func payment(_ id: String) -> String { "activity.payment." + opaque(id) }
    static func pending(_ id: String) -> String { "activity.pending." + opaque(id) }
    static func limitation(_ id: String) -> String { "activity.limitation." + opaque(id) }
    static func transaction(_ id: String) -> String { "activity.transaction." + opaque(id) }

    static let rowPrefixes = [
        "activity.decision.", "activity.payment.", "activity.pending.",
        "activity.limitation.", "activity.transaction.",
    ]
}

/// The contract both copies of the token must satisfy, character for
/// character. Do not regenerate these from either implementation: they are the
/// thing that catches an implementation changing.
enum AutomationTokenVectors {
    static let cases: [(identity: String, token: String)] = [
        ("", "cbf29ce484222325"),
        ("a", "af63dc4c8601ec8c"),
        ("obs-streaming", "9ac03f209deb1760"),
        ("obs-paypal-unresolved", "01a3eb4e5c2bef45"),
        ("pending-snapshot", "63eb36fd26467a43"),
        ("pending-third", "ec863c759cf2b224"),
        ("live:tx-1", "0800a431d0655ce9"),
        ("archive:arc-1", "7f054a8284db4711"),
    ]
}
