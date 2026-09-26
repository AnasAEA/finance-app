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
