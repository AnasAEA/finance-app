import Testing
import Foundation
import FinanceCore
@testable import FinanceApp

/// The day a person points at is the day that gets stored.
///
/// The bug this locks down was not a display quirk. A `DatePicker` hands back
/// local midnight; reading that instant in UTC lands on the previous day in
/// every zone east of Greenwich, and at the end of a month it lands in the
/// previous *month*. A September rent recorded into August is not a rounding
/// error, so the round trip is asserted for every day of a year, in four zones.
@Suite("A picked date is the date that is stored")
struct CivilDateTests {

    static let zones: [TimeZone] = [
        TimeZone(identifier: "Europe/Paris")!,
        TimeZone(identifier: "Africa/Casablanca")!,
        TimeZone(identifier: "UTC")!,
        TimeZone(identifier: "America/New_York")!
    ]

    /// What a `DatePicker` on a device in `zone` hands back for a civil date:
    /// the start of that day, locally.
    static func pickerValue(_ day: CalendarDay, in zone: TimeZone) throws -> Date {
        CalendarDay.calendar(in: zone).startOfDay(for: try #require(day.date(in: zone)))
    }

    static func everyDayOf(_ year: Int) -> [CalendarDay] {
        (1...12).flatMap { month in
            (1...Day.daysInMonth(year: year, month: month)).map {
                CalendarDay(year: year, month: month, day: $0)
            }
        }
    }

    @Test("Sep 16 stays Sep 16, in every zone")
    func theSeptemberSixteenthCase() throws {
        let picked = CalendarDay(year: 2026, month: 9, day: 16)
        for zone in Self.zones {
            let fromPicker = try Self.pickerValue(picked, in: zone)
            #expect(CalendarDay(fromPicker, in: zone) == picked, "\(zone.identifier)")
        }
    }

    @Test("Reading a locally picked day in UTC is what used to lose it")
    func utcReadingIsTheDefectBeingFixed() throws {
        // Paris midnight on 16 September is 22:00 UTC on the 15th. This is the
        // exact conversion the mapper used to perform, kept here so the
        // regression is described rather than merely absent.
        let paris = TimeZone(identifier: "Europe/Paris")!
        let picked = CalendarDay(year: 2026, month: 9, day: 16)
        let fromPicker = try Self.pickerValue(picked, in: paris)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let asUTC = utc.dateComponents([.year, .month, .day], from: fromPicker)
        #expect(asUTC.day == 15)

        #expect(CalendarDay(fromPicker, in: paris)?.day == 16)
    }

    @Test("Every day of 2026 round-trips in every zone, DST included")
    func everyDayRoundTrips() throws {
        for zone in Self.zones {
            for day in Self.everyDayOf(2026) {
                let readBack = CalendarDay(try Self.pickerValue(day, in: zone), in: zone)
                #expect(readBack == day, "\(zone.identifier) \(day)")
            }
        }
    }

    @Test("Spring-forward and fall-back days keep their own date")
    func daylightSavingTransitions() throws {
        let cases: [(String, [CalendarDay])] = [
            ("Europe/Paris", [
                CalendarDay(year: 2026, month: 3, day: 29),
                CalendarDay(year: 2026, month: 10, day: 25)
            ]),
            ("America/New_York", [
                CalendarDay(year: 2026, month: 3, day: 8),
                CalendarDay(year: 2026, month: 11, day: 1)
            ]),
            // Casablanca leaves and re-enters +01:00 around Ramadan.
            ("Africa/Casablanca", [
                CalendarDay(year: 2026, month: 2, day: 15),
                CalendarDay(year: 2026, month: 3, day: 22)
            ])
        ]
        for (identifier, days) in cases {
            let zone = TimeZone(identifier: identifier)!
            for day in days {
                #expect(CalendarDay(try Self.pickerValue(day, in: zone), in: zone) == day, "\(identifier) \(day)")
                // The day either side of a transition must not be dragged onto it.
                #expect(CalendarDay(try Self.pickerValue(day, in: zone), in: zone)?.month == day.month)
            }
        }
    }

    @Test("A month end never rolls backwards into the month before")
    func monthEndsDoNotRollBack() throws {
        for zone in Self.zones {
            for month in 1...12 {
                let last = CalendarDay(
                    year: 2026,
                    month: month,
                    day: Day.daysInMonth(year: 2026, month: month)
                )
                let readBack = CalendarDay(try Self.pickerValue(last, in: zone), in: zone)
                #expect(readBack == last, "\(zone.identifier) \(last)")
                #expect(readBack?.month == month)
            }
        }
    }

    @Test("The mapper's Day/Date bridge round-trips in both directions")
    func mapperBridgeRoundTrips() throws {
        for zone in Self.zones {
            for day in Self.everyDayOf(2026) {
                let domain = Day(year: day.year, month: day.month, day: day.day)
                #expect(DomainMapper.day(fixtureInstant(domain, in: zone), in: zone) == domain,
                        "\(zone.identifier) \(day)")
            }
        }
    }

    @Test("A draft dated from a picker maps to the day that was picked")
    func draftKeepsTheSelectedDay() throws {
        let account = Account(
            id: "bank", name: "Bank", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails
        )
        for zone in Self.zones {
            for picked in [
                CalendarDay(year: 2026, month: 9, day: 16),
                CalendarDay(year: 2026, month: 8, day: 31),
                CalendarDay(year: 2026, month: 12, day: 31),
                CalendarDay(year: 2026, month: 3, day: 29)
            ] {
                let draft = try #require(TransactionDraft(
                    date: try Self.pickerValue(picked, in: zone),
                    timeZone: zone,
                    kind: .expense,
                    amount: .eur(12.34),
                    accountID: account.id,
                    categoryKey: "food"
                ))
                let mapped = try DomainMapper().transaction(from: try #require(draft), accounts: [account])
                #expect(mapped.transaction.date == Day(year: picked.year, month: picked.month, day: picked.day),
                        "\(zone.identifier) \(picked)")
            }
        }
    }
}
