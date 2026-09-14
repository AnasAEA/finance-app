import Testing
import FinanceCore
@testable import FinanceApp

/// The app's side of the checked Day arithmetic.
///
/// Nothing here is reachable from a real calendar date. It exists so that the
/// screens' behaviour at the boundary is a decision on the record rather than
/// whatever the arithmetic happened to do.
@Suite("Checked day arithmetic at the app boundary")
struct DayF2AppBoundaryTests {

    private let asOf = Day(year: 2026, month: 9, day: 2)   // a Wednesday

    // MARK: - Period selection

    @Test func weekStartAtOrdinalEndpointsUsesTheExactWeekday() throws {
        // Independent integer reference: floorMod(i + 3, 7), evaluated with
        // arbitrary-precision integers. Constants avoid repeating the adapter.
        let cases: [(Int, Int)] = [
            (.max, 3), (.max - 1, 2), (.max - 2, 1), (.max - 3, 0),
            (.min, 2), (.min + 1, 3), (-1, 2), (0, 3), (1, 4)
        ]
        for (index, weekday) in cases {
            let day = Day(index: index)
            let monday = try #require(ReviewRequestBuilder.startOfWeek(containing: day))
            #expect(monday.days(until: day) == weekday, "ordinal \(index)")
            #expect(monday == day.advanced(by: -weekday))
        }
    }

