import Foundation

enum ActivityTextPresentation {
    /// Statement descriptors stay verbatim in detail. All-capitals list copy
    /// gets sentence-like casing so it does not compete with the amount.
    static func readableTitle(_ title: String) -> String {
        let letters = title.unicodeScalars.filter(CharacterSet.letters.contains)
        guard letters.count >= 4, title == title.uppercased() else { return title }
        let preserved = Set(["BNP", "ATM", "SEPA", "EUR", "USD", "EU"])
        return title.split(separator: " ").map { word in
            let token = String(word)
            if preserved.contains(token) { return token }
            if token == "PAYPAL" { return "PayPal" }
            return token.localizedCapitalized
        }.joined(separator: " ")
    }

    /// A row title for a list. A card payment or card refund written as the
    /// bank's statement line ("FACTURE CARTE DU 010126 CAFE DU PORT CARTE
    /// 1234XXXXXXXX5678") is named by its merchant: the row already shows the
    /// date, and the masked card number is detail. Anything else keeps its
    /// words and only gets readable casing.
    ///
    /// Display only. Detail screens keep the descriptor verbatim, search reads
    /// the original text, and the shape of a descriptor never decides what a
    /// record is.
    static func listTitle(_ title: String) -> String {
        readableTitle(cardMerchant(in: title) ?? title)
    }

    /// The same for a ledger row, which may carry a name a person typed:
    /// only an exact card statement line is rewritten, so "SNCF" entered by
    /// hand keeps its spelling instead of becoming "Sncf".
    static func ledgerListTitle(_ title: String) -> String {
        cardMerchant(in: title).map(readableTitle) ?? title
    }

    /// The merchant inside a French card-payment or card-refund statement
    /// line, or nil unless the text is exactly that shape.
    static func cardMerchant(in title: String) -> String? {
        let line = title.trimmingCharacters(in: .whitespaces)
        guard let match = line.wholeMatch(
            of: #/(?:FACTURE|AVOIR) CARTE DU [0-9]{6} (.+?) CARTE [0-9X*]{8,}/#
        ) else { return nil }
        let merchant = match.1.trimmingCharacters(in: .whitespaces)
        return merchant.isEmpty ? nil : merchant
    }
}

struct ActivityTimelineGroup<Row: Identifiable>: Identifiable {
    let id: Row.ID
    let date: CalendarDay?
    var rows: [Row]
}

enum ActivityTimelineGrouping {
    /// Preserve the selected sort: only adjacent equal dates share a heading.
    static func adjacent<Row: Identifiable>(
        _ rows: [Row], date: (Row) -> CalendarDay?
    ) -> [ActivityTimelineGroup<Row>] {
        var groups: [ActivityTimelineGroup<Row>] = []
        for row in rows {
            let day = date(row)
            if let last = groups.last, last.date == day {
                groups[groups.count - 1].rows.append(row)
            } else {
                groups.append(ActivityTimelineGroup(id: row.id, date: day, rows: [row]))
            }
        }
        return groups
    }
}
