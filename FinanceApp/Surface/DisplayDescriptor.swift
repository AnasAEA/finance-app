import Foundation

/// Guards the boundary between analysis vocabulary and words on a screen.
///
/// The imported document preserves forensic descriptors verbatim, which is
/// right: the reconstruction says exactly what the evidence supported, and one
/// financing plan's evidence supported nothing about the purchase at all. The
/// descriptor recorded for it is
/// `UNKNOWN — not present in available primary descriptors`.
///
/// That sentence is true, and it is a statement about the *evidence*. As the
/// title of a row it reads as though the app were reporting an internal fault
/// to the person whose money it is. Presentation replaces it with something
/// calm and equally true, derived only from what is already known — never from
/// a fact invented to fill the gap.
enum DisplayDescriptor {
    /// Screaming diagnostic tokens, matched only in their screaming form. A
    /// person who writes "Unknown charge" on their own row means it and keeps
    /// it; `UNKNOWN — …` is machine vocabulary and does not survive.
    static let diagnosticTokens: Set<String> = [
        "UNKNOWN", "UNRESOLVED", "UNAVAILABLE", "NOT_COMPUTABLE", "NO_DATA",
        "N/A", "TBD", "TODO", "NULL", "NONE", "NIL",
    ]

    /// True when `text` is empty or opens with a diagnostic token.
    static func isDiagnostic(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let first = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? trimmed
        let token = first.trimmingCharacters(in: CharacterSet(charactersIn: ":,.;—–-"))
        return diagnosticTokens.contains(token)
    }

    /// `raw` when a person could have written it, otherwise `fallback()`.
    static func humane(_ raw: String, fallback: () -> String) -> String {
        isDiagnostic(raw) ? fallback() : raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An instalment plan's title.
    ///
    /// The provider is a known fact and is already printed beside the title, so
    /// naming it claims nothing new; that the row is an instalment is what the
    /// plan *is*. Neither invents a merchant nor an amount.
    static func instalmentTitle(purchaseDescription: String, provider: String) -> String {
        humane(purchaseDescription) {
            let provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
            return provider.isEmpty || isDiagnostic(provider)
                ? "Instalment"
                : "\(provider) instalment"
        }
    }
}