    @Test func ordinaryPeriodSelectionIsUnchanged() throws {
        // Weeks still start on Monday, and the week arithmetic still runs
        // through the epoch ordinal for days that have one.
        #expect(
            ReviewRequestBuilder.startOfWeek(containing: asOf) == Day(year: 2026, month: 8, day: 31)
        )
        let week = try #require(ReviewRequestBuilder.calendarInterval(
            ReviewPeriodSelection(scope: .week, offset: -1), asOf: asOf
        ))
        #expect(week.start == Day(year: 2026, month: 8, day: 24))
        #expect(week.end == Day(year: 2026, month: 8, day: 30))

        let month = try #require(ReviewRequestBuilder.calendarInterval(
            ReviewPeriodSelection(scope: .month, offset: -13), asOf: asOf
        ))
        #expect(month.start == Day(year: 2025, month: 8, day: 1))
        #expect(month.end == Day(year: 2025, month: 8, day: 31))
    }

    /// Month offsets move once, checked, rather than stepping `abs(offset)`
    /// times — which could not express `Int.min` and walked the whole way.
    @Test func extremeMonthOffsetsAreAnsweredWithoutNegatingIntMin() {
        // Answered, exactly, not refused: these offsets stay inside the domain.
        #expect(
            ReviewRequestBuilder.calendarInterval(
                ReviewPeriodSelection(scope: .month, offset: .min), asOf: asOf
            )?.start == Day(year: -768_614_336_404_562_624, month: 1, day: 1)
        )
        #expect(
            ReviewRequestBuilder.calendarInterval(
                ReviewPeriodSelection(scope: .month, offset: .max), asOf: asOf
            )?.start == Day(year: 768_614_336_404_566_677, month: 4, day: 1)
        )
    }

    /// A week offset whose day count overflows is refused. The screen does not
    /// silently show a nearer week it could reach.
    @Test func anUnreachableWeekIsRefusedRatherThanSubstituted() {
        for offset in [Int.min, Int.max, Int.max / 6] {
            #expect(
                ReviewRequestBuilder.calendarInterval(
                    ReviewPeriodSelection(scope: .week, offset: offset), asOf: asOf
                ) == nil,
                "offset \(offset)"
            )
        }
        // And a request for such a period is not assembled at all.
        #expect(
            ReviewRequestBuilder.makeRequest(
                document: FinanceDocument(
                    schemaVersion: Interchange.currentSchemaVersion, documentKind: "TEST",
                    accounts: [], balances: []
                ),
                selection: ReviewPeriodSelection(scope: .week, offset: .min),
                asOf: asOf,
                categoryKeys: [:],
                incomeSources: [],
                coverage: .absent
            ) == nil
        )
    }

    /// The adapter requires a representable ordinal and does not substitute
    /// another week when that input is unavailable.
    @Test func aDayWithNoOrdinalHasNoGuessedWeekStart() {
        let extreme = Day(year: .max, month: 6, day: 1)
        #expect(extreme.index == nil)
        #expect(ReviewRequestBuilder.startOfWeek(containing: extreme) == nil)
    }

    /// Navigation stops at the last period it can actually build.
    @Test func navigationBoundsStayInsideWhatCanBeBuilt() {
        let earliest = ReviewRequestBuilder.earliestOffset(
            scope: .month, asOf: asOf, archiveCutoff: Day(year: 2026, month: 1, day: 31)
        )
        #expect(earliest < 0)
        #expect(ReviewRequestBuilder.calendarInterval(
            ReviewPeriodSelection(scope: .month, offset: earliest), asOf: asOf
        ) != nil)
    }

    // MARK: - The Insights screen

    /// A period the store cannot review is reported as unavailable. It is
    /// never presented as a reviewed period that happens to be empty.
    @Test @MainActor func anUnreviewablePeriodIsUnavailableNotEmpty() {
        let store = FinanceStore.preview()
        // The ordinary selections the screen offers still present.
        #expect(store.review(ReviewPeriodSelection(scope: .month, offset: 0)) != nil)
        #expect(store.review(ReviewPeriodSelection(scope: .week, offset: -1)) != nil)
        // One that cannot be constructed presents nothing at all.
        #expect(store.review(ReviewPeriodSelection(scope: .week, offset: .min)) == nil)
    }

    // MARK: - Import freshness

    /// A balance whose age cannot be stated refuses the import, sanitized by
    /// account identifier. It is never shown as "as of today".
    @Test func aBalanceWhoseAgeCannotBeStatedRefusesTheImport() throws {
        let account = Account(
            id: "bank-main", name: "Current", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails
        )
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account],
            balances: [
                AccountBalance(
                    accountID: account.id,
                    balance: Money(minorUnits: 1_000, currency: .eur),
                    asOf: Day(year: .min, month: 1, day: 1),
                    status: .observed
                )
            ],
            planning: FinanceDocument.Planning(defaultScenario: .base)
        )
        #expect(throws: AppImportError.inconsistentDocument(.undatableBalance(accountID: "bank-main"))) {
            try DocumentImporter.preview(of: document, today: Day(year: 2026, month: 9, day: 2))
        }
        // The message names the account and nothing about the money or the date.
        let message = AppImportError.SemanticProblem
            .undatableBalance(accountID: "bank-main").message
        #expect(message.contains("bank-main"))
        #expect(!message.contains("1000") && !message.contains("10.00"))

        // An ordinary anchor still previews, with its age intact.
        let ordinary = try DocumentImporter.preview(
            of: FinanceDocument(
                schemaVersion: Interchange.currentSchemaVersion,
                documentKind: "TEST",
                accounts: [account],
                balances: [
                    AccountBalance(
                        accountID: account.id,
                        balance: Money(minorUnits: 1_000, currency: .eur),
                        asOf: Day(year: 2026, month: 8, day: 30),
                        status: .observed
                    )
                ],
                planning: FinanceDocument.Planning(defaultScenario: .base)
            ),
            today: Day(year: 2026, month: 9, day: 2)
        )
        #expect(ordinary.accounts.first?.freshness == .daysOld(3))
    }

    // MARK: - History archive arithmetic

    /// A source gap ends on the last day of its end month. Reading that day
    /// directly is exact where "first day of the next month, minus one" needed
    /// two boundary moves that both fail at the end of the domain.
    @Test func aGapEndsOnTheLastDayOfItsEndMonthWithoutLeavingIt() {
        for month in [
            MonthKey(year: 2026, month: 2), MonthKey(year: 2024, month: 2),
            MonthKey(year: 2026, month: 4), MonthKey(year: 2026, month: 12)
        ] {
            // Identical to the old "next month's first day, minus one".
            let old = month.next?.firstDay.advanced(by: -1)
            #expect(month.firstDay.lastDayOfMonth == old, "\(month)")
        }
        // And still answerable in the month where the old form had no next.
        let last = MonthKey(year: .max, month: 12)
        #expect(last.next == nil)
        #expect(last.firstDay.lastDayOfMonth == Day(year: .max, month: 12, day: 31))
    }
}
