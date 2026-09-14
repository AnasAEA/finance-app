import Testing
import Foundation
import FinanceCore
@testable import FinanceApp

/// Checkpoint close / reverify policy foundation.
///
/// What this suite proves is that the producer half of a checkpoint write
/// decides correctly — which revision, if any, an ended month should become —
/// and that deciding is all it does. Nothing here stores anything, and the
/// policy it exercises cannot.
///
/// Readiness is never assembled. Every readiness below comes from
/// `PeriodCheckpointEvaluator` through a `ReviewResult` the real `ReviewEngine`
/// produced, and every comparison is derived exactly the way
/// `AttentionComposition` derives it in production — two passes, the second
/// carrying the first's comparison. A test that hand-built a readiness would be
/// testing a shape, not the product.
///
/// Every fixture is synthetic. No real store, device or provider is touched.
@Suite("Checkpoint close / reverify policy")
struct CheckpointClosePolicyTests {

    // MARK: - Fixtures

    private static let august = ReviewInterval.month(MonthKey(year: 2026, month: 8))
    private static let september = ReviewInterval.month(MonthKey(year: 2026, month: 9))
    private static let october = ReviewInterval.month(MonthKey(year: 2026, month: 10))

    /// After August ends, so an August checkpoint is not `periodNotEnded`.
    private let asOf = Day(year: 2026, month: 9, day: 3)

    private let candidateID = UUID(uuidString: "A0000000-0000-0000-0000-00000000000A")!
    private let closedAt = Date(timeIntervalSinceReferenceDate: 820_000_000)

    private var identity: CheckpointAppendIdentity {
        CheckpointAppendIdentity(candidateID: candidateID, closedAt: closedAt)
    }

