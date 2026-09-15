import FinanceCore
import Foundation
import Testing
@testable import FinanceApp

@Suite("Phase 2.9B period verification presentation")
struct PeriodVerificationMapperTests {
    private let period = ReviewInterval.month(MonthKey(year: 2026, month: 8))
    private func day(_ iso: String) -> Day { Day(isoString: iso)! }
    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    private func review() throws -> ReviewResult {
        let account = Account(
            id: "account-test", name: "Test current account", currency: .eur,
            kind: .bank, supportedRails: PaymentRail.euroBankRails
        )
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account],
            balances: [
                AccountBalance(
                    accountID: account.id,
                    balance: euro("500.00"),
                    asOf: period.start
                )
            ],
            planning: FinanceDocument.Planning(defaultScenario: .base)
        )
        return try ReviewEngine.review(
            ReviewRequest(
                document: document,
                kind: .monthly,
                interval: period,
                asOf: period.end,
                coverage: .liveCovered([period])
            )
        )
    }

    private func observation() -> SyncedObservationItem {
        SyncedObservationItem(
            id: "observation-unknown",
            providerName: "Test Bank",
            providerAccountName: "Test current account",
            isAccountBindingActive: true,
            amount: .eur(-24),
            status: .booked,
            resolution: .unreviewed,
            displayMerchant: "Unresolved purchase",
            observedMerchant: nil,
            rawMerchantText: nil,
            remittance: nil,
            merchantEmail: nil,
            bankTransactionCode: nil,
            dates: ObservationDates(
                booking: CalendarDay(year: 2026, month: 8, day: 7),
                transaction: nil,
                value: nil,
                derivedTransaction: nil,
                derivedProvenanceLabel: nil,
                economicPeriod: CalendarDay(year: 2026, month: 8, day: 7)
            ),
            observedAt: Date(timeIntervalSince1970: 1_777_680_000),
            suggestions: [],
            duplicateConflict: nil,
            hasProviderStatusWarning: false
        )
    }

    private func defaultExceptions() -> [PeriodCheckpointException] {
        [
            PeriodCheckpointException(
                id: "observation-unknown",
                kind: .unknownBookedEconomics,
                day: day("2026-08-07"),
                amount: euro("-24.00")
            ),
            PeriodCheckpointException(
                id: "uncategorized:2026-08",
                kind: .uncategorizedEconomicSpending,
                amount: euro("18.00")
            ),
            PeriodCheckpointException(
                id: "observation-aggregate",
                kind: .aggregateEvidenceModelLimitation,
                aggregateBasis: .structuralCandidateOnly,
                day: day("2026-08-09"),
                amount: euro("-40.00")
            ),
        ]
    }

    private func readiness(
        projection: SemanticPeriodProjection? = nil,
        exceptions: [PeriodCheckpointException]? = nil,
        baselineComparison: PeriodCheckpointBaselineComparison = .unavailable(.noBaselinePersistence)
    ) throws -> PeriodCheckpointReadiness {
        PeriodCheckpointEvaluator.evaluate(
            PeriodCheckpointRequest(
                period: period,
                kind: .monthly,
                asOf: day("2026-09-03"),
                review: try review(),
                exceptions: exceptions ?? defaultExceptions(),
                projection: projection,
                baselineComparison: baselineComparison
            )
        )
    }

    private func present(
        exceptions: [PeriodCheckpointException]? = nil,
        baselineComparison: PeriodCheckpointBaselineComparison
    ) throws -> PeriodVerificationPresentation {
        PeriodVerificationMapper.present(
            try readiness(exceptions: exceptions, baselineComparison: baselineComparison),
            periodLabel: "August 2026",
            observations: [observation()],
            expectedPayments: []
        )
    }

    // MARK: - Checkpoint verification state

    @Test("P1: a period the history holds nothing for is not verified")
    func neverClosedIsNotVerified() throws {
        let presentation = PeriodVerificationMapper.present(
            try readiness(baselineComparison: .notPreviouslyClosed),
            periodLabel: "August 2026",
            observations: [observation()],
            expectedPayments: []
        )
        #expect(presentation.verificationState == .notVerified)
        #expect(presentation.verificationState.headline == "Not verified yet.")
        #expect(presentation.changeSummary == nil)
    }

    @Test("P3: an unchanged stored checkpoint is verified")
    func unchangedIsVerified() throws {
        for quality in [PeriodCheckpointQuality.clean, .withExceptions] {
            let presentation = PeriodVerificationMapper.present(
                try readiness(baselineComparison: .unchangedSinceClose(previousQuality: quality)),
                periodLabel: "August 2026",
                observations: [observation()],
                expectedPayments: []
            )
            #expect(presentation.verificationState == .verified)
            #expect(presentation.verificationState.headline == "Verified.")
            #expect(presentation.changeSummary == nil)
        }
    }

    @Test("P4: a period that moved since its close reads as changed, never verified")
    func changedReadsAsChanged() throws {
        let presentation = PeriodVerificationMapper.present(
            try readiness(
                baselineComparison: .changedSinceClose(
                    previousQuality: .clean, changes: .init(.economicsChanged)
                )
            ),
            periodLabel: "August 2026",
            observations: [observation()],
            expectedPayments: []
        )
        #expect(presentation.verificationState == .changedSinceVerification)
        #expect(presentation.verificationState.headline == "Changes since verification.")
        let summary = try #require(presentation.changeSummary)
        #expect(summary.dimensions.contains(.economics))
        #expect(
            summary.statements.contains("The month's recorded spending or income is different.")
        )
    }

    @Test("P5: every comparison that settles nothing fails closed to unavailable")
    func inconclusiveFailsClosed() throws {
        let inconclusive: [PeriodCheckpointBaselineComparison] = [
            .unavailable(.noBaselinePersistence),
            .unavailable(.baselineProjectionUnreadable),
            .indeterminate(previousQuality: .clean, blockers: .init(.sourceGap)),
            .requiresReverification(
                previousQuality: .withExceptions,
                storedFormatToken: "v0",
                comparisonFormat: .v1
            ),
        ]
        for comparison in inconclusive {
            let presentation = PeriodVerificationMapper.present(
                try readiness(baselineComparison: comparison),
                periodLabel: "August 2026",
                observations: [observation()],
                expectedPayments: []
            )
            #expect(
                presentation.verificationState == .unavailable,
                "\(comparison) did not fail closed"
            )
            #expect(
                presentation.verificationState.headline == "Verification status unavailable."
            )
            #expect(presentation.changeSummary == nil, "\(comparison) claimed a change")
        }
    }

    @Test("Ended-period fixture has one decision and two limitations")
    func oneDecisionTwoLimitations() throws {
        let presentation = PeriodVerificationMapper.present(
            try readiness(),
            periodLabel: "August 2026",
            observations: [observation()],
            expectedPayments: []
        )

        #expect(presentation.decisionCount == 1)
        #expect(presentation.limitationCount == 2)
        #expect(presentation.decisions.count == 1)
        #expect(presentation.limitations.count == 2)
        #expect(presentation.decisions[0].destination != nil)
        #expect(presentation.limitations.allSatisfy { $0.destination == nil })
        #expect(
            presentation.totalsStatement
                == "Totals are calculated from what's recorded — they may not be the whole picture."
        )
        #expect(
            presentation.categoryStatement
                == "Some spending is counted but isn't assigned to a budget line."
        )
        #expect(
            presentation.auditStatement
                == "Not every relevant bank record has a confirmed relationship."
        )
        #expect(presentation.limitations.contains {
            $0.detail.contains("Arithmetic is not proof")
                && $0.detail.contains("no new expense should be created")
        })
        #expect(presentation.changeSummary == nil)
    }

    @Test("Verification presentation is independent of semantic projection")
    func projectionIsNotAPresentationInput() throws {
        let projection = SemanticPeriodProjection(
            period: SemanticInterval(period),
            kind: .monthly,
            coverage: .complete,
            budget: SemanticBudgetFact(try review().budget),
            transactions: [],
            observations: [],
            expectations: []
        )
        let without = PeriodVerificationMapper.present(
            try readiness(),
            periodLabel: "August 2026",
            observations: [observation()],
            expectedPayments: []
        )
        let with = PeriodVerificationMapper.present(
            try readiness(projection: projection),
            periodLabel: "August 2026",
            observations: [observation()],
            expectedPayments: []
        )
        #expect(with == without)
    }

    @Test("Presentation contains no checkpoint enum vocabulary or close-history claims")
    func noInternalVocabulary() throws {
        let presentation = PeriodVerificationMapper.present(
            try readiness(),
            periodLabel: "August 2026",
            observations: [observation()],
            expectedPayments: []
        )
        let visible = ([presentation.totalsStatement]
            + [presentation.categoryStatement, presentation.auditStatement].compactMap { $0 }
            + presentation.decisions.flatMap { [$0.title, $0.detail] }
            + presentation.limitations.flatMap { [$0.title, $0.detail] })
            .joined(separator: " ")
            .lowercased()
        for forbidden in [
            "unknownbookedeconomics", "aggregateevidencemodellimitation",
            "needsdecisions", "changed since", "unchanged since", "last verified",
            "already verified", "ready to close",
        ] {
            #expect(!visible.contains(forbidden), "\(forbidden)")
        }
    }

    // MARK: - Change summary

    @Test("An unchanged month has no change summary")
    func unchangedHasNoChangeSummary() throws {
        let presentation = try present(
            exceptions: [],
            baselineComparison: .unchangedSinceClose(previousQuality: .clean)
        )
        #expect(presentation.verificationState == .verified)
        #expect(presentation.changeSummary == nil)
    }

    @Test("A clean close whose economics moved names that dimension, not occupancy")
    func economicsChangeOnAStillCleanMonth() throws {
        let presentation = try present(
            exceptions: [],
            baselineComparison: .changedSinceClose(
                previousQuality: .clean, changes: .init(.economicsChanged)
            )
        )
        let summary = try #require(presentation.changeSummary)
        #expect(summary.dimensions == [.economics])
        #expect(summary.occupancyStatements.isEmpty)
        #expect(summary.statements == [
            "The month's recorded spending or income is different."
        ])
    }

    @Test("A clean close followed by a new booked movement says so")
    func newExceptionAfterACleanClose() throws {
        let presentation = try present(
            exceptions: [
                PeriodCheckpointException(
                    id: "observation-unknown",
                    kind: .unknownBookedEconomics,
                    day: day("2026-08-07"),
                    amount: euro("-24.00")
                )
            ],
            baselineComparison: .changedSinceClose(
                previousQuality: .clean, changes: .init(.evidenceChanged)
            )
        )
        let summary = try #require(presentation.changeSummary)
        #expect(summary.occupancyStatements == ["1 bank movement now needs review."])
        #expect(summary.dimensions == [.evidence])
        #expect(summary.statements.first == "1 bank movement now needs review.")
    }

    @Test("Several new booked movements use the plural")
    func severalNewBankMovements() throws {
        let presentation = try present(
            exceptions: [
                PeriodCheckpointException(
                    id: "observation-a",
                    kind: .unknownBookedEconomics,
                    day: day("2026-08-07"),
                    amount: euro("-12.00")
                ),
                PeriodCheckpointException(
                    id: "observation-b",
                    kind: .unknownBookedEconomics,
                    day: day("2026-08-08"),
                    amount: euro("-8.00")
                ),
            ],
            baselineComparison: .changedSinceClose(
                previousQuality: .clean, changes: .init(.evidenceChanged)
            )
        )
        let summary = try #require(presentation.changeSummary)
        #expect(summary.occupancyStatements == ["2 bank movements now need review."])
    }

    @Test("A close that carried exceptions, now carrying none, says they are gone")
    func disappearedExceptionsAfterAnAcknowledgedClose() throws {
        let presentation = try present(
            exceptions: [],
            baselineComparison: .changedSinceClose(
                previousQuality: .withExceptions, changes: .init(.evidenceChanged)
            )
        )
        let summary = try #require(presentation.changeSummary)
        #expect(summary.occupancyStatements == [
            "Previously acknowledged items are no longer present."
        ])
        #expect(summary.dimensions == [.evidence])
    }

    @Test("Issues then and issues now do not invent correspondence")
    func mixedOccupancyDoesNotClaimPrecision() throws {
        let presentation = try present(
            baselineComparison: .changedSinceClose(
                previousQuality: .withExceptions, changes: .init(.economicsChanged)
            )
        )
        let summary = try #require(presentation.changeSummary)
        #expect(summary.occupancyStatements.isEmpty)
        #expect(summary.dimensions == [.economics])
        let visible = summary.statements.joined(separator: " ").lowercased()
        #expect(!visible.contains("now needs review"))
        #expect(!visible.contains("no longer present"))
        #expect(!visible.contains("observation-unknown"))
        #expect(!visible.contains("uncategorized:2026-08"))
    }

    @Test("A same-id current exception is not treated as the previous subject")
    func sameIdentifierIsNotSemanticIdentity() throws {
        let presentation = try present(
            exceptions: [
                PeriodCheckpointException(
                    id: "observation-unknown",
                    kind: .unknownBookedEconomics,
                    day: day("2026-08-07"),
                    amount: euro("-99.00")
                )
            ],
            baselineComparison: .changedSinceClose(
                previousQuality: .withExceptions, changes: .init(.evidenceChanged)
            )
        )
        let summary = try #require(presentation.changeSummary)
        #expect(summary.occupancyStatements.isEmpty)
        let visible = summary.statements.joined(separator: " ")
        #expect(!visible.contains("observation-unknown"))
        #expect(!visible.lowercased().contains("now needs review"))
        #expect(!visible.lowercased().contains("identical"))
    }

    @Test("Every change class maps to product copy and never names itself")
    func everyChangeClassHasProductCopy() throws {
        #expect(PeriodCheckpointChangeClass.allCases.count == VerificationChangeDimension.allCases.count)
        for changeClass in PeriodCheckpointChangeClass.allCases {
            let presentation = try present(
                exceptions: [],
                baselineComparison: .changedSinceClose(
                    previousQuality: .clean, changes: .init(changeClass)
                )
            )
            let summary = try #require(presentation.changeSummary)
            #expect(summary.dimensions.count == 1, "\(changeClass)")
            #expect(summary.occupancyStatements.isEmpty, "\(changeClass)")
            let visible = summary.statements.joined(separator: " ").lowercased()
            #expect(!visible.contains(changeClass.rawValue.lowercased()), "\(changeClass)")
            #expect(!visible.contains("changedsinceclose"))
            #expect(!visible.contains("revision"))
            #expect(!visible.contains("predecessor"))
            #expect(!visible.contains("digest"))
            #expect(!visible.contains("canonical"))
        }
    }

    @Test("Several dimensions keep comparison rank and do not dump identifiers")
    func multipleDimensionsKeepRank() throws {
        let presentation = try present(
            exceptions: [],
            baselineComparison: .changedSinceClose(
                previousQuality: .clean,
                changes: .init(.expectationChanged, .economicsChanged, .evidenceChanged)
            )
        )
        let summary = try #require(presentation.changeSummary)
        #expect(summary.dimensions == [.economics, .evidence, .expectation])
        #expect(summary.statements == [
            "The month's recorded spending or income is different.",
            "The month's available evidence has changed.",
            "A scheduled payment's standing has changed.",
        ])
    }

    @Test("Unavailable comparison never claims specific changes")
    func unavailableComparisonHasNoSummary() throws {
        let presentation = try present(
            baselineComparison: .unavailable(.baselineProjectionUnreadable)
        )
        #expect(presentation.verificationState == .unavailable)
        #expect(presentation.changeSummary == nil)
    }
}
