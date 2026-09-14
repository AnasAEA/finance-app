import Foundation
import SwiftUI

/// A civil calendar date: the thing a person points at on a date picker.
///
/// It carries no instant, no offset and no time zone, because the date someone
/// selected does not have any. A `Date` does — it is a point on the timeline —
/// and turning one into a day requires saying *whose* calendar day is meant.
/// Getting that wrong is not a rounding error: interpreting a locally selected
/// 16 September in UTC stores 15 September, and at a month boundary it stores
/// the wrong month.
///
/// So the app boundary speaks `CalendarDay`, converts once, in the person's own
/// zone, and hands FinanceCore a date that already means what they picked.
///
/// Integer components are not themselves validated: an invalid picker or
/// mapping value must fail at the Day/Foundation boundary rather than trap
/// here. Description stays total for any components.
struct CalendarDay: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The civil date `date` falls on in `timeZone`.
    ///
    /// `timeZone` defaults to the device's, which is the only correct reading
    /// of a value a `DatePicker` produced on that device.
    ///
    /// The bridge is CE-only. A Foundation value whose era is not Gregorian AD,
    /// or whose year/month/day cannot be extracted, fails rather than being
    /// rewritten as a positive CE date.
    init?(_ date: Date, in timeZone: TimeZone = .current) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let parts = Self.calendar(in: timeZone).dateComponents(
            [.era, .year, .month, .day],
            from: date
        )
        guard let era = parts.era, let year = parts.year,
              let month = parts.month, let day = parts.day,
              era == 1
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// An instant that reads back as this same civil date in `timeZone`.
    ///
    /// Anchored at midday rather than midnight: a spring-forward transition can
    /// delete local midnight altogether, and a formatter reading a midnight
    /// anchor under a slightly different zone can print the day before.
    ///
    /// Nil when Foundation cannot represent this civil day, or would normalize
    /// it to a different one. Never substitutes epoch, today, or another date.
    func date(in timeZone: TimeZone = .current) -> Date? {
        guard year > 0 else { return nil }
        let calendar = Self.calendar(in: timeZone)
        var components = DateComponents()
        components.era = 1
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        components.minute = 0
        components.second = 0
        guard let candidate = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.era, .year, .month, .day], from: candidate)
        guard back.era == 1, back.year == year, back.month == month, back.day == day else {
            return nil
        }
        return candidate
    }

    /// Gregorian and POSIX, so the arithmetic never depends on the device's
    /// preferred calendar — only on its zone, which is the part that matters.
    static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }

    static func < (a: CalendarDay, b: CalendarDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// Structural civil text. Ordinary 0000...9999 dates stay `YYYY-MM-DD`.
    /// Invalid components still print rather than trap.
    var description: String { Self.formatCivil(year: year, month: month, day: day) }

    /// Foundation formatting when the civil day has an instant; otherwise the
    /// structural civil text. Ordinary dates keep their previous output.
    func formatted(_ style: Date.FormatStyle, timeZone: TimeZone = .current) -> String {
        if let date = date(in: timeZone) {
            var style = style
            style.timeZone = timeZone
            return date.formatted(style)
        }
        return description
    }

    func formatted(
        date dateStyle: Date.FormatStyle.DateStyle,
        time timeStyle: Date.FormatStyle.TimeStyle,
        timeZone: TimeZone = .current
    ) -> String {
        if let date = date(in: timeZone) {
            return date.formatted(date: dateStyle, time: timeStyle)
        }
        return description
    }

    private static func formatCivil(year: Int, month: Int, day: Int) -> String {
        formatYear(year) + "-" + formatPart(month) + "-" + formatPart(day)
    }

    private static func formatYear(_ value: Int) -> String {
        if (0...9999).contains(value) { return pad(value, width: 4) }
        var digits = String(value.magnitude)
        while digits.count < 4 { digits = "0" + digits }
        return (value < 0 ? "-" : "+") + digits
    }

    private static func formatPart(_ value: Int) -> String {
        if (0...99).contains(value) { return pad(value, width: 2) }
        return String(value)
    }

    private static func pad(_ value: Int, width: Int) -> String {
        var out = String(value)
        while out.count < width { out = "0" + out }
        return out
    }
}

/// DatePicker is available only when its instant representation is truthful.
/// The civil value remains visible and unchanged when it cannot be picked.
struct CivilDatePicker: View {
    let title: String
    @Binding var selection: CalendarDay?
    var range: ClosedRange<Date>? = nil
    @State private var invalidSelection = false

    init(_ title: String, selection: Binding<CalendarDay?>, in range: ClosedRange<Date>? = nil) {
        self.title = title
        self._selection = selection
        self.range = range
    }

    init(_ title: String, selection: Binding<CalendarDay>, in range: ClosedRange<Date>? = nil) {
        self.title = title
        self._selection = Binding(get: { selection.wrappedValue }, set: {
            if let value = $0 { selection.wrappedValue = value }
        })
        self.range = range
    }

    var body: some View {
        if let civil = selection, let instant = civil.date() {
            let binding = Binding<Date>(get: { instant }, set: { value in
                guard let day = CalendarDay(value) else { invalidSelection = true; return }
                invalidSelection = false
                selection = day
            })
            if let range {
                DatePicker(title, selection: binding, in: range, displayedComponents: .date)
            } else {
                DatePicker(title, selection: binding, displayedComponents: .date)
            }
            if invalidSelection { Text("Choose a real calendar date.") }
        } else {
            LabeledContent(title, value: selection?.description ?? "Date unavailable")
        }
    }
}