    private func day(_ iso: String) -> Day { Day(isoString: iso)! }
    private func euro(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .eur)! }

    /// One account with a dated balance: enough for the engine to review a
    /// period, small enough that every exception is one a test stated.
    private func document(from start: Day) -> FinanceDocument {
        let account = Account(
            id: "account-test", name: "Test current account", currency: .eur,
            kind: .bank, supportedRails: PaymentRail.euroBankRails
        )
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account],
            balances: [
                AccountBalance(accountID: account.id, balance: euro("500.00"), asOf: start)
            ],
            planning: FinanceDocument.Planning(defaultScenario: .base)
        )
    }

    /// A real review of one period, produced by the authoritative engine.
    private func review(
        _ interval: ReviewInterval, kind: ReviewPeriodKind = .monthly
    ) throws -> ReviewResult {
        try ReviewEngine.review(
            ReviewRequest(
                document: document(from: interval.start),
                kind: kind,
                interval: interval,
                asOf: interval.end,
                coverage: .liveCovered([interval])
            )
        )
    }

    /// A complete projection for one period. `spendingMinor` is the only dial:
    /// two projections that differ by it are two different semantic states of
    /// the same period, which is exactly what "changed since close" means.
    private func projection(
        _ interval: ReviewInterval,
        kind: ReviewPeriodKind = .monthly,
        spendingMinor: Int64 = 12_345
    ) -> SemanticPeriodProjection {
        SemanticPeriodProjection(
            period: SemanticInterval(interval),
            kind: kind,
            coverage: .complete,
            budget: SemanticBudgetFact(
                periodEconomicSpending: Money(minorUnits: spendingMinor, currency: .eur),
                uncategorized: Money(minorUnits: 0, currency: .eur),
                attributions: []
            ),
            transactions: [],
            observations: [],
            expectations: []
        )
    }

    /// Readiness exactly as production builds it.
    ///
    /// `AttentionComposition.readiness(for:)` evaluates twice: once to
    /// establish the current state the baseline is measured against, then again
    /// carrying that comparison. Reproduced here rather than approximated,
    /// because the policy cross-checks the comparison the readiness carries
    /// against the one its chain tip produces — and a harness that skipped the
    /// second pass would fail that check for the wrong reason.
    private func readiness(
        period: ReviewInterval = august,
        kind: ReviewPeriodKind = .monthly,
        asOf: Day? = nil,
        exceptions: [PeriodCheckpointException] = [],
        confirmed: PeriodCheckpointConfirmedAcknowledgments = .noDecisions,
        projection: SemanticPeriodProjection?? = nil,
        tip: PeriodCheckpointStoredRead = .empty
    ) throws -> PeriodCheckpointReadiness {
        var request = PeriodCheckpointRequest(
            period: period,
            kind: kind,
            asOf: asOf ?? self.asOf,
            review: try review(period, kind: kind),
            exceptions: exceptions,
            confirmedAcknowledgments: confirmed,
            projection: projection ?? self.projection(period, kind: kind)
        )
        request.baselineComparison = PeriodCheckpointBaselineReader.comparison(
            baseline: PeriodCheckpointBaselineReader.source(for: tip),
            current: PeriodCheckpointEvaluator.evaluate(request)
        )
        return PeriodCheckpointEvaluator.evaluate(request)
    }

    /// A stored chain tip for one period, carrying a chosen projection.
    private func storedTip(
        id: UUID = UUID(uuidString: "B0000000-0000-0000-0000-00000000000B")!,
        period: ReviewInterval = august,
        kind: ReviewPeriodKind = .monthly,
        revisionNumber: Int64 = 1,
        predecessorID: UUID? = nil,
        closedAt: Date = Date(timeIntervalSinceReferenceDate: 810_000_000),
        spendingMinor: Int64 = 12_345,
        exceptions: [PeriodCheckpointException] = []
    ) throws -> PeriodCheckpointRevision {
        try PeriodCheckpointRevision(
            rehydratingStoredSnapshot: id,
            period: SemanticInterval(period),
            periodKind: kind,
            revisionNumber: revisionNumber,
            predecessorID: predecessorID,
            closedAt: closedAt,
            canonicalProjection: try CanonicalSemanticPeriodProjection(
                projection(period, kind: kind, spendingMinor: spendingMinor)
            ),
            acknowledgedExceptions: exceptions.map(AcknowledgedExceptionRecord.init),
            quality: exceptions.isEmpty ? .clean : .withExceptions,
            safeClaims: .surviving(exceptions)
        )
    }

    /// A header in a projection format this build does not implement.
    private func unsupportedHeader(
        period: ReviewInterval = august, kind: ReviewPeriodKind = .monthly
    ) -> PeriodCheckpointStoredHeader {
        PeriodCheckpointStoredHeader(
            revisionID: UUID(uuidString: "C0000000-0000-0000-0000-00000000000C")!,
            period: SemanticInterval(period),
            periodKind: kind,
            revisionNumber: 1,
            predecessorID: nil,
            previousQuality: .clean,
            formatToken: "finance-app/semantic-period-projection/v99"
        )
    }

    private func exception(_ id: String, _ decimal: String) -> PeriodCheckpointException {
        PeriodCheckpointException(
            id: id, kind: .overdueExpectedOccurrence,
            day: day("2026-08-05"), amount: euro(decimal)
        )
    }

    /// Confirmed authority for an exact carried set, through the only producer.
    private func confirm(
        _ decisions: [PeriodCheckpointException], carrying carried: [PeriodCheckpointException]
    ) throws -> PeriodCheckpointConfirmedAcknowledgments {
        try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            decisions: decisions, carriedExceptions: carried
        )
    }

    // MARK: - Reading a decision

    private func refusal(_ decision: CheckpointClosePolicyDecision) -> CheckpointClosePolicyRefusal? {
        if case let .refused(reason) = decision { return reason }
        return nil
    }

    private func appended(
        _ decision: CheckpointClosePolicyDecision,
        identity suppliedIdentity: CheckpointAppendIdentity? = nil
    ) -> PeriodCheckpointRevision? {
        switch decision {
        case let .firstClose(plan), let .reverify(plan):
            switch CheckpointClosePolicy.materialize(plan: plan, identity: suppliedIdentity ?? identity) {
            case let .candidate(revision): return revision
            case .refused:
                Issue.record("valid classified fixture should materialize")
                return nil
            }
        case .alreadyCurrent, .refused: return nil
        }
    }

    private func isFirstClose(_ decision: CheckpointClosePolicyDecision) -> Bool {
        if case .firstClose = decision { return true }
        return false
    }

    private func isReverify(_ decision: CheckpointClosePolicyDecision) -> Bool {
        if case .reverify = decision { return true }
        return false
    }

    private func isAlreadyCurrent(_ decision: CheckpointClosePolicyDecision) -> Bool {
        if case .alreadyCurrent = decision { return true }
        return false
    }

    // MARK: - P1-P9: eligibility and product scope

    @Test("P1: a ready, clean, ended month with no history is a first close")
    func firstCloseOfACleanMonth() throws {
        let decision = CheckpointClosePolicy.classify(
            currentReadiness: try readiness(),
            currentChainTip: .empty
        )

        #expect(isFirstClose(decision))
        let revision = try #require(appended(decision))
        #expect(revision.revisionNumber == 1)
        #expect(revision.predecessorID == nil)
        #expect(revision.id == candidateID)
        #expect(revision.closedAt == closedAt)
        #expect(revision.period == SemanticInterval(Self.august))
        #expect(revision.periodKind == .monthly)
        #expect(revision.quality == .clean)
        #expect(revision.acknowledgedExceptions.isEmpty)
    }

    @Test("P2: a first close carries every acknowledged exception, exactly")
    func firstCloseCarriesAcknowledgments() throws {
        let carried = [exception("occurrence:rent", "200.00"), exception("occurrence:gym", "35.00")]
        let ready = try readiness(
            exceptions: carried, confirmed: try confirm(carried, carrying: carried)
        )
        #expect(ready.disposition == .readyWithAcknowledgedExceptions)

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: .empty
        )

        let revision = try #require(appended(decision))
        #expect(isFirstClose(decision))
        #expect(revision.quality == .withExceptions)
        #expect(Set(revision.acknowledgedExceptions.map(\.exception)) == Set(carried))
        #expect(revision.acknowledgedExceptions.count == carried.count)
    }

    @Test("P3: a blocked month is refused")
    func blockedIsRefused() throws {
        // Two exceptions sharing one identifier: an invalid exception set, and
        // a blocker the evaluator raises independently of coverage.
        let clash = [exception("occurrence:rent", "200.00"), exception("occurrence:rent", "250.00")]
        let ready = try readiness(exceptions: clash)
        #expect(ready.disposition == .blocked)

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: .empty
        )
        #expect(refusal(decision) == .readinessNotReady)
        #expect(appended(decision) == nil)
    }

    @Test("P4: an undecided limitation is refused")
    func needsDecisionsIsRefused() throws {
        let ready = try readiness(exceptions: [exception("occurrence:rent", "200.00")])
        #expect(ready.disposition == .needsDecisions)

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: .empty
        )
        #expect(refusal(decision) == .readinessNotReady)
        #expect(appended(decision) == nil)
    }

    @Test("P5: readiness with no semantic projection is refused")
    func missingProjectionIsRefused() throws {
        let ready = try readiness(projection: .some(nil))
        #expect(ready.projection == nil)
        #expect(ready.disposition.isReady)

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: .empty
        )
        #expect(refusal(decision) == .semanticProjectionUnavailable)
        #expect(appended(decision) == nil)
    }

    @Test("P6: a month that has not ended is refused as not ended")
    func unendedMonthIsRefused() throws {
        let ready = try readiness(
            period: Self.september, asOf: day("2026-09-03")
        )
        #expect(ready.blockers.contains { $0.kind == .periodNotEnded })

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: .empty
        )
        #expect(refusal(decision) == .periodNotEnded)
        #expect(appended(decision) == nil)
    }

    @Test("P7: a future month is refused as not ended")
    func futureMonthIsRefused() throws {
        let ready = try readiness(period: Self.october, asOf: day("2026-09-03"))

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: .empty
        )
        #expect(refusal(decision) == .periodNotEnded)
        #expect(appended(decision) == nil)
    }

    @Test("P8: a weekly period is never a product write, however ready it is")
    func weeklyIsRefused() throws {
        let week = try #require(ReviewInterval.weekStarting(day("2026-08-03")))
        let ready = try readiness(period: week, kind: .weekly, asOf: day("2026-08-20"))
        #expect(ready.disposition == .readyClean)

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: .empty
        )
        #expect(refusal(decision) == .unsupportedWriteScope)
        #expect(appended(decision) == nil)
    }

    @Test("P9: an interval that is not a whole calendar month is refused")
    func partialMonthIsRefused() throws {
        // Month-to-date: the shape `ReviewRequestBuilder` builds for a running
        // month, carrying `.monthly` and ending mid-month.
        let partial = ReviewInterval(start: day("2026-08-01"), end: day("2026-08-15"))
        let ready = try readiness(period: partial, asOf: day("2026-08-20"))
        #expect(ready.disposition == .readyClean)

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: .empty
        )
        #expect(refusal(decision) == .unsupportedWriteScope)
        #expect(appended(decision) == nil)
    }

    @Test("P9b: a period that starts mid-month is refused, and one whole month is not")
    func onlyAWholeCalendarMonthIsProductScope() throws {
        #expect(CheckpointClosePolicy.isMonthlyProductScope(
            period: SemanticInterval(Self.august), kind: .monthly
        ))
        // Right length, wrong boundaries.
        #expect(!CheckpointClosePolicy.isMonthlyProductScope(
            period: SemanticInterval(start: day("2026-08-02"), end: day("2026-09-01")),
            kind: .monthly
        ))
        // Whole month, wrong kind.
        #expect(!CheckpointClosePolicy.isMonthlyProductScope(
            period: SemanticInterval(Self.august), kind: .weekly
        ))
        // Two whole months is not one month.
        #expect(!CheckpointClosePolicy.isMonthlyProductScope(
            period: SemanticInterval(start: day("2026-08-01"), end: day("2026-09-30")),
            kind: .monthly
        ))
        // February, so the last day is not assumed.
        #expect(CheckpointClosePolicy.isMonthlyProductScope(
            period: SemanticInterval(start: day("2026-02-01"), end: day("2026-02-28")),
            kind: .monthly
        ))
        #expect(!CheckpointClosePolicy.isMonthlyProductScope(
            period: SemanticInterval(start: day("2026-02-01"), end: day("2026-02-27")),
            kind: .monthly
        ))
    }

    // MARK: - C1-C10: the chain

    @Test("C1: a changed month with a supported tip appends after it")
    func changedMonthReverifies() throws {
        let tip = try storedTip(revisionNumber: 3, predecessorID: UUID(), spendingMinor: 11_111)
        let read = PeriodCheckpointStoredRead.supported(tip)
        let ready = try readiness(tip: read)

        guard case .changedSinceClose = ready.baselineComparison else {
            Issue.record("expected a changed comparison, got \(ready.baselineComparison)")
            return
        }

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: read
        )

        #expect(isReverify(decision))
        let revision = try #require(appended(decision))
        #expect(revision.revisionNumber == 4)
        #expect(revision.predecessorID == tip.id)
        #expect(revision.id == candidateID)
        #expect(revision.closedAt == closedAt)
    }

    @Test("C2: a tip that already represents this exact state is already current")
    func unchangedIsAlreadyCurrent() throws {
        let tip = try storedTip(spendingMinor: 12_345)
        let read = PeriodCheckpointStoredRead.supported(tip)
        let ready = try readiness(tip: read)

        guard case .unchangedSinceClose = ready.baselineComparison else {
            Issue.record("expected an unchanged comparison, got \(ready.baselineComparison)")
            return
        }

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: read
        )

        #expect(isAlreadyCurrent(decision))
        #expect(appended(decision) == nil)
        #expect(refusal(decision) == nil)
    }

    @Test("C3: requires-reverification over a supported tip is an append, not a refusal")
    func requiresReverificationOverASupportedTipAppends() throws {
        // Reachable only through the comparison vocabulary in this build: a
        // supported revision always carries a payload in the comparison format,
        // so `.requiresReverification` arrives from an unsupported-format
        // *header*, which `classify` refuses by name (C4). The rule that a
        // supported tip needing re-verification appends is stated here so a
        // later build — one where a supported revision can be readable and not
        // comparable — inherits the decided answer rather than a new argument.
        #expect(
            CheckpointClosePolicy.outcome(
                for: .requiresReverification(
                    previousQuality: .clean,
                    storedFormatToken: "finance-app/semantic-period-projection/v99",
                    comparisonFormat: .v1
                ),
                hasSupportedTip: true
            ) == .append
        )
    }

    @Test("C4: an unsupported-format tip is refused, and never a first close")
    func unsupportedTipIsRefused() throws {
        let read = PeriodCheckpointStoredRead.unsupportedFormat(unsupportedHeader())
        let ready = try readiness(tip: read)

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: read
        )
        #expect(refusal(decision) == .previousRevisionFormatUnsupported)
        #expect(!isFirstClose(decision))
        #expect(appended(decision) == nil)
    }

    @Test("C5: a corrupt tip is refused, and never a first close")
    func corruptTipIsRefused() throws {
        let read = PeriodCheckpointStoredRead.corrupt(.storeUnreadable)
        let ready = try readiness(tip: read)

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: read
        )
        #expect(refusal(decision) == .previousRevisionCorrupt)
        #expect(!isFirstClose(decision))
        #expect(appended(decision) == nil)

        // And the world it describes really is an unavailable baseline, not an
        // empty one: absence of a reading is never a reading of absence.
        let derived = PeriodCheckpointBaselineReader.comparison(
            baseline: PeriodCheckpointBaselineReader.source(for: read), current: ready
        )
        #expect(derived == .unavailable(.baselineProjectionUnreadable))
    }

    @Test("C6: an indeterminate comparison can never reach an append")
    func indeterminateNeverAppends() throws {
        // A period whose own evidence cannot support a comparison is blocked,
        // so `classify` refuses it before the comparison is consulted — and the
        // comparison it would have produced is `.indeterminate`, never
        // `.changedSinceClose`. Both halves are pinned.
        let tip = try storedTip()
        let read = PeriodCheckpointStoredRead.supported(tip)
        let clash = [exception("occurrence:rent", "200.00"), exception("occurrence:rent", "250.00")]
        let blocked = try readiness(exceptions: clash, tip: read)

        guard case .indeterminate = blocked.baselineComparison else {
            Issue.record("expected an indeterminate comparison, got \(blocked.baselineComparison)")
            return
        }

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: blocked, currentChainTip: read
        )
        #expect(appended(decision) == nil)
        #expect(refusal(decision) == .readinessNotReady)

        // The comparison itself permits nothing, whichever route reaches it.
        #expect(
            CheckpointClosePolicy.outcome(
                for: blocked.baselineComparison, hasSupportedTip: true
            ) == .refuse(.comparisonIndeterminate)
        )
    }

    @Test("C7: an unavailable comparison can never reach an append")
    func unavailableNeverAppends() throws {
        for unavailability in [
            PeriodCheckpointBaselineComparison.Unavailability.noBaselinePersistence,
            .baselineProjectionUnreadable,
        ] {
            #expect(
                CheckpointClosePolicy.outcome(
                    for: .unavailable(unavailability), hasSupportedTip: true
                ) == .refuse(.comparisonUnavailable)
            )
            #expect(
                CheckpointClosePolicy.outcome(
                    for: .unavailable(unavailability), hasSupportedTip: false
                ) == .refuse(.comparisonUnavailable)
            )
        }
    }

    @Test("C8: a tip from another period is refused")
    func wrongPeriodTipIsRefused() throws {
        let foreign = try storedTip(period: Self.september)
        let read = PeriodCheckpointStoredRead.supported(foreign)

        // The readiness is August's; the tip is September's. Built against the
        // empty read so the refusal is the mismatch itself rather than the
        // coherence check that would also catch it.
        let decision = CheckpointClosePolicy.classify(
            currentReadiness: try readiness(tip: .empty),
            currentChainTip: read
        )
        #expect(refusal(decision) == .previousRevisionPeriodMismatch)
        #expect(appended(decision) == nil)
    }

    @Test("C9: a tip of another period kind is refused")
    func wrongKindTipIsRefused() throws {
        // Same days, different kind: a weekly close does not speak for a
        // monthly one even when the intervals coincide.
        let foreign = try storedTip(kind: .weekly)
        let read = PeriodCheckpointStoredRead.supported(foreign)

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: try readiness(tip: .empty),
            currentChainTip: read
        )
        #expect(refusal(decision) == .previousRevisionKindMismatch)
        #expect(appended(decision) == nil)
    }

    @Test("C10: chain position comes from revisionNumber, and closedAt cannot move it")
    func predecessorIsChosenByRevisionNumber() throws {
        let earlyClose = Date(timeIntervalSinceReferenceDate: 1)
        let lateClose = Date(timeIntervalSinceReferenceDate: 900_000_000)

        // The same tip, stamped at two wildly different times. If `closedAt`
        // had any say in chain position, these would disagree.
        for stamp in [earlyClose, lateClose] {
            let tip = try storedTip(
                revisionNumber: 7, predecessorID: UUID(), closedAt: stamp, spendingMinor: 11_111
            )
            let read = PeriodCheckpointStoredRead.supported(tip)
            let decision = CheckpointClosePolicy.classify(
                currentReadiness: try readiness(tip: read),
                currentChainTip: read
            )
            let revision = try #require(appended(decision))
            #expect(revision.revisionNumber == 8)
            #expect(revision.predecessorID == tip.id)
        }
    }

    @Test("C11: a tip and a comparison read from different observations refuse")
    func inconsistentObservationIsRefused() throws {
        // Readiness evaluated against an empty store; the tip says otherwise.
        // Neither reading may be used, and the policy says so rather than
        // picking one.
        let tip = try storedTip(spendingMinor: 11_111)
        let read = PeriodCheckpointStoredRead.supported(tip)
        let staleReadiness = try readiness(tip: .empty)
        #expect(staleReadiness.baselineComparison == .notPreviouslyClosed)

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: staleReadiness, currentChainTip: read
        )
        #expect(refusal(decision) == .inconsistentPreviousObservation)
        #expect(appended(decision) == nil)

        // And the other way round: readiness that knows about a tip, handed an
        // empty read.
        let freshReadiness = try readiness(tip: read)
        let reversed = CheckpointClosePolicy.classify(
            currentReadiness: freshReadiness, currentChainTip: .empty
        )
        #expect(refusal(reversed) == .inconsistentPreviousObservation)
        #expect(appended(reversed) == nil)
    }

    @Test("CR1: supported A says unchanged but supplied B says changed, so classification refuses")
    func supportedUnchangedWitnessCannotHideChangedTip() throws {
        let a = try storedTip(spendingMinor: 12_345)
        let b = try storedTip(
            id: UUID(uuidString: "BBBBBBBB-1111-1111-1111-111111111111")!,
            revisionNumber: 7, predecessorID: UUID(), spendingMinor: 11_111
        )
        let readB = PeriodCheckpointStoredRead.supported(b)
        let againstA = try readiness(tip: .supported(a))
        #expect(againstA.baselineComparison == .unchangedSinceClose(previousQuality: .clean))
        guard case .changedSinceClose = try readiness(tip: readB).baselineComparison else {
            Issue.record("B must produce a changed comparison")
            return
        }

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: againstA, currentChainTip: readB
        )
        #expect(refusal(decision) == .inconsistentPreviousObservation)
    }

    @Test("CR2: supported A says changed but supplied B says unchanged, so classification refuses")
    func supportedChangedWitnessCannotAppendOverUnchangedTip() throws {
        let a = try storedTip(spendingMinor: 11_111)
        let b = try storedTip(
            id: UUID(uuidString: "BBBBBBBB-1111-1111-1111-111111111111")!,
            revisionNumber: 7, predecessorID: UUID(), spendingMinor: 12_345
        )
        let readB = PeriodCheckpointStoredRead.supported(b)
        let againstA = try readiness(tip: .supported(a))
        guard case .changedSinceClose = againstA.baselineComparison else {
            Issue.record("A must produce a changed comparison")
            return
        }
        #expect(try readiness(tip: readB).baselineComparison == .unchangedSinceClose(previousQuality: .clean))

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: againstA, currentChainTip: readB
        )
        #expect(refusal(decision) == .inconsistentPreviousObservation)
    }

    @Test("CR3: equal comparison results do not transfer A's chain authority to the supplied B tip")
    func equalComparisonWitnessUsesOnlySuppliedTipMetadata() throws {
        let a = try storedTip(spendingMinor: 11_111)
        let b = try storedTip(
            id: UUID(uuidString: "BBBBBBBB-1111-1111-1111-111111111111")!,
            revisionNumber: 7, predecessorID: UUID(), spendingMinor: 22_222
        )
        let readB = PeriodCheckpointStoredRead.supported(b)
        let againstA = try readiness(tip: .supported(a))
        let againstB = try readiness(tip: readB)
        #expect(a.id != b.id)
        #expect(a.revisionNumber != b.revisionNumber)
        guard case .changedSinceClose = againstA.baselineComparison else {
            Issue.record("A must produce a changed comparison")
            return
        }
        #expect(againstA.baselineComparison == againstB.baselineComparison)

        // The recomputed B comparison is semantic authority. A's comparison
        // is only a coherence witness; equal results do not identify a read.
        let decision = CheckpointClosePolicy.classify(
            currentReadiness: againstA, currentChainTip: readB
        )
        #expect(isReverify(decision))
        let revision = try #require(appended(decision))
        #expect(revision.predecessorID == b.id)
        #expect(revision.revisionNumber == b.revisionNumber + 1)
        #expect(revision.predecessorID != a.id)
        #expect(revision.canonicalProjection.bytes == (try CanonicalSemanticPeriodProjection(#require(againstA.projection))).bytes)
    }

    @Test("C12: every comparison state has exactly one outcome")
    func theComparisonVocabularyIsTotal() throws {
        let changed = PeriodCheckpointChangeClasses([.economicsChanged])!
        let states: [(PeriodCheckpointBaselineComparison, Bool, CheckpointClosePolicy.ComparisonOutcome)] = [
            (.notPreviouslyClosed, false, .append),
            (.notPreviouslyClosed, true, .refuse(.inconsistentPreviousObservation)),
            (.unchangedSinceClose(previousQuality: .clean), true, .alreadyCurrent),
            (.unchangedSinceClose(previousQuality: .clean), false, .refuse(.inconsistentPreviousObservation)),
            (.changedSinceClose(previousQuality: .clean, changes: changed), true, .append),
            (.changedSinceClose(previousQuality: .clean, changes: changed), false, .refuse(.inconsistentPreviousObservation)),
            (.requiresReverification(previousQuality: .clean, storedFormatToken: "v99", comparisonFormat: .v1), true, .append),
            (.requiresReverification(previousQuality: .clean, storedFormatToken: "v99", comparisonFormat: .v1), false, .refuse(.inconsistentPreviousObservation)),
            (.unavailable(.noBaselinePersistence), true, .refuse(.comparisonUnavailable)),
            (.unavailable(.baselineProjectionUnreadable), false, .refuse(.comparisonUnavailable)),
        ]
        for (comparison, hasTip, expected) in states {
            #expect(
                CheckpointClosePolicy.outcome(for: comparison, hasSupportedTip: hasTip) == expected,
                "\(comparison) with tip=\(hasTip)"
            )
        }
    }

    // MARK: - I1-I6: idempotency and identity

    @Test("I1: an unchanged month is already current without append metadata")
    func alreadyCurrentNeedsNoIdentity() throws {
        let read = PeriodCheckpointStoredRead.supported(try storedTip())
        let decision = CheckpointClosePolicy.classify(
            currentReadiness: try readiness(tip: read), currentChainTip: read
        )
        #expect(isAlreadyCurrent(decision))
        #expect(appended(decision) == nil)
    }

    @Test("I2: deciding twice over the same world gives the same answer")
    func decidingIsStable() throws {
        // The product's idempotency is this: after a close lands, the next
        // decision over the tip it created is `alreadyCurrent`, not a second
        // revision. Modelled end to end — first close, then re-decide against
        // the revision that close produced.
        let first = CheckpointClosePolicy.classify(
            currentReadiness: try readiness(tip: .empty), currentChainTip: .empty
        )
        let stored = try #require(appended(first))
        #expect(isFirstClose(first))

        let read = PeriodCheckpointStoredRead.supported(stored)
        let afterwards = CheckpointClosePolicy.classify(
            currentReadiness: try readiness(tip: read),
            currentChainTip: read
        )
        #expect(isAlreadyCurrent(afterwards))
        #expect(appended(afterwards) == nil)
    }

    @Test("I3/I4: a candidate carries exactly the supplied identity and time")
    func candidateUsesSuppliedIdentity() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let stamp = Date(timeIntervalSinceReferenceDate: 777_777_777)

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: try readiness(),
            currentChainTip: .empty
        )
        let revision = try #require(appended(decision, identity: CheckpointAppendIdentity(candidateID: id, closedAt: stamp)))
        #expect(revision.id == id)
        #expect(revision.closedAt == stamp)
    }

    @Test("I5: the candidate's projection is the readiness's own, byte for byte")
    func candidateProjectionComesFromTheSameReadiness() throws {
        let ready = try readiness()
        let decision = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: .empty
        )
        let revision = try #require(appended(decision))
        let fromReadiness = try CanonicalSemanticPeriodProjection(try #require(ready.projection))
        #expect(revision.canonicalProjection.bytes == fromReadiness.bytes)
        #expect(revision.projectionDigest == fromReadiness.digest)
    }

    // MARK: - ID1-ID6: metadata follows classification

    @Test("ID1: alreadyCurrent uses the metadata-free classification API")
    func alreadyCurrentClassificationNeedsNoMetadata() throws {
        let classify: (PeriodCheckpointReadiness, PeriodCheckpointStoredRead) -> CheckpointClosePolicyDecision =
            CheckpointClosePolicy.classify
        let read = PeriodCheckpointStoredRead.supported(try storedTip())
        #expect(isAlreadyCurrent(classify(try readiness(tip: read), read)))
    }

    @Test("ID2: a refusal uses the metadata-free classification API")
    func refusedClassificationNeedsNoMetadata() throws {
        let classify: (PeriodCheckpointReadiness, PeriodCheckpointStoredRead) -> CheckpointClosePolicyDecision =
            CheckpointClosePolicy.classify
        let ready = try readiness(exceptions: [exception("occurrence:rent", "200.00")])
        #expect(refusal(classify(ready, .empty)) == .readinessNotReady)
    }

    @Test("ID3: firstClose returns an opaque plan before identity or time is supplied")
    func firstCloseClassificationNeedsNoMetadata() throws {
        let decision = CheckpointClosePolicy.classify(
            currentReadiness: try readiness(), currentChainTip: .empty
        )
        guard case let .firstClose(plan) = decision else {
            Issue.record("expected a first-close plan")
            return
        }
        let _: CheckpointClosePolicy.AppendPlan = plan
    }

    @Test("ID4: reverify returns an opaque plan before identity or time is supplied")
    func reverifyClassificationNeedsNoMetadata() throws {
        let read = PeriodCheckpointStoredRead.supported(try storedTip(spendingMinor: 11_111))
        let decision = CheckpointClosePolicy.classify(
            currentReadiness: try readiness(tip: read), currentChainTip: read
        )
        guard case let .reverify(plan) = decision else {
            Issue.record("expected a reverify plan")
            return
        }
        let _: CheckpointClosePolicy.AppendPlan = plan
    }

    @Test("ID5: first-close materialization uses identity and time supplied after the plan")
    func firstCloseMaterializesWithLaterMetadata() throws {
        let ready = try readiness()
        guard case let .firstClose(plan) = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: .empty
        ) else { Issue.record("expected a first-close plan"); return }

        let supplied = CheckpointAppendIdentity(
            candidateID: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
            closedAt: Date(timeIntervalSinceReferenceDate: 777_777_777)
        )
        guard case let .candidate(revision) = CheckpointClosePolicy.materialize(plan: plan, identity: supplied)
        else { Issue.record("expected a materialized revision"); return }
        #expect(revision.id == supplied.candidateID)
        #expect(revision.closedAt == supplied.closedAt)
        #expect(revision.revisionNumber == 1)
        #expect(revision.predecessorID == nil)
        #expect(revision.canonicalProjection.bytes == (try CanonicalSemanticPeriodProjection(#require(ready.projection))).bytes)
    }

    @Test("ID6: reverify materialization uses later metadata and the planned chain position")
    func reverifyMaterializesWithLaterMetadata() throws {
        let tip = try storedTip(revisionNumber: 7, predecessorID: UUID(), spendingMinor: 11_111)
        let read = PeriodCheckpointStoredRead.supported(tip)
        let ready = try readiness(tip: read)
        guard case let .reverify(plan) = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: read
        ) else { Issue.record("expected a reverify plan"); return }

        let supplied = CheckpointAppendIdentity(
            candidateID: UUID(uuidString: "87654321-4321-4321-4321-CBA987654321")!,
            closedAt: Date(timeIntervalSinceReferenceDate: 888_888_888)
        )
        guard case let .candidate(revision) = CheckpointClosePolicy.materialize(plan: plan, identity: supplied)
        else { Issue.record("expected a materialized revision"); return }
        #expect(revision.id == supplied.candidateID)
        #expect(revision.closedAt == supplied.closedAt)
        #expect(revision.revisionNumber == 8)
        #expect(revision.predecessorID == tip.id)
        #expect(revision.canonicalProjection.bytes == (try CanonicalSemanticPeriodProjection(#require(ready.projection))).bytes)
    }

    @Test("Materialization fails closed on invalid identity or time after a valid plan")
    func materializationRefusesInvalidMetadata() throws {
        let tip = try storedTip(spendingMinor: 11_111)
        let read = PeriodCheckpointStoredRead.supported(tip)
        guard case let .reverify(plan) = CheckpointClosePolicy.classify(
            currentReadiness: try readiness(tip: read), currentChainTip: read
        ) else { Issue.record("expected a reverify plan"); return }

        for supplied in [
            CheckpointAppendIdentity(candidateID: tip.id, closedAt: closedAt),
            CheckpointAppendIdentity(candidateID: candidateID, closedAt: Date(timeIntervalSinceReferenceDate: .nan)),
        ] {
            guard case let .refused(reason) = CheckpointClosePolicy.materialize(plan: plan, identity: supplied)
            else { Issue.record("invalid metadata must not materialize"); continue }
            #expect(reason == .revisionConstructionRefused)
        }
    }

    @Test("Overflow refuses during metadata-free classification; an unchanged max tip remains a no-op")
    func overflowIsResolvedBeforeMetadata() throws {
        for spending in [Int64(11_111), Int64(12_345)] {
            let read = PeriodCheckpointStoredRead.supported(try storedTip(
                revisionNumber: .max, predecessorID: UUID(), spendingMinor: spending
            ))
            let decision = CheckpointClosePolicy.classify(
                currentReadiness: try readiness(tip: read), currentChainTip: read
            )
            if spending == 11_111 {
                #expect(refusal(decision) == .revisionNumberUnrepresentable)
            } else {
                #expect(isAlreadyCurrent(decision))
            }
        }
    }

    // MARK: - A1-A5: acknowledgments

    @Test("A1: acknowledged subjects survive into the candidate exactly")
    func acknowledgedSubjectsSurvive() throws {
        let carried = [
            exception("occurrence:rent", "200.00"),
            PeriodCheckpointException(
                id: "uncategorized:2026-08", kind: .uncategorizedEconomicSpending,
                day: day("2026-08-31"), amount: euro("18.00")
            ),
        ]
        let ready = try readiness(
            exceptions: carried, confirmed: try confirm(carried, carrying: carried)
        )
        let decision = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: .empty
        )
        let revision = try #require(appended(decision))

        // Whole values, not identifiers: the same subject the evaluator
        // partitioned, carried through unchanged.
        #expect(revision.acknowledgedExceptions.map(\.exception) == ready.acknowledgedExceptions)
        #expect(revision.safeClaims == ready.safeClaims)
    }

    @Test("A2: stale confirmed authority blocks, and blocks the close with it")
    func staleAuthorityIsRefused() throws {
        let carried = [exception("occurrence:rent", "200.00")]
        let substituted = [exception("occurrence:rent", "250.00")]
        let authority = try confirm(substituted, carrying: substituted)

        // Authority for a subject this month no longer carries.
        let ready = try readiness(exceptions: carried, confirmed: authority)
        #expect(ready.blockers.contains { $0.kind == .confirmedAcknowledgmentSubjectMismatch })

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: .empty
        )
        #expect(refusal(decision) == .readinessNotReady)
        #expect(appended(decision) == nil)
    }

    @Test("A3: a partly decided month is refused, not partly closed")
    func partialDecisionIsRefused() throws {
        let carried = [exception("occurrence:rent", "200.00"), exception("occurrence:gym", "35.00")]
        let ready = try readiness(
            exceptions: carried, confirmed: try confirm([carried[0]], carrying: carried)
        )
        #expect(ready.disposition == .needsDecisions)
        #expect(ready.undecidedExceptions.count == 1)

        let decision = CheckpointClosePolicy.classify(
            currentReadiness: ready, currentChainTip: .empty
        )
        #expect(refusal(decision) == .readinessNotReady)
        #expect(appended(decision) == nil)
    }
}
