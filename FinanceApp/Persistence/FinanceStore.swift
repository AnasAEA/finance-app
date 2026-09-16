import Foundation
import SwiftData
import Observation
import FinanceCore

enum FinanceClockError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case currentDayUnavailable

    var description: String { "The current day could not be read. Try again." }
    var errorDescription: String? { description }
}

struct TrustedRuleProcessingResult: Equatable, Sendable {
    let evaluatedObservationCount: Int
    let appliedObservationIDs: [String]
    let ambiguousObservationIDs: [String]
    let failedObservationIDs: [String]

    static let empty = TrustedRuleProcessingResult(
        evaluatedObservationCount: 0,
        appliedObservationIDs: [],
        ambiguousObservationIDs: [],
        failedObservationIDs: []
    )
}

private struct TrustedAutomationObservationSignature: Equatable {
    let bindingID: String
    let provider: ExternalProvider
    let identity: ExternalObservationIdentity
    let status: ExternalObservationStatus
    let direction: ExternalCreditDebitIndicator
    let amount: Money
    let bookingDate: Day?
    let transactionDate: Day?
    let valueDate: Day?
    let derivedTransactionDate: Day?
    let structuredMerchantName: String?
    let bankTransactionCode: String?
    let bankTransactionSubCode: String?
    let providerEligibleForEconomicActual: Bool
    let resolution: ObservationResolutionState

    init(_ observation: ExternalObservation, resolution: ObservationResolutionState) {
        bindingID = observation.bindingID
        provider = observation.provider
        identity = observation.identity
        status = observation.status
        direction = observation.creditDebitIndicator
        amount = observation.amount
        bookingDate = observation.bookingDate
        transactionDate = observation.transactionDate
        valueDate = observation.valueDate
        derivedTransactionDate = observation.derivedTransactionDate
        structuredMerchantName = observation.structuredMerchantName
        bankTransactionCode = observation.bankTransactionCode
        bankTransactionSubCode = observation.bankTransactionSubCode
        providerEligibleForEconomicActual = observation.providerEligibleForEconomicActual
        self.resolution = resolution
    }
}

/// One atomically published snapshot evaluation. A successful context owns
/// the exact forecast value that produced its snapshot; attention may consume
/// that value but may never run a second forecast.
struct SnapshotEvaluationContext {
    enum Projection {
        case notRequired
        /// A test/preview facade supplied an already-mapped snapshot.
        case fixedSnapshot
        case success(ForecastResult)
        case failure
    }

    let snapshot: FinanceAppSnapshot
    let projection: Projection

    var forecast: ForecastResult? {
        guard case let .success(result) = projection else { return nil }
        return result
    }

    var safeToUseIsAvailable: Bool {
        switch projection {
        case .success, .fixedSnapshot: true
        case .notRequired, .failure: false
        }
    }

    var projectionFailed: Bool {
        if case .failure = projection { return true }
        return false
    }
}

/// The published snapshot retains its exact forecast. Fixed facade stores also
/// supply cached attention here; real stores compose live attention separately
/// from this snapshot, once per screen composition.
struct PublishedFinanceEvaluation {
    let snapshot: SnapshotEvaluationContext
    let attention: AttentionPresentation
}

/// SwiftUI's single financial boundary: document persistence and the one
/// authoritative forecast engine live behind this facade.
@Observable
@MainActor
final class FinanceStore: FinanceProviding {
    private(set) var publishedEvaluation: PublishedFinanceEvaluation
    var snapshotEvaluation: SnapshotEvaluationContext {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { return publishedEvaluation.snapshot }
        guard let day = civilToday() else {
            // Retain the last dated data, but never claim a current projection.
            return SnapshotEvaluationContext(snapshot: publishedEvaluation.snapshot.snapshot, projection: .failure)
        }
        if let cached = currentDayEvaluation, cached.day == day { return cached.evaluation }
        if DomainMapper.day(publishedEvaluation.snapshot.snapshot.asOf) == day {
            return publishedEvaluation.snapshot
        }
        let evaluation = makeSnapshotEvaluation(scenario: scenario)
        currentDayEvaluation = (day, evaluation)
        return evaluation
    }
    var attentionPresentation: AttentionPresentation { currentPresentation().attention }
    var snapshot: FinanceAppSnapshot { snapshotEvaluation.snapshot }
    var safeToUseIsAvailable: Bool { snapshotEvaluation.safeToUseIsAvailable }
    var snapshotProjectionFailed: Bool { snapshotEvaluation.projectionFailed }

    var scenario: PlanScenario = .base {
        didSet { recalculate() }
    }

    /// Retain the source: each later operation samples its own instant.
    private let clock: () -> Date
    /// Initialization provenance, never the real store's operational current day.
    let initialDay: CalendarDay
    let civilTimeZone: TimeZone
    @ObservationIgnored private var fixedDay: CalendarDay?

    private struct OperationDate {
        let instant: Date
        let day: Day?
    }
    // MainActor synchronous scopes only: never retained across an await. Nested
    // persistence/composition helpers share their initiating operation's sample.
    @ObservationIgnored private var operationDate: OperationDate?
    @ObservationIgnored private var currentDayEvaluation: (day: Day, evaluation: SnapshotEvaluationContext)?

    private func beginOperation(independent: Bool = false) -> OperationDate? {
        let previous = operationDate
        if previous == nil || independent {
            let instant = clock()
            let day: Day?
            if let fixedDay { day = DomainMapper.day(fixedDay) }
            else { day = DomainMapper.day(instant, in: civilTimeZone) }
            operationDate = OperationDate(instant: instant, day: day)
        }
        return previous
    }

    private func operationInstant() -> Date {
        operationDate?.instant ?? clock()
    }

    private func civilToday() -> Day? {
        if let operationDate { return operationDate.day }
        if let fixedDay { return DomainMapper.day(fixedDay) }
        return DomainMapper.day(clock(), in: civilTimeZone)
    }

    private func requireCivilToday() throws -> Day {
        guard let day = civilToday() else { throw FinanceClockError.currentDayUnavailable }
        return day
    }

    /// A cheap, checked current-day read. Fixed facades keep their supplied day.
    func currentDay() -> CalendarDay? { civilToday().map(DomainMapper.civilDay) }

    func affordabilityDefaults() -> (day: CalendarDay?, range: ClosedRange<Date>?) {
        let previous = beginOperation()
        defer { operationDate = previous }
        return (currentDay(), affordabilityDateRange())
    }

    func affordabilityDateRange() -> ClosedRange<Date>? {
        guard let day = civilToday(), let end = day.advanced(by: forecastHorizonDays - 1),
              let startDate = DomainMapper.date(day, in: civilTimeZone),
              let endDate = DomainMapper.date(end, in: civilTimeZone) else { return nil }
        return startDate...endDate
    }

    /// Private archive access is a separate facade. Its rows never enter
    /// `document`, forecasting or the operational snapshot.
    let history: HistoryArchiveService

    /// Durable local checkpoint revision history. Emptiness and import safety
    /// consult occupancy so a history that outlived its document cannot attach
    /// itself to a different imported dataset. The one production write is
    /// `EndedMonthCheckpointWriter`; this type does not call `store` itself.
    let checkpoints: PeriodCheckpointRepository

    private var document: FinanceDocument
    private var transactionPresentation: [String: DomainMapper.TransactionPresentation] = [:]

    /// Transaction id → budget category key: the store's one authoritative
    /// answer, read by the review request, the review's checkpoint and
    /// attention alike. Written once so the checkpoint cannot end up looking
    /// at a different categorisation from the budget it is checkpointing.
    var categoryKeysByTransaction: [String: String] {
        transactionPresentation.compactMapValues(\.categoryKey)
    }
    private var appMetadata: AppPersistenceMetadata = .empty
    private(set) var trustedAutomationEnabled = false
    private(set) var trustedAutomationDiagnostic: String?
    /// Set when the stored graph could not be read: corrupt rows, or a
    /// document schema this build does not support. The store then serves an
    /// empty plan **and refuses to write**, so an unreadable store is never
    /// overwritten by a fresh one on the next entry.
    private(set) var loadFailure: String?

    private let context: ModelContext?
    private let mapper = DomainMapper()
    private let forecastHorizonDays = 120
    private let safeToSpendWindowDays = 30
    @ObservationIgnored private var isFixed = false
    @ObservationIgnored private let writer: DocumentWriter
    @ObservationIgnored private let forecastRunner: (ForecastRequest) throws -> ForecastResult

    /// A document decoded and validated but not yet written. It exists only
    /// between the preview and the confirmation, and it is the reason those
    /// two are separate steps: the person sees what is in the file before any
    /// of it becomes the store.
    @ObservationIgnored private var pendingImport: FinanceDocument?

    /// The summary on screen while an import is being reviewed.
    private(set) var pendingImportPreview: ImportPreview?

    // MARK: - Live bank sync state
    //
    // Remote accounts and connections are read-through: they describe the
    // backend, not this person's finances, so they are never written into
    // `FinanceDocument` and an export stays portable without them.

    private(set) var bankSyncActivity: BankSyncActivity = .idle
    private(set) var remoteAccounts: [RemoteAccountSummary] = []
    private(set) var remoteConnections: [RemoteConnectionSummary] = []
    private(set) var pairingState: BankPairingState = .notConfigured

    /// One freshness answer for every product surface. Views do not re-derive
    /// connection relevance or choose their own fallback timestamp.
    /// State and caption are derived from one elapsed-time reference.
    func freshnessEvaluation() -> BankFreshnessEvaluation {
        let previous = beginOperation()
        defer { operationDate = previous }
        let reference = operationInstant()
        return BankFreshnessEvaluation(state: BankFreshness.evaluate(
            snapshot: snapshot, activity: bankSyncActivity,
            pairing: pairingState, reference: reference
        ), reference: reference)
    }

    /// Reuses the day's forecast. Crossing a civil day recomputes it once;
    /// freshness and attention share this composition's instant and civil day.
    func currentPresentation() -> (snapshot: FinanceAppSnapshot, projectionFailed: Bool, attention: AttentionPresentation, freshness: BankFreshnessEvaluation) {
        let previous = beginOperation()
        defer { operationDate = previous }
        let reference = operationInstant()
        let evaluation = snapshotEvaluation
        let freshness = BankFreshnessEvaluation(state: BankFreshness.evaluate(
            snapshot: evaluation.snapshot, activity: bankSyncActivity,
            pairing: pairingState, reference: reference
        ), reference: reference)
        let attention = isFixed ? publishedEvaluation.attention
            : makeAttentionPresentation(from: evaluation, freshness: freshness.state)
        return (evaluation.snapshot, evaluation.projectionFailed, attention, freshness)
    }

    var bankFreshness: BankFreshness { freshnessEvaluation().state }

    @ObservationIgnored let identityStore: DeviceIdentityStore

    /// `unavailableReason` names why there is no store to write to, when the
    /// app knows. A store that cannot be written must not look like a store
    /// with nothing in it: without this, an import would validate, preview,
    /// report its counts and keep none of it.
    init(
        context: ModelContext?,
        clock: @escaping () -> Date = Date.init,
        timeZone: TimeZone = .current,
        forecastRunner: @escaping (ForecastRequest) throws -> ForecastResult = ForecastEngine.run,
        writer: DocumentWriter = .live,
        identityStore: DeviceIdentityStore = .init(),
        unavailableReason: String? = nil
    ) throws {
        let instant = clock()
        guard let day = DomainMapper.day(instant, in: timeZone) else {
            throw FinanceClockError.currentDayUnavailable
        }
        self.context = context
        self.history = HistoryArchiveService(context: context, now: clock)
        self.checkpoints = PeriodCheckpointRepository(context: context, now: clock)
        self.clock = clock
        self.initialDay = DomainMapper.civilDay(day)
        self.civilTimeZone = timeZone
        self.writer = writer
        self.forecastRunner = forecastRunner
        self.identityStore = identityStore
        self.document = Self.emptyDocument()
        self.publishedEvaluation = PublishedFinanceEvaluation(
            snapshot: SnapshotEvaluationContext(
                snapshot: .empty(asOf: DomainMapper.civilDay(day)), projection: .notRequired
            ),
            attention: .initial()
        )
        self.loadFailure = unavailableReason
        operationDate = OperationDate(instant: instant, day: day)
        load()
        operationDate = nil
        pairingState = Self.initialPairingState(identityStore)
    }

    convenience init(
        context: ModelContext?, now: Date,
        writer: DocumentWriter = .live,
        identityStore: DeviceIdentityStore = .init(),
        unavailableReason: String? = nil
    ) throws {
        try self.init(context: context, clock: { now }, writer: writer,
                      identityStore: identityStore, unavailableReason: unavailableReason)
    }

    /// Configuration decides whether pairing is even offered; the Keychain
    /// decides whether it has already happened.
    private static func initialPairingState(_ store: DeviceIdentityStore) -> BankPairingState {
        guard BankSyncConfiguration.baseURL() != nil else { return .notConfigured }
        return store.pairedDeviceID == nil ? .unpaired : .paired
    }

    /// A store that serves product-shaped values without FinanceCore. UI tests
    /// and previews can prove the facade boundary with this initializer.
    init(snapshot: FinanceAppSnapshot, now: Date = Date()) {
        context = nil
        history = HistoryArchiveService(context: nil)
        checkpoints = PeriodCheckpointRepository(context: nil)
        writer = .live
        forecastRunner = ForecastEngine.run
        identityStore = DeviceIdentityStore()
        self.clock = { now }
        initialDay = snapshot.asOf
        fixedDay = snapshot.asOf
        civilTimeZone = .current
        document = Self.emptyDocument()
        appMetadata = .empty
        isFixed = true
        self.publishedEvaluation = PublishedFinanceEvaluation(
            snapshot: SnapshotEvaluationContext(
                snapshot: snapshot, projection: .fixedSnapshot
            ),
            attention: .initial(heroIsAvailable: true)
        )
        scenario = snapshot.scenario
    }

    init(
        document: FinanceDocument,
        today: Day,
        now: Date = Date(),
        scenario: PlanScenario,
        transactionPresentation: [String: DomainMapper.TransactionPresentation] = [:],
        appMetadata: AppPersistenceMetadata = .empty,
        forecastRunner: @escaping (ForecastRequest) throws -> ForecastResult = ForecastEngine.run
    ) {
        context = nil
        history = HistoryArchiveService(context: nil)
        checkpoints = PeriodCheckpointRepository(context: nil)
        writer = .live
        self.forecastRunner = forecastRunner
        identityStore = DeviceIdentityStore()
        self.clock = { now }
        self.initialDay = DomainMapper.civilDay(today)
        self.fixedDay = DomainMapper.civilDay(today)
        self.civilTimeZone = .current
        self.document = document
        self.transactionPresentation = transactionPresentation
        self.appMetadata = appMetadata
        trustedAutomationEnabled = appMetadata.trustedAutomationEnabled
        publishedEvaluation = PublishedFinanceEvaluation(
            snapshot: SnapshotEvaluationContext(
                snapshot: .empty(asOf: DomainMapper.civilDay(today)), projection: .notRequired
            ),
            attention: .initial()
        )
        self.scenario = scenario
    }

    /// The hardened shared fixture is explicit preview/development data. The
    /// production initializer never calls this and never seeds fictional
    /// history on first launch.
    ///
    /// The fixture is excluded from the Release bundle, so this falls back to
    /// an empty document rather than trapping if it is ever reached from a
    /// Release build.
    static func preview(scenario: PlanScenario = .base) -> FinanceStore {
        let document = (try? developmentFixture()) ?? Self.emptyDocument()
        return FinanceStore(
            document: document,
            today: Day(year: 2027, month: 3, day: 1),
            scenario: scenario
        )
    }

    #if DEBUG
    /// Synthetic planning rows for Plan visual checks. Compiled out of Release
    /// and never written to a production store.
    static func planningPreview() -> FinanceStore {
        guard var document = try? developmentFixture() else { return preview() }
        let today = Day(year: 2027, month: 3, day: 1)
        let euro: (Int64) -> Money = { Money(minorUnits: $0, currency: .eur) }
        let dedicatedID = document.accounts.first { account in
            account.currency == .eur && account.kind == .bank
        }?.id
        document.planning.sinkingFunds = [
            SinkingFund(
                id: "sf-camera", name: "Camera",
                targetAmount: euro(40_000), reservedAmount: euro(12_000)
            ),
            SinkingFund(
                id: "sf-bike", name: "Bike",
                targetAmount: euro(90_000), reservedAmount: euro(20_000),
                custody: dedicatedID.map { .dedicatedAccount(accountID: $0) } ?? .virtualReservation
            )
        ]
        document.planning.plannedPurchases = [
            PlannedPurchase(
                id: "goal-wishlist", name: "Headphones",
                targetAmount: euro(8_000), status: .planned,
                requirement: .euroBankPayment()
            ),
            PlannedPurchase(
                id: "goal-camera", name: "Camera",
                targetAmount: euro(40_000), status: .reserved,
                funding: .sinkingFund(id: "sf-camera"),
                requirement: .euroBankPayment()
            ),
            PlannedPurchase(
                id: "goal-bike", name: "Bike",
                targetAmount: euro(90_000), status: .reserved,
                funding: .sinkingFund(id: "sf-bike"),
                requirement: .euroBankPayment()
            )
        ]
        return FinanceStore(document: document, today: today, scenario: .base)
    }

    /// Empty production Plan, in memory. Compiled out of Release and never
    /// written to a production store.
    static func emptyPreview() -> FinanceStore {
        FinanceStore(
            document: emptyDocument(),
            today: Day(year: 2027, month: 3, day: 1),
            scenario: .base
        )
    }
    #endif

    /// Debug-only visual-validation state for the daily-use slice. It derives
    /// from the excluded sample fixture and never touches the production store
    /// or the Release bundle.
    static func dailyUsePreview() -> FinanceStore {
        guard var document = try? developmentFixture() else { return preview() }
        let day = Day(year: 2027, month: 2, day: 27)
        let potID = document.incomeSources.first?.id
        let transactions: [Transaction] = [
            Transaction(
                id: "preview-groceries", date: day, kind: .expense,
                legs: [AccountLeg(accountID: "card-wallet", amount: Money(minorUnits: -1_840, currency: .eur))],
                factivity: .observed, lifecycle: .cleared,
                provenance: Provenance(source: "DEV-PREVIEW", evidenceGrade: .userConfirmed)
            ),
            Transaction(
                id: "preview-bakery", date: day, kind: .expense,
                legs: [AccountLeg(accountID: "bank-main", amount: Money(minorUnits: -650, currency: .eur))],
                factivity: .observed, lifecycle: .cleared,
                provenance: Provenance(source: "DEV-PREVIEW", evidenceGrade: .userConfirmed)
            ),
            Transaction(
                id: "preview-financing", date: day, kind: .financingRepayment,
                legs: [AccountLeg(accountID: "online-wallet", amount: Money(minorUnits: -4_000, currency: .eur))],
                factivity: .observed, lifecycle: .cleared,
                provenance: Provenance(source: "DEV-PREVIEW", evidenceGrade: .userConfirmed)
            ),
            Transaction(
                id: "preview-inflow", date: day, kind: .income,
                legs: [AccountLeg(accountID: "bank-main", amount: Money(minorUnits: 40_000, currency: .eur))],
                incomeSourceID: potID,
                factivity: .observed, lifecycle: .cleared,
                provenance: Provenance(source: "DEV-PREVIEW", evidenceGrade: .userConfirmed)
            ),
            Transaction(
                id: "preview-transfer", date: day, kind: .transfer,
                legs: [
                    AccountLeg(accountID: "bank-main", amount: Money(minorUnits: -5_000, currency: .eur)),
                    AccountLeg(accountID: "card-wallet", amount: Money(minorUnits: 5_000, currency: .eur))
                ],
                factivity: .observed, lifecycle: .cleared,
                provenance: Provenance(source: "DEV-PREVIEW", evidenceGrade: .userConfirmed)
            )
        ]
        document.transactions.append(contentsOf: transactions)
        let presentation: [String: DomainMapper.TransactionPresentation] = [
            "preview-groceries": .init(categoryKey: "food", merchant: "Corner Market"),
            "preview-bakery": .init(categoryKey: "food", merchant: "Bakery"),
            "preview-financing": .init(categoryKey: nil, merchant: "Headphones instalment"),
            "preview-inflow": .init(categoryKey: "income", merchant: "Trip pot share")
        ]
        return FinanceStore(
            document: document,
            today: Day(year: 2027, month: 3, day: 1),
            scenario: .base,
            transactionPresentation: presentation,
            appMetadata: AppPersistenceMetadata(
                incomeSourceActive: Dictionary(
                    uniqueKeysWithValues: document.incomeSources.map { ($0.id, true) }
                )
            )
        )
    }

    #if DEBUG
    /// Synthetic Phase 2.4C state. Compiled out of Release; it contains no
    /// production provider payload, account identity or credential.
    static func bankInboxPreview() -> FinanceStore {
        guard var document = try? developmentFixture() else { return preview() }
        document.schemaVersion = Interchange.currentSchemaVersion
        guard let observed = DomainMapper.date(Day(year: 2027, month: 3, day: 6)) else { return preview() }
        let boundary = Day(year: 2027, month: 3, day: 1)
        document.planning.recurringObligations.append(
            RecurringObligation(
                id: "ob-synthetic-streaming",
                name: "Streaming membership",
                amount: Money(minorUnits: 349, currency: .eur),
                spec: .monthly(onDay: 4, from: MonthKey(year: 2027, month: 3), through: nil),
                requirement: .euroBankPayment(rails: [.cardDebit]),
                spendingClass: .optional
            )
        )
        document.externalAccountBindings = [
            ExternalAccountBinding(
                id: "binding-bank", provider: .bnp,
                remoteOpaqueAccountID: "acct_bank",
                localAccountID: "bank-main", syncStartBoundary: boundary, createdAt: observed
            ),
            ExternalAccountBinding(
                id: "binding-wallet", provider: .paypal,
                remoteOpaqueAccountID: "acct_wallet",
                localAccountID: "online-wallet", syncStartBoundary: boundary, createdAt: observed
            ),
            ExternalAccountBinding(
                id: "binding-revolut", provider: .revolut,
                remoteOpaqueAccountID: "acct_neobank_eur",
                localAccountID: "card-wallet", syncStartBoundary: boundary, createdAt: observed
            )
        ]

        func observation(
            _ id: String,
            binding: String,
            provider: ExternalProvider,
            amount: Int64,
            day: Int,
            merchant: String? = nil,
            raw: String? = nil,
            code: String? = nil,
            transactionDate: Bool = false,
            status: ExternalObservationStatus = .booked,
            identity: ExternalObservationIdentity = .durable,
            eligible: Bool = true
        ) -> ExternalObservation {
            let date = Day(year: 2027, month: 3, day: day)
            return ExternalObservation(
                id: id,
                bindingID: binding,
                provider: provider,
                identity: identity,
                status: status,
                creditDebitIndicator: amount < 0 ? .debit : .credit,
                amount: Money(minorUnits: amount, currency: .eur),
                bookingDate: transactionDate ? nil : date,
                transactionDate: transactionDate ? date : nil,
                valueDate: provider == .revolut ? date : nil,
                rawMerchantText: raw,
                structuredMerchantName: merchant,
                remittance: raw,
                bankTransactionCode: code,
                eligibleForEconomicActual: eligible,
                observedAt: observed
            )
        }

        let observations = [
            observation(
                "obs-streaming", binding: "binding-bank", provider: .bnp,
                amount: -349, day: 4, raw: "STREAMING MEMBERSHIP"
            ),
            observation(
                "obs-atm", binding: "binding-revolut", provider: .revolut,
                amount: -3_000, day: 5, raw: "CASH MACHINE", code: "ATM"
            ),
            observation(
                "obs-paypal-unresolved", binding: "binding-bank", provider: .bnp,
                amount: -799, day: 5, raw: "PAYPAL EUROPE"
            ),
            observation(
                "obs-bank-merchant", binding: "binding-bank", provider: .bnp,
                amount: -799, day: 3, raw: "PAYPAL EUROPE"
            ),
            observation(
                "obs-wallet-merchant", binding: "binding-wallet", provider: .paypal,
                amount: -799, day: 2, merchant: "Google Payment Ireland",
                transactionDate: true
            ),
            observation(
                "obs-resolved", binding: "binding-revolut", provider: .revolut,
                amount: -250, day: 2, raw: "VERIFICATION", code: "TRANSFER"
            ),
            observation(
                "pending-snapshot", binding: "binding-bank", provider: .bnp,
                amount: 0, day: 6, raw: "PENDING CARD",
                status: .pending, identity: .provisionalSnapshot, eligible: false
            ),
            observation(
                "pending-zero", binding: "binding-bank", provider: .bnp,
                amount: 0, day: 5, raw: "PENDING PAYMENT",
                status: .pending, identity: .provisionalSnapshot, eligible: false
            ),
            observation(
                "pending-third", binding: "binding-bank", provider: .bnp,
                amount: 0, day: 4, raw: nil,
                status: .pending, identity: .provisionalSnapshot, eligible: false
            ),
            observation(
                "obs-rejected", binding: "binding-wallet", provider: .paypal,
                amount: -999, day: 6, merchant: "Rejected merchant",
                transactionDate: true, status: .rejected, eligible: false
            ),
            observation(
                "obs-before-cutover", binding: "binding-bank", provider: .bnp,
                amount: -100, day: 1, raw: "OPENING-DAY HISTORY"
            )
        ]
        let balances = [
            ProviderBalanceSnapshot(
                id: "balance-bank-clbd", bindingID: "binding-bank", provider: .bnp,
                balanceType: "CLBD", amount: Money(minorUnits: 36_456, currency: .eur),
                referenceDate: Day(year: 2027, month: 3, day: 6), observedAt: observed
            ),
            ProviderBalanceSnapshot(
                id: "balance-bank-xpcd", bindingID: "binding-bank", provider: .bnp,
                balanceType: "XPCD", amount: Money(minorUnits: 36_706, currency: .eur),
                referenceDate: Day(year: 2027, month: 3, day: 6), observedAt: observed
            )
        ]
        let candidates = [
            CrossProviderCandidate(
                id: "candidate-unique", bankObservationID: "obs-bank-merchant",
                walletObservationID: "obs-wallet-merchant", state: .unique,
                candidateCount: 1, amount: Money(minorUnits: 799, currency: .eur),
                dayOffset: -1, rule: "synthetic_same_amount_window", computedAt: observed
            ),
            CrossProviderCandidate(
                id: "candidate-ambiguous", bankObservationID: "obs-paypal-unresolved",
                walletObservationID: nil, state: .ambiguous,
                candidateCount: 2, amount: Money(minorUnits: 799, currency: .eur),
                rule: "synthetic_same_amount_window", computedAt: observed
            )
        ]
        try? ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: observations, balances: balances, candidates: candidates),
            into: &document
        )
        try? ExternalEvidenceReview.markNoEconomicEffect(
            observationID: "obs-resolved", resolvedAt: observed, in: &document
        )
        return FinanceStore(
            document: document,
            today: Day(year: 2027, month: 3, day: 6),
            scenario: .base,
            appMetadata: AppPersistenceMetadata(
                authoritativePendingSnapshots: [
                    .bnp: AuthoritativePendingSnapshot(
                        authoritativeAt: observed,
                        observationIDs: ["pending-snapshot", "pending-zero", "pending-third"]
                    ),
                    .paypal: AuthoritativePendingSnapshot(
                        authoritativeAt: observed,
                        observationIDs: []
                    ),
                    .revolut: AuthoritativePendingSnapshot(
                        authoritativeAt: observed,
                        observationIDs: []
                    ),
                ],
                // Coverage the synthetic backend would have established for
                // the three mapped accounts. Without it the fixture can only
                // ever show the fail-closed state, which would hide the rest
                // of the review from visual validation.
                authoritativeLiveCoverage: Dictionary(
                    uniqueKeysWithValues: [
                        ("acct_bank", ExternalProvider.bnp, "bank-main"),
                        ("acct_wallet", ExternalProvider.paypal, "online-wallet"),
                        ("acct_neobank_eur", ExternalProvider.revolut, "card-wallet"),
                    ].map { remote, provider, local in
                        (
                            remote,
                            AuthoritativeLiveCoverage(
                                provider: provider,
                                remoteOpaqueAccountID: remote,
                                localAccountID: local,
                                syncedFrom: Day(year: 2026, month: 12, day: 8),
                                syncedThrough: Day(year: 2027, month: 3, day: 6),
                                authoritativeAt: observed
                            )
                        )
                    }
                )
            )
        )
    }

    /// Synthetic Phase 2.4D state for visual validation.
    ///
    /// Builds on the Bank Inbox fixture and adds a backend directory: three
    /// connections in three different consent states, the three mapped
    /// accounts, and four dormant pockets nobody mapped. No network, no real
    /// device pairing, no production identifier.
    static func bankSyncPreview(
        pairing: BankPairingState = .paired,
        activity: BankSyncActivity = .idle
    ) -> FinanceStore {
        let store = bankInboxPreview()
        guard let observed = DomainMapper.date(Day(year: 2027, month: 3, day: 6)) else { return preview() }
        store.pairingState = pairing
        store.bankSyncActivity = activity
        store.remoteConnections = [
            RemoteConnectionSummary(
                id: "conn-bank", provider: .bnp, institution: "Synthetic Bank",
                status: "connected", validUntil: Day(year: 2027, month: 8, day: 24),
                lastSuccessfulSyncAt: observed, lastErrorCode: nil
            ),
            RemoteConnectionSummary(
                id: "conn-wallet", provider: .paypal, institution: "Synthetic Wallet",
                status: "expiringSoon", validUntil: Day(year: 2027, month: 3, day: 14),
                lastSuccessfulSyncAt: observed, lastErrorCode: nil
            ),
            RemoteConnectionSummary(
                id: "conn-neobank", provider: .revolut, institution: "Synthetic Neobank",
                status: "reauthorizationRequired", validUntil: Day(year: 2027, month: 3, day: 1),
                lastSuccessfulSyncAt: nil, lastErrorCode: "SESSION_EXPIRED"
            )
        ]
        store.remoteAccounts = [
            RemoteAccountSummary(
                id: "acct_bank", provider: .bnp, displayName: "Current account",
                product: "Compte", cashAccountType: "CACC", currencyCode: "EUR",
                syncedFrom: nil, syncedThrough: nil
            ),
            RemoteAccountSummary(
                id: "acct_wallet", provider: .paypal, displayName: "Wallet balance",
                product: nil, cashAccountType: nil, currencyCode: "EUR",
                syncedFrom: nil, syncedThrough: nil
            ),
            RemoteAccountSummary(
                id: "acct_neobank_eur", provider: .revolut, displayName: "Neobank EUR",
                product: nil, cashAccountType: "CACC", currencyCode: "EUR",
                syncedFrom: nil, syncedThrough: nil
            ),
            RemoteAccountSummary(
                id: "acct_neobank_mad", provider: .revolut, displayName: "Neobank MAD",
                product: nil, cashAccountType: nil, currencyCode: "MAD",
                syncedFrom: nil, syncedThrough: nil
            ),
            RemoteAccountSummary(
                id: "acct_neobank_chf", provider: .revolut, displayName: "Neobank CHF",
                product: nil, cashAccountType: nil, currencyCode: "CHF",
                syncedFrom: nil, syncedThrough: nil
            )
        ]
        store.recalculate()
        return store
    }

    /// Debug-only Concept B+ HCI prototype. Compiled out of Release.
    static func hciPrototypePreview(variant: String = "full") -> FinanceStore {
        switch variant {
        case "positive": return hciPositivePreview()
        case "healthySync": return hciHealthySyncPreview()
        case "emptyGoals": return bankSyncPreview()
        case "emptyReview": return planningPreview()
        case "needsReviewOnly": return hciNeedsReviewOnlyPreview()
        case "pendingOnly": return hciPendingOnlyPreview()
        case "aggregateConflict": return hciAggregateConflictPreview()
        case "exactExisting": return hciExactExistingPreview()
        case "projectionFailure": return hciProjectionFailurePreview()
        default: return hciFullPreview()
        }
    }

    /// Shortfall, goals, To Review queue, and bank connections together.
    private static func hciFullPreview() -> FinanceStore {
        let store = bankSyncPreview()
        applyPlanningPreviewState(to: &store.document)
        store.document.note = "HCIPrototypeNeedsReviewQueue"
        store.recalculate()
        return store
    }

    /// The projection genuinely fails while the document stays populated.
    ///
    /// The failure is injected at the one authoritative seam — the forecast
    /// runner — so the store takes its real unavailable path. Nothing about
    /// the presentation is mocked: this is the only honest way to rehearse
    /// what a person sees when today's figure cannot be established.
    private static func hciProjectionFailurePreview() -> FinanceStore {
        let source = hciFullPreview()
        guard let sourceDay = source.civilToday() else { return source }
        let store = FinanceStore(
            document: source.document,
            today: sourceDay,
            now: source.clock(),
            scenario: .base
        ) { _ in throw ForecastError.emptyHorizon }
        store.transactionPresentation = source.transactionPresentation
        store.appMetadata = source.appMetadata
        store.pairingState = source.pairingState
        store.bankSyncActivity = source.bankSyncActivity
        store.remoteConnections = source.remoteConnections
        store.recalculate()
        return store
    }

    private static func hciNeedsReviewOnlyPreview() -> FinanceStore {
        let store = bankSyncPreview()
        store.appMetadata.authoritativePendingSnapshots = [:]
        store.recalculate()
        return store
    }

    private static func hciPendingOnlyPreview() -> FinanceStore {
        let store = bankSyncPreview()
        let resolvedAt = store.clock()
        for index in store.document.observationResolutions.indices where
            store.document.observationResolutions[index].state == .unreviewed {
            store.document.observationResolutions[index].state = .noEconomicEffect
            store.document.observationResolutions[index].resolvedAt = resolvedAt
        }
        store.recalculate()
        return store
    }

    /// Two existing signed account legs sum to one provider observation. The
    /// fixture exercises the warning/override path without inventing a link.
    private static func hciAggregateConflictPreview() -> FinanceStore {
        let store = bankSyncPreview()
        let day = Day(year: 2027, month: 3, day: 5)
        let rows = [
            Transaction(
                id: "hci-aggregate-a", date: day, kind: .financingRepayment,
                legs: [AccountLeg(
                    accountID: "bank-main",
                    amount: Money(minorUnits: -400, currency: .eur)
                )],
                factivity: .observed, lifecycle: .cleared
            ),
            Transaction(
                id: "hci-aggregate-b", date: day, kind: .financingRepayment,
                legs: [AccountLeg(
                    accountID: "bank-main",
                    amount: Money(minorUnits: -399, currency: .eur)
                )],
                factivity: .observed, lifecycle: .cleared
            ),
        ]
        store.document.transactions.append(contentsOf: rows)
        store.transactionPresentation["hci-aggregate-a"] = .init(
            categoryKey: nil, merchant: "First recorded repayment"
        )
        store.transactionPresentation["hci-aggregate-b"] = .init(
            categoryKey: nil, merchant: "Second recorded repayment"
        )
        store.recalculate()
        return store
    }

    /// Exact same-account amount/date candidate for the preferred Match
    /// Existing action.
    private static func hciExactExistingPreview() -> FinanceStore {
        let store = bankSyncPreview()
        store.document.transactions.append(
            Transaction(
                id: "hci-exact-existing",
                date: Day(year: 2027, month: 3, day: 4),
                kind: .expense,
                legs: [AccountLeg(
                    accountID: "bank-main",
                    amount: Money(minorUnits: -349, currency: .eur)
                )],
                factivity: .observed,
                lifecycle: .cleared
            )
        )
        store.transactionPresentation["hci-exact-existing"] = .init(
            categoryKey: nil, merchant: "Recorded membership"
        )
        store.recalculate()
        return store
    }

    /// A current, successful provider state for the quiet Home freshness
    /// caption. The synthetic connection and timestamp already come from the
    /// bank-sync preview; this variant simply removes its deliberate failure
    /// cases.
    private static func hciHealthySyncPreview() -> FinanceStore {
        let store = bankSyncPreview()
        store.remoteConnections = Array(store.remoteConnections.prefix(1))
        store.recalculate()
        return store
    }

    /// Positive safe-to-spend, goals, no To Review items.
    private static func hciPositivePreview() -> FinanceStore {
        let today = Day(year: 2027, month: 3, day: 1)
        let euro: (Int64) -> Money = { Money(minorUnits: $0, currency: .eur) }
        let bank = Account(
            id: "hci-proto-bank-eur",
            name: "Current account",
            currency: .eur,
            kind: .bank,
            supportedRails: PaymentRail.euroBankRails
        )
        var document = emptyDocument()
        document.documentKind = "HCI-PROTOTYPE-FIXTURE"
        document.note = "HCIPrototypeNeedsReviewQueue unused"
        document.accounts = [bank]
        document.balances = [
            AccountBalance(accountID: bank.id, balance: euro(250_000), asOf: today)
        ]
        document.planning.monthlyEconomicCeiling = euro(70_000)
        document.planning.budgets = [
            BudgetAllocation(
                id: "hci-everyday",
                name: "Everyday",
                spendingClass: .flexible,
                monthlyAmount: euro(8_500),
                effectiveFrom: MonthKey(year: 2027, month: 3),
                confirmation: .userConfirmed,
                categoryKeys: ["groceries"]
            )
        ]
        document.planning.recurringObligations = [
            RecurringObligation(
                id: "hci-phone",
                name: "Phone plan",
                amount: euro(1_500),
                spec: .monthly(onDay: 7, from: MonthKey(year: 2027, month: 3), through: nil),
                requirement: .euroBankPayment(rails: [.cardDebit]),
                spendingClass: .optional
            )
        ]
        applyPlanningPreviewState(to: &document, dedicatedAccountID: bank.id)
        document.planning.plannedPurchases.removeAll { $0.id == "goal-bike" }
        document.planning.sinkingFunds.removeAll { $0.id == "sf-bike" }
        return FinanceStore(document: document, today: today, scenario: .base)
    }

    private static func applyPlanningPreviewState(
        to document: inout FinanceDocument,
        dedicatedAccountID: String? = nil
    ) {
        let euro: (Int64) -> Money = { Money(minorUnits: $0, currency: .eur) }
        let dedicatedID = dedicatedAccountID ?? document.accounts.first {
            $0.currency == .eur && $0.kind == .bank
        }?.id
        document.planning.sinkingFunds = [
            SinkingFund(
                id: "sf-camera", name: "Camera",
                targetAmount: euro(40_000), reservedAmount: euro(12_000)
            ),
            SinkingFund(
                id: "sf-bike", name: "Bike",
                targetAmount: euro(90_000), reservedAmount: euro(20_000),
                custody: dedicatedID.map { .dedicatedAccount(accountID: $0) } ?? .virtualReservation
            )
        ]
        document.planning.plannedPurchases = [
            PlannedPurchase(
                id: "goal-wishlist", name: "Headphones",
                targetAmount: euro(8_000), status: .planned,
                requirement: .euroBankPayment()
            ),
            PlannedPurchase(
                id: "goal-camera", name: "Camera",
                targetAmount: euro(40_000), status: .reserved,
                funding: .sinkingFund(id: "sf-camera"),
                requirement: .euroBankPayment()
            ),
            PlannedPurchase(
                id: "goal-bike", name: "Bike",
                targetAmount: euro(90_000), status: .reserved,
                funding: .sinkingFund(id: "sf-bike"),
                requirement: .euroBankPayment()
            )
        ]
    }
    #endif

    // MARK: - What the store is holding

    /// True when nothing has been entered or imported yet.
    ///
    /// Emptiness is a property of the whole document, not of the account list:
    /// a store with no accounts but a saved commitment is not a fresh install,
    /// and offering to replace it wholesale would lose that commitment.
    var isEmpty: Bool {
        // A fixed store has no document — its snapshot *is* its truth, and a
        // hand-built one full of accounts is not a fresh install.
        if isFixed { return snapshot.accounts.isEmpty && snapshot.trackedHoldings.isEmpty }
        guard documentIsEmpty else { return false }
        // Checkpoint history survives every document replace by design, so a
        // store whose document was emptied can still hold accepted closes of
        // periods that belonged to it. Letting an import land on top of them
        // would attach one dataset's closes to another dataset's money.
        // Metadata that cannot be read as a coherent whole fails closed here
        // too: unreadable is not empty.
        return checkpoints.occupancy() == .empty
    }

    /// Emptiness of the ledger alone, without the local metadata beside it.
    private var documentIsEmpty: Bool {
        document.accounts.isEmpty
            && document.balances.isEmpty
            && document.transactions.isEmpty
            && document.expectedTransactions.isEmpty
            && document.incomeSources.isEmpty
            && document.installments.isEmpty
            && document.debts.isEmpty
            && document.planning.recurringObligations.isEmpty
            && document.planning.budgets.isEmpty
    }

    /// The stored graph could not be read at launch. The store serves an empty
    /// plan and refuses to write, so screens must not present it as a fresh
    /// install with nothing to lose.
    var storeIsUnreadable: Bool { loadFailure != nil }

    /// Why "Import current state" is unavailable, or `nil` when it may run.
    ///
    /// Phase 2.2 imports into an empty store only. An unreadable store is not
    /// an empty one: its rows exist and are the only copy of themselves, so
    /// replacing them is the one outcome an import must never produce.
    var importBlocker: AppImportError? {
        if isFixed { return .storeIsReadOnly }
        if storeIsUnreadable { return .storeUnreadable }
        // Checkpoint metadata that cannot be read is the same situation as a
        // document that cannot be read: the rows exist and are the only copy of
        // themselves, so an import must not write over them. A subgraph that
        // reads cleanly and holds history blocks the import as a non-empty
        // store, which is what it is.
        switch checkpoints.occupancy() {
        case .unreadable: return .storeUnreadable
        case .holdsCheckpointHistory: return .storeNotEmpty
        case .empty: return documentIsEmpty ? nil : .storeNotEmpty
        }
    }

    var canImportCurrentState: Bool { importBlocker == nil }

    // MARK: - Import: prepare, review, confirm

    /// Decodes and validates a chosen file, and describes it. Writes nothing.
    ///
    /// Everything that can be checked without touching the store is checked
    /// here: a document this build cannot read must not first destroy the one
    /// it can. On return the document is staged in memory and the preview is
    /// the whole of what the person is shown about it.
    @discardableResult
    func prepareImport(from url: URL) throws -> ImportPreview {
        // Asked before the file is opened: a store that cannot accept an import
        // has no business reading someone's finances off disk to tell them so.
        if let importBlocker { throw importBlocker }
        return try stage(DocumentImporter.read(contentsOf: url))
    }

    /// The same path from bytes already in hand.
    @discardableResult
    func prepareImport(from data: Data) throws -> ImportPreview {
        if let importBlocker { throw importBlocker }
        return try stage(DocumentImporter.decode(data))
    }

    private func stage(_ candidate: FinanceDocument) throws -> ImportPreview {
        let previous = beginOperation()
        defer { operationDate = previous }
        try DocumentImporter.semanticValidate(candidate)
        let preview = try DocumentImporter.preview(of: candidate, today: try requireCivilToday())
        pendingImport = candidate
        pendingImportPreview = preview
        return preview
    }

    /// Forgets a staged document. Nothing was written, so there is nothing to
    /// undo — but the decoded personal data should not outlive the sheet.
    func cancelImport() {
        pendingImport = nil
        pendingImportPreview = nil
    }

    /// Writes the staged document, with any balances the reviewer corrected.
    ///
    /// All of it lands or none of it does. The in-memory document moves only
    /// after the write has returned, and the write itself rolls the context
    /// back on failure, so a store that refuses an import is byte-for-byte the
    /// store that went into it.
    @discardableResult
    func confirmImport(balanceCorrections: [ImportBalanceCorrection] = []) throws -> ImportSummary {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard let pending = pendingImport else { throw AppImportError.noDocumentStaged }
        // Re-checked rather than trusted from `prepareImport`: the sheet may
        // have been open while something else wrote to the store.
        if let importBlocker { throw importBlocker }

        let corrected = try DocumentImporter.applying(balanceCorrections, to: pending)
        // A correction changes only balances, but a corrected balance is still
        // a balance the store has rules about. Validating the thing actually
        // being written costs nothing and closes the gap between what was
        // previewed and what is persisted.
        try DocumentImporter.semanticValidate(corrected)

        let summary = try DocumentImporter.summary(of: corrected, today: try requireCivilToday())
        let importedMetadata = AppPersistenceMetadata(
            incomeSourceActive: Dictionary(
                uniqueKeysWithValues: corrected.incomeSources.map { ($0.id, true) }
            ),
            currentHoldingsModelVersion: CurrentHoldings.modelVersion
        )

        if let context {
            do {
                try writer.write(corrected, context, try requireCivilToday(), [:], importedMetadata)
            } catch {
                // Atomicity is the store's guarantee, not one writer's: whatever
                // the writer left half-done in the context is discarded here, so
                // the next successful write cannot commit part of a failed
                // import along with itself.
                context.rollback()
                throw AppImportError.persistenceFailed(Self.safeReason(error))
            }
        }

        // Past this line the write has committed, so the in-memory store may
        // move. Nothing above it changed a published value.
        loadFailure = nil
        document = corrected
        transactionPresentation = [:]
        appMetadata = importedMetadata
        trustedAutomationEnabled = importedMetadata.trustedAutomationEnabled
        pendingImport = nil
        pendingImportPreview = nil
        // Assigning the scenario recalculates; the snapshot is rebuilt from the
        // imported document before this returns, so Home is correct on the next
        // frame and no relaunch is involved.
        scenario = DomainMapper.scenario(corrected.planning.defaultScenario ?? .base)
        recalculate()
        return summary
    }

    /// What a failed write is allowed to say about itself.
    ///
    /// A `PersistenceMappingError` names records structurally — identifiers and
    /// field names — and is safe to show. Anything else is reported by type
    /// alone: a store-level error can quote the row it choked on, and that row
    /// is the person's money.
    private static func safeReason(_ error: Error) -> String {
        if let mapping = error as? PersistenceMappingError { return mapping.description }
        return String(describing: type(of: error))
    }

    // MARK: - FinanceDocument import/export

    /// Replaces the local pre-alpha store from the versioned interchange
    /// contract, in one step, for tests and development tooling.
    ///
    /// The user-facing path is `prepareImport` → review → `confirmImport`; this
    /// keeps the older single-call spelling working and shares the same
    /// validate-then-write ordering.
    ///
    /// It is also the one path that may replace an unreadable store: doing so
    /// is a decision, not a side effect of adding a transaction.
    func importDocument(_ imported: FinanceDocument) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { return }
        // An older additive minor version is read, then stored as the version
        // this build writes: a 1.1.0 export is a 1.3.0 document with nothing
        // reconciled or externally evidenced. Keeping the old number would make
        // the first reconciliation write a field the declared version does not
        // admit to having.
        var imported = imported
        if try Interchange.format(for: imported.schemaVersion) == .v1 {
            imported.schemaVersion = Interchange.currentSchemaVersion
        }
        // Validated before anything is replaced: a document this build cannot
        // read must not first destroy the one it can.
        try StoredDocumentGraph.validate(imported)
        _ = try requireCivilToday()
        let importedMetadata = AppPersistenceMetadata(
            incomeSourceActive: Dictionary(
                uniqueKeysWithValues: imported.incomeSources.map { ($0.id, true) }
            ),
            currentHoldingsModelVersion: CurrentHoldings.modelVersion
        )
        if let context {
            do {
                try writer.write(imported, context, try requireCivilToday(), [:], importedMetadata)
            } catch {
                context.rollback()
                throw error
            }
        }
        loadFailure = nil
        document = imported
        transactionPresentation = [:]
        appMetadata = importedMetadata
        trustedAutomationEnabled = importedMetadata.trustedAutomationEnabled
        pendingImport = nil
        pendingImportPreview = nil
        scenario = DomainMapper.scenario(imported.planning.defaultScenario ?? .base)
        recalculate()
    }

    func exportDocument() throws -> FinanceDocument {
        if let context, let stored = try StoredDocumentGraph.load(from: context) {
            return stored
        }
        return document
    }

    // MARK: - Export: backup

    /// Why "Export backup" is unavailable, or `nil` when it may run.
    ///
    /// An unreadable store is the case this exists for. The store then serves
    /// an empty plan, and an empty plan encodes perfectly well — so without
    /// this gate the app would hand back a well-formed backup of nothing and
    /// look like it had worked.
    ///
    /// The unreadable check comes first, unlike `importBlocker`'s order,
    /// because an unreadable store has no context either — and "your data
    /// could not be opened" is the sentence that situation needs, not the one
    /// about a store with nothing behind it.
    ///
    /// A backup is a copy of what is on this device, so a store with no
    /// persistent context has nothing to make one from. That covers the fixed
    /// facade and the in-memory preview/fixture stores alike.
    ///
    /// The last condition is an account rather than `documentIsEmpty` or
    /// `isEmpty`, and neither of those would be right. A restore needs at
    /// least one account — `DocumentImporter.semanticValidate` refuses a
    /// document without one — so an accountless store cannot produce a
    /// restorable file whatever else it holds, and a person who has added a
    /// goal but no account must not be told there is nothing there.
    /// `documentIsEmpty` does not count goals or set-aside at all, and
    /// `isEmpty` additionally consults checkpoint history, which a backup does
    /// not carry and so cannot make one worth taking.
    var backupBlocker: AppExportError? {
        if storeIsUnreadable { return .storeUnreadable }
        if isFixed || context == nil { return .storeIsReadOnly }
        return document.accounts.isEmpty ? .nothingToExport : nil
    }

    var canExportBackup: Bool { backupBlocker == nil }

    /// Reads the stored graph, writes it to interchange bytes, and proves the
    /// bytes read back before returning them. Writes nothing and keeps nothing.
    ///
    /// The source is the persisted graph, not the in-memory document: a backup
    /// is a copy of what is on disk, and reading it back through the same load
    /// path a relaunch uses is what makes it one.
    func exportBackup() throws -> FinanceBackup {
        let previous = beginOperation()
        defer { operationDate = previous }
        if let backupBlocker { throw backupBlocker }
        guard let day = civilToday() else { throw AppExportError.currentDayUnavailable }
        let stored: FinanceDocument
        do {
            stored = try exportDocument()
        } catch {
            // The stored graph would not come back. It is not empty and it is
            // not readable, which is the `storeUnreadable` situation arriving
            // late rather than at launch.
            throw AppExportError.storeUnreadable
        }
        return try DocumentExporter.backup(of: stored, on: day)
    }

    // MARK: - Loading

    private func load() {
        guard let context else {
            recalculate()
            return
        }
        do {
            if let stored = try StoredDocumentGraph.load(from: context) {
                document = stored
                appMetadata = try StoredDocumentGraph.loadAppMetadata(from: context)
                trustedAutomationEnabled = appMetadata.trustedAutomationEnabled
                transactionPresentation = try Dictionary(
                    uniqueKeysWithValues: context.fetch(FetchDescriptor<StoredTransaction>()).map {
                        (
                            $0.identifier,
                            DomainMapper.TransactionPresentation(
                                categoryKey: $0.appCategoryKey,
                                merchant: $0.appMerchant
                            )
                        )
                    }
                )
                scenario = DomainMapper.scenario(stored.planning.defaultScenario ?? .base)
            }
        } catch {
            // No fixture fallback in production, and no silent reset: the app
            // opens empty and read-only, because the alternative is that the
            // first new entry purges rows that could not be read but are still
            // the only copy of them.
            loadFailure = String(describing: error)
            document = Self.emptyDocument()
            transactionPresentation = [:]
            appMetadata = .empty
            trustedAutomationEnabled = false
        }
        recalculate()
    }

    private static func emptyDocument() -> FinanceDocument {
        FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "LOCAL-USER-DATA",
            note: "Empty local store. No sample financial history was seeded.",
            accounts: [],
            balances: [],
            planning: FinanceDocument.Planning(defaultScenario: .base)
        )
    }

    private final class FixtureBundleMarker: NSObject {}

    /// The Debug/test-only development fixture.
    ///
    /// `*.fixture.json` is excluded from the app target's Release
    /// configuration, so the bytes are not in a shipped bundle and this throws
    /// there. Nothing in the production path calls it.
    static func developmentFixture() throws -> FinanceDocument {
        let bundles = [Bundle.main, Bundle(for: FixtureBundleMarker.self)]
        guard let url = bundles.compactMap({
            $0.url(forResource: "sample-scenario", withExtension: "fixture.json")
        }).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Interchange.decode(Data(contentsOf: url))
    }


    // MARK: - Mutation

    /// Records an entry. Returning means it is in the document *and* on disk;
    /// anything else throws `AppEntryError` naming what went wrong, so the
    /// sheet can stay open and say so. There is no path that returns having
    /// done nothing.
    func add(_ draft: TransactionDraft) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { throw AppEntryError.storeIsReadOnly }
        let mapped = try mapper.transaction(
            from: draft,
            accounts: document.accounts,
            incomeSources: document.incomeSources,
            incomeSourceActive: appMetadata.incomeSourceActive
        )

        guard civilToday() != nil else { throw AppEntryError.currentDayUnavailable }
        let restoreTransactions = document.transactions
        let restoreBalances = document.balances
        let restoreMetadata = appMetadata
        document.transactions.append(mapped.transaction)
        transactionPresentation[mapped.transaction.id] = mapped.presentation
        switch draft.kind {
        case .expense:
            appMetadata.lastExpenseAccountID = draft.accountID
        case .income:
            appMetadata.lastIncomeAccountID = draft.accountID
        case .transfer:
            break
        }

        do {
            try persistCurrentDocument()
        } catch {
            // The write failed, so the in-memory document must not keep an
            // entry the store does not have. Leaving it would show a saved
            // transaction that is gone on next launch.
            document.transactions = restoreTransactions
            document.balances = restoreBalances
            appMetadata = restoreMetadata
            transactionPresentation.removeValue(forKey: mapped.transaction.id)
            throw AppEntryError.persistenceFailed(String(describing: error))
        }
        recalculate()
    }

    // MARK: - Removing a transaction

    /// Why this transaction cannot be removed, or `nil` when it can.
    ///
    /// The single authority. The screen asks it to decide whether to offer the
    /// action, and `deleteActivityRow` asks it again before doing anything, so
    /// a row whose situation changed while it was on screen is refused rather
    /// than removed on the strength of a stale answer.
    ///
    /// Every clause reads live document state and names a durable record that
    /// would be left pointing at nothing. Two of them — the settlement and the
    /// evidence link — FinanceCore would also refuse on the way to disk, so
    /// checking them here turns an opaque write failure into a sentence a
    /// person can act on. The other two it would not refuse, which is exactly
    /// why they are checked: nothing downstream would notice.
    ///
    /// Order matters only for the message. The strongest statement about the
    /// row comes first, so a transaction that is both imported evidence and
    /// settles a payment is described as the evidence it is.
    func removalBlocker(forTransaction id: String) -> AppRemovalError? {
        if isFixed { return .storeIsReadOnly }
        if storeIsUnreadable { return .storeUnreadable }
        guard let transaction = document.transactions.first(where: { $0.id == id }) else {
            return .notFound
        }

        // Not something this app recorded. `userConfirmed` is the grade the
        // domain already uses for "a person explicitly stated this" — it is
        // what a trusted rule requires of the confirmations behind it — and it
        // is what both entry paths in this app produce. Anything else arrived
        // as evidence from outside, and removing it here would discard a
        // record the app cannot recreate.
        guard transaction.provenance.evidenceGrade == .userConfirmed else {
            return .sourceEvidence
        }

        if document.planning.settlements.contains(where: { $0.actualTransactionID == id }) {
            return .settlesExpectedPayment
        }
        if document.externalEvidenceLinks.contains(where: { $0.transactionID == id }) {
            return .linkedToBankEvidence
        }
        // Held by another transaction, so the direction matters: this row may
        // link outward freely, but a refund, repayment or disposal recorded
        // against it is a statement about *this* row that would silently
        // change meaning if it vanished.
        if document.transactions.contains(where: { $0.id != id && $0.linkedTransactionID == id }) {
            return .linkedFromAnotherTransaction
        }
        if document.planning.plannedPurchases.contains(where: { $0.purchasedTransactionID == id }) {
            return .recordedAsGoalPurchase
        }
        return nil
    }

    /// Removes one transaction, or throws the reason it may not be removed.
    ///
    /// Nothing cascades. A settlement, an evidence link, another transaction's
    /// link and a goal's purchase are all records of something decided or
    /// observed, and deleting one row is not a reason to erase any of them —
    /// so a transaction any of them names is refused here rather than removed
    /// with its dependants quietly deleted behind it.
    func deleteActivityRow(id: String) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        // Evaluated against the state as it is now, not as the screen last saw
        // it. A disabled button is a courtesy; this is the guarantee.
        if let blocker = removalBlocker(forTransaction: id) { throw blocker }
        guard let index = document.transactions.firstIndex(where: { $0.id == id }) else {
            throw AppRemovalError.notFound
        }
        _ = try requireCivilToday()
        let restoreTransactions = document.transactions
        let restoreBalances = document.balances
        let restorePresentation = transactionPresentation

        document.transactions.remove(at: index)
        transactionPresentation.removeValue(forKey: id)

        do {
            try persistCurrentDocument()
        } catch {
            document.transactions = restoreTransactions
            document.balances = restoreBalances
            transactionPresentation = restorePresentation
            throw AppRemovalError.persistenceFailed(String(describing: error))
        }
        recalculate()
    }

    func saveAccount(_ draft: AccountDraft) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { throw AppManagementError.storeIsReadOnly }
        guard draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AppManagementError.nameRequired
        }

        _ = try requireCivilToday()
        let restoreAccounts = document.accounts
        let restoreBalances = document.balances
        do {
            if let id = draft.id {
                guard let index = document.accounts.firstIndex(where: { $0.id == id }) else {
                    throw AppManagementError.unknownAccount
                }
                let existing = document.accounts[index]
                guard existing.currency.code == draft.currencyCode,
                      existing.currency.minorUnitDigits == draft.fractionDigits else {
                    throw AppManagementError.invalidCurrency
                }
                let mapped = try mapper.newAccount(
                    from: draft,
                    id: id,
                    drawOrder: existing.drawOrder
                )
                document.accounts[index] = mapped.account
            } else {
                let id = "account-\(UUID().uuidString.lowercased())"
                let mapped = try mapper.newAccount(
                    from: draft,
                    id: id,
                    drawOrder: (document.accounts.map(\.drawOrder).max() ?? -1) + 1
                )
                document.accounts.append(mapped.account)
                document.balances.append(mapped.balance)
            }
            try persistCurrentDocument()
        } catch let error as AppManagementError {
            document.accounts = restoreAccounts
            document.balances = restoreBalances
            throw error
        } catch {
            document.accounts = restoreAccounts
            document.balances = restoreBalances
            throw AppManagementError.persistenceFailed(String(describing: error))
        }
        recalculate()
    }

    func saveIncomeSource(_ draft: IncomeSourceDraft) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { throw AppManagementError.storeIsReadOnly }
        guard draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AppManagementError.nameRequired
        }
        if let preferred = draft.preferredAccountID,
           !document.accounts.contains(where: { $0.id == preferred && $0.isActive }) {
            throw AppManagementError.inactivePreferredAccount
        }

        _ = try requireCivilToday()
        let restoreSources = document.incomeSources
        let restoreMetadata = appMetadata
        do {
            let id: String
            if let existingID = draft.id {
                guard let index = document.incomeSources.firstIndex(where: { $0.id == existingID }) else {
                    throw AppManagementError.unknownIncomeSource
                }
                id = existingID
                document.incomeSources[index] = mapper.updating(
                    document.incomeSources[index],
                    from: draft
                )
            } else {
                id = "income-source-\(UUID().uuidString.lowercased())"
                let preferredCurrency = draft.preferredAccountID.flatMap { preferred in
                    document.accounts.first { $0.id == preferred }?.currency
                } ?? .eur
                document.incomeSources.append(
                    mapper.newIncomeSource(
                        from: draft,
                        id: id,
                        today: try requireCivilToday(),
                        currency: preferredCurrency
                    )
                )
            }
            appMetadata.incomeSourceActive[id] = draft.isActive
            try persistCurrentDocument()
        } catch let error as AppManagementError {
            document.incomeSources = restoreSources
            appMetadata = restoreMetadata
            throw error
        } catch {
            document.incomeSources = restoreSources
            appMetadata = restoreMetadata
            throw AppManagementError.persistenceFailed(String(describing: error))
        }
        recalculate()
    }

    // MARK: - Budget

    /// Sets or clears the gross monthly economic-spending ceiling.
    ///
    /// Gross by definition: this is what may be consumed in a month, housing
    /// included. Assistance that has not arrived is income elsewhere in the
    /// plan and never an argument for a smaller obligation here.
    func setMonthlyEconomicCeiling(_ amount: Amount?) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { throw AppManagementError.storeIsReadOnly }
        if let amount {
            guard !amount.isNegative, amount.currencyCode == Currency.eur.code else {
                throw AppManagementError.invalidBudgetAmount
            }
        }
        _ = try requireCivilToday()
        let restore = document.planning.monthlyEconomicCeiling
        document.planning.monthlyEconomicCeiling = amount.map(DomainMapper.money)
        do {
            try persistCurrentDocument()
        } catch {
            document.planning.monthlyEconomicCeiling = restore
            throw AppManagementError.persistenceFailed(String(describing: error))
        }
        recalculate()
    }

    /// Sets or clears the operating floor for the spendable euro pool.
    ///
    /// Planning policy only: the forecast uses this as the cash floor it
    /// should not fall below. It does not move balances, rewrite history, or
    /// change Safe to Use. Nil means no floor is configured.
    func setSafetyReserve(_ amount: Amount?) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { throw AppManagementError.storeIsReadOnly }
        if let amount {
            guard !amount.isNegative, amount.currencyCode == Currency.eur.code else {
                throw AppManagementError.invalidSafetyReserve
            }
        }
        _ = try requireCivilToday()
        let restore = document.planning.safetyFloor
        document.planning.safetyFloor = amount.map(DomainMapper.money)
        do {
            try persistCurrentDocument()
        } catch {
            document.planning.safetyFloor = restore
            throw AppManagementError.persistenceFailed(String(describing: error))
        }
        recalculate()
    }

    /// Creates or updates one budget line, and records that the person agreed
    /// to its target.
    func saveBudgetLine(_ draft: BudgetLineDraft) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { throw AppManagementError.storeIsReadOnly }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppManagementError.nameRequired }
        guard !draft.monthlyTarget.isNegative,
              draft.monthlyTarget.currencyCode == Currency.eur.code else {
            throw AppManagementError.invalidBudgetAmount
        }
        // A category feeding two lines would double-count its spending, so the
        // clash is refused rather than resolved by an arbitrary precedence.
        if let clash = categoryClash(for: draft) {
            throw AppManagementError.duplicateBudgetCategory(clash)
        }

        _ = try requireCivilToday()
        let restore = document.planning.budgets
        let month = try requireCivilToday().monthKey
        if let id = draft.id {
            guard let index = document.planning.budgets.firstIndex(where: { $0.id == id }) else {
                throw AppManagementError.unknownBudget
            }
            var budget = document.planning.budgets[index]
            budget.name = name
            budget.spendingClass = DomainMapper.spendingClass(draft.spendingClass)
            budget.categoryKeys = draft.categoryKeys
            budget.confirmation = .userConfirmed
            // An override for a month already under way would silently disagree
            // with the base amount from next month on. The person edited the
            // line, so the line is what changes.
            budget.monthlyOverrides.removeValue(forKey: month)
            budget.monthlyAmount = DomainMapper.money(draft.monthlyTarget)
            document.planning.budgets[index] = budget
        } else {
            document.planning.budgets.append(
                BudgetAllocation(
                    id: "budget-\(UUID().uuidString.lowercased())",
                    name: name,
                    spendingClass: DomainMapper.spendingClass(draft.spendingClass),
                    monthlyAmount: DomainMapper.money(draft.monthlyTarget),
                    effectiveFrom: month,
                    confirmation: .userConfirmed,
                    categoryKeys: draft.categoryKeys
                )
            )
        }

        do {
            try persistCurrentDocument()
        } catch {
            document.planning.budgets = restore
            throw AppManagementError.persistenceFailed(String(describing: error))
        }
        recalculate()
    }

    func deleteBudgetLine(id: String) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { throw AppManagementError.storeIsReadOnly }
        guard document.planning.budgets.contains(where: { $0.id == id }) else {
            throw AppManagementError.unknownBudget
        }
        _ = try requireCivilToday()
        let restore = document.planning.budgets
        let restoreObligations = document.planning.recurringObligations
        document.planning.budgets.removeAll { $0.id == id }
        // A commitment pointing at a line that no longer exists would keep
        // reporting into nothing. Unlink it rather than leave a dangling id.
        for index in document.planning.recurringObligations.indices
        where document.planning.recurringObligations[index].budgetID == id {
            document.planning.recurringObligations[index].budgetID = nil
        }
        do {
            try persistCurrentDocument()
        } catch {
            document.planning.budgets = restore
            document.planning.recurringObligations = restoreObligations
            throw AppManagementError.persistenceFailed(String(describing: error))
        }
        recalculate()
    }

    /// Accepts every proposed target as it stands.
    func confirmSuggestedBudgetLines() throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { throw AppManagementError.storeIsReadOnly }
        _ = try requireCivilToday()
        let restore = document.planning.budgets
        for index in document.planning.budgets.indices
        where document.planning.budgets[index].confirmation == .suggested {
            document.planning.budgets[index].confirmation = .userConfirmed
        }
        guard document.planning.budgets != restore else { return }
        do {
            try persistCurrentDocument()
        } catch {
            document.planning.budgets = restore
            throw AppManagementError.persistenceFailed(String(describing: error))
        }
        recalculate()
    }

    /// Links a recurring commitment to the line it is committed against, so
    /// its settled charge lands in that line rather than nowhere.
    func setBudget(_ budgetID: String?, forObligation obligationID: String) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { throw AppManagementError.storeIsReadOnly }
        guard let index = document.planning.recurringObligations
            .firstIndex(where: { $0.id == obligationID }) else { return }
        if let budgetID, !document.planning.budgets.contains(where: { $0.id == budgetID }) {
            throw AppManagementError.unknownBudget
        }
        _ = try requireCivilToday()
        let restore = document.planning.recurringObligations
        document.planning.recurringObligations[index].budgetID = budgetID
        do {
            try persistCurrentDocument()
        } catch {
            document.planning.recurringObligations = restore
            throw AppManagementError.persistenceFailed(String(describing: error))
        }
        recalculate()
    }

    /// The categories currently feeding one line.
    func categoryKeys(forBudget id: String) -> [String] {
        document.planning.budgets.first { $0.id == id }?.categoryKeys ?? []
    }

    func budgetID(forObligation id: String) -> String? {
        document.planning.recurringObligations.first { $0.id == id }?.budgetID
    }

    /// Committed recurring charges, so the editor can offer each one a line.
    /// Hypothetical rules are left out: an exploration commits nothing.
    func unlinkedCommitments() -> [CommitmentOption] {
        document.planning.recurringObligations
            .filter { $0.commitmentStatus == .committed }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { CommitmentOption(id: $0.id, name: $0.name, amount: DomainMapper.amount($0.amount.magnitude)) }
    }

    /// The name of a line already claiming one of the draft's categories.
    private func categoryClash(for draft: BudgetLineDraft) -> String? {
        let claimed = Set(draft.categoryKeys)
        guard !claimed.isEmpty else { return nil }
        for budget in document.planning.budgets where budget.id != draft.id {
            if !claimed.isDisjoint(with: budget.categoryKeys) { return budget.name }
        }
        return nil
    }

    private func persistCurrentDocument() throws {
        if let loadFailure { throw AppEntryError.persistenceFailed(loadFailure) }
        guard let context else { return }
        appMetadata.currentHoldingsModelVersion = CurrentHoldings.modelVersion
        let restoreVersion = document.schemaVersion
        if document.planning.containsDurablePlanningState {
            document.schemaVersion = Interchange.version(
                document.schemaVersion,
                atLeast: Interchange.planningStateSchemaVersion
            )
        }
        do {
            try writer.write(
                document,
                context,
                try requireCivilToday(),
                transactionPresentation,
                appMetadata
            )
        } catch {
            // The live writer already rolls back inside `replace`, but a
            // failing stand-in can tear down rows and throw. Callers restore
            // the in-memory document; this restores the SwiftData context so
            // the next successful write cannot commit a half-destroyed graph.
            document.schemaVersion = restoreVersion
            context.rollback()
            throw error
        }
    }

    // MARK: - Phase 2.7 planning state

    func savePlannedPurchase(_ draft: PlannedPurchaseDraft) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        let purchase = try plannedPurchase(from: draft)
        try savePlannedPurchase(purchase)
    }

    func saveSinkingFund(_ draft: SinkingFundDraft) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        let fund = try sinkingFund(from: draft)
        try saveSinkingFund(fund)
    }

    /// Pure what-if. Does not write goals, funds, transactions, or balances.
    func evaluateAffordability(_ draft: AffordabilityDraft) throws -> AffordabilityPresentation {
        let previous = beginOperation()
        defer { operationDate = previous }
        let candidate = try affordabilityCandidate(from: draft)
        // The horizon this verdict is measured over. A horizon that cannot be
        // built is refused, never shortened: a shorter one answers an easier
        // question than the one asked.
        let asOf = try requireCivilToday()
        guard let horizonEnd = asOf.advanced(by: forecastHorizonDays - 1) else {
            throw AppEntryError.forecastUnavailable
        }
        let request = AffordabilityRequest(
            document: document,
            today: asOf,
            horizonEnd: horizonEnd,
            candidate: candidate,
            plannedPurchases: document.planning.plannedPurchases,
            sinkingFunds: document.planning.sinkingFunds
        )
        do {
            let verdict = try AffordabilityEngine.evaluate(request)
            return mapper.affordabilityPresentation(
                verdict,
                document: document,
                settlementAccountID: draft.accountID
            )
        } catch let error as AffordabilityError {
            throw AppManagementError.affordability(DomainMapper.affordabilityErrorMessage(error))
        }
    }

    func plannedPurchaseDraft(id: String) -> PlannedPurchaseDraft? {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard let purchase = document.planning.plannedPurchases.first(where: { $0.id == id }) else {
            return nil
        }
        var draft = PlannedPurchaseDraft()
        draft.targetDate = currentDay()
        draft.id = purchase.id
        draft.name = purchase.name
        draft.amountText = DomainMapper.amount(purchase.targetAmount).editingText
        draft.currencyCode = purchase.targetAmount.currency.code
        draft.fractionDigits = purchase.targetAmount.currency.minorUnitDigits
        if let target = purchase.targetDate {
            draft.hasTargetDate = true
            draft.targetDate = DomainMapper.civilDay(target)
        }
        draft.status = mapper.goalStatus(purchase.status)
        draft.funding = mapper.goalFunding(purchase.funding)
        if case let .sinkingFund(id) = purchase.funding { draft.sinkingFundID = id }
        draft.installmentPlanID = purchase.installmentPlanID
        draft.note = purchase.note ?? ""
        return draft
    }

    func sinkingFundDraft(id: String) -> SinkingFundDraft? {
        guard let fund = document.planning.sinkingFunds.first(where: { $0.id == id }) else {
            return nil
        }
        var draft = SinkingFundDraft()
        draft.id = fund.id
        draft.name = fund.name
        draft.targetText = DomainMapper.amount(fund.targetAmount).editingText
        draft.reservedText = DomainMapper.amount(fund.reservedAmount).editingText
        draft.currencyCode = fund.targetAmount.currency.code
        draft.fractionDigits = fund.targetAmount.currency.minorUnitDigits
        draft.custody = mapper.fundCustody(fund.custody)
        if case let .dedicatedAccount(accountID) = fund.custody {
            draft.dedicatedAccountID = accountID
        }
        draft.goalID = fund.goalID
        draft.contributionText = fund.contributionAmount.map { DomainMapper.amount($0).editingText } ?? ""
        draft.status = mapper.fundStatus(fund.status)
        draft.note = fund.note ?? ""
        return draft
    }

    func makeAffordabilityDraft() -> AffordabilityDraft {
        let previous = beginOperation()
        defer { operationDate = previous }
        var draft = AffordabilityDraft()
        draft.on = currentDay()
        draft.currencyCode = snapshot.currencyCode
        return draft
    }

    func affordabilityDraft(prefilledFromGoalID goalID: String) -> AffordabilityDraft {
        let previous = beginOperation()
        defer { operationDate = previous }
        var draft = makeAffordabilityDraft()
        draft.plannedPurchaseID = goalID
        guard let purchase = document.planning.plannedPurchases.first(where: { $0.id == goalID }) else {
            return draft
        }
        draft.amountText = DomainMapper.amount(purchase.targetAmount).editingText
        draft.currencyCode = purchase.targetAmount.currency.code
        draft.fractionDigits = purchase.targetAmount.currency.minorUnitDigits
        if let on = purchase.targetDate {
            let civil = DomainMapper.civilDay(on)
            draft.on = draft.on.map { max(civil, $0) }
        }
        draft.funding = mapper.goalFunding(purchase.funding)
        if case let .sinkingFund(id) = purchase.funding { draft.sinkingFundID = id }
        draft.installmentPlanID = purchase.installmentPlanID
        return draft
    }

    private func plannedPurchase(from draft: PlannedPurchaseDraft) throws -> PlannedPurchase {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppManagementError.nameRequired }
        let amount: Amount
        do {
            amount = try Amount.parse(draft.amountText, currencyCode: draft.currencyCode, fractionDigits: draft.fractionDigits)
        } catch {
            throw AppManagementError.invalidAmount
        }
        guard !amount.isNegative, amount.isPositive else { throw AppManagementError.invalidAmount }
        let funding: PlannedPurchaseFunding
        switch draft.funding {
        case .cash:
            funding = .cashOnPurchase
        case .sinkingFund:
            guard let fundID = draft.sinkingFundID else { throw AppManagementError.unknownSinkingFund }
            funding = .sinkingFund(id: fundID)
        case .financing:
            funding = .financing
        }
        let existing = draft.id.flatMap { id in
            document.planning.plannedPurchases.first { $0.id == id }
        }
        let money = DomainMapper.money(amount)
        var reserved = existing?.reservedAmount ?? Money(minorUnits: 0, currency: money.currency)
        if case .sinkingFund = funding {
            reserved = Money(minorUnits: 0, currency: money.currency)
        } else if reserved.currency != money.currency {
            reserved = Money(minorUnits: 0, currency: money.currency)
        }
        return PlannedPurchase(
            id: draft.id ?? "goal-\(UUID().uuidString.lowercased())",
            name: name,
            targetAmount: money,
            targetDate: draft.hasTargetDate ? try DomainMapper.requiredDay(draft.targetDate, or: AppManagementError.invalidDate) : nil,
            status: mapper.plannedPurchaseStatus(draft.status),
            funding: funding,
            reservedAmount: reserved,
            purchasedTransactionID: existing?.purchasedTransactionID,
            installmentPlanID: draft.funding == .financing ? draft.installmentPlanID : nil,
            budgetID: existing?.budgetID,
            requirement: existing?.requirement ?? mapper.paymentRequirement(
                currencyCode: draft.currencyCode,
                fractionDigits: draft.fractionDigits,
                rail: .card
            ),
            note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private func sinkingFund(from draft: SinkingFundDraft) throws -> SinkingFund {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppManagementError.nameRequired }
        let target: Amount
        let reserved: Amount
        do {
            target = try Amount.parse(draft.targetText, currencyCode: draft.currencyCode, fractionDigits: draft.fractionDigits)
            reserved = try Amount.parse(
                draft.reservedText.isEmpty ? "0" : draft.reservedText,
                currencyCode: draft.currencyCode,
                fractionDigits: draft.fractionDigits
            )
        } catch {
            throw AppManagementError.invalidAmount
        }
        guard !target.isNegative, target.isPositive else { throw AppManagementError.invalidAmount }
        guard !reserved.isNegative else { throw AppManagementError.invalidAmount }
        let contribution: Money?
        let trimmedContribution = draft.contributionText.trimmingCharacters(in: .whitespaces)
        if trimmedContribution.isEmpty {
            contribution = nil
        } else {
            do {
                contribution = DomainMapper.money(
                    try Amount.parse(trimmedContribution, currencyCode: draft.currencyCode, fractionDigits: draft.fractionDigits)
                )
            } catch {
                throw AppManagementError.invalidAmount
            }
        }
        let custody: SinkingFundCustody
        switch draft.custody {
        case .virtual:
            custody = .virtualReservation
        case .dedicated:
            guard let accountID = draft.dedicatedAccountID else { throw AppManagementError.unknownAccount }
            custody = .dedicatedAccount(accountID: accountID)
        }
        let existing = draft.id.flatMap { id in
            document.planning.sinkingFunds.first { $0.id == id }
        }
        return SinkingFund(
            id: draft.id ?? "fund-\(UUID().uuidString.lowercased())",
            name: name,
            goalID: draft.goalID,
            targetAmount: DomainMapper.money(target),
            reservedAmount: DomainMapper.money(reserved),
            contributionAmount: contribution,
            contributionSchedule: existing?.contributionSchedule,
            custody: custody,
            status: mapper.sinkingFundStatus(draft.status),
            note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private func affordabilityCandidate(from draft: AffordabilityDraft) throws -> AffordabilityCandidate {
        let amount: Amount
        do {
            amount = try Amount.parse(draft.amountText, currencyCode: draft.currencyCode, fractionDigits: draft.fractionDigits)
        } catch {
            throw AppManagementError.invalidAmount
        }
        guard amount.isPositive else { throw AppManagementError.invalidAmount }
        let money = DomainMapper.money(amount)
        let requirement = mapper.paymentRequirement(
            currencyCode: draft.currencyCode,
            fractionDigits: draft.fractionDigits,
            rail: draft.rail
        )
        let kind: AffordabilityCandidateKind
        var financing: FinancingProposal?
        if draft.asReservation {
            kind = .reservation
        } else if draft.funding == .financing, let planID = draft.installmentPlanID,
                  let plan = document.installments.first(where: { $0.id == planID }) {
            kind = .financingPurchase
            financing = FinancingProposal(
                originalPurchaseAmount: plan.originalPurchaseAmount,
                installments: plan.installments
            )
        } else {
            kind = .consumption
        }
        let sinkingFundID = (kind == .consumption && draft.funding == .sinkingFund) ? draft.sinkingFundID : nil
        return AffordabilityCandidate(
            id: "ui-\(draft.plannedPurchaseID ?? "check")",
            name: draft.plannedPurchaseID.flatMap { id in
                document.planning.plannedPurchases.first { $0.id == id }?.name
            } ?? "Purchase",
            amount: money,
            on: try DomainMapper.requiredDay(draft.on, or: AppManagementError.invalidDate),
            requirement: requirement,
            kind: kind,
            settlementAccountID: draft.accountID,
            sinkingFundID: sinkingFundID,
            financing: financing
        )
    }

    /// Creates or replaces one planned purchase. Not a transaction.
    func savePlannedPurchase(_ purchase: PlannedPurchase) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { throw AppManagementError.storeIsReadOnly }
        _ = try requireCivilToday()
        let restore = document
        if let index = document.planning.plannedPurchases.firstIndex(where: { $0.id == purchase.id }) {
            document.planning.plannedPurchases[index] = purchase
        } else {
            document.planning.plannedPurchases.append(purchase)
        }
        try commitPlanning(restoring: restore)
    }

    func deletePlannedPurchase(id: String) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { throw AppManagementError.storeIsReadOnly }
        guard document.planning.plannedPurchases.contains(where: { $0.id == id }) else {
            throw AppManagementError.unknownPlannedPurchase
        }
        if document.planning.sinkingFunds.contains(where: { $0.goalID == id }) {
            throw AppManagementError.plannedPurchaseStillReferenced
        }
        _ = try requireCivilToday()
        let restore = document
        document.planning.plannedPurchases.removeAll { $0.id == id }
        try commitPlanning(restoring: restore)
    }

    /// Creates or replaces one sinking fund. Not spending.
    func saveSinkingFund(_ fund: SinkingFund) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { throw AppManagementError.storeIsReadOnly }
        _ = try requireCivilToday()
        let restore = document
        if let index = document.planning.sinkingFunds.firstIndex(where: { $0.id == fund.id }) {
            document.planning.sinkingFunds[index] = fund
        } else {
            document.planning.sinkingFunds.append(fund)
        }
        try commitPlanning(restoring: restore)
    }

    func deleteSinkingFund(id: String) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { throw AppManagementError.storeIsReadOnly }
        guard document.planning.sinkingFunds.contains(where: { $0.id == id }) else {
            throw AppManagementError.unknownSinkingFund
        }
        let stillLinked = document.planning.plannedPurchases.contains { purchase in
            if case let .sinkingFund(fundID) = purchase.funding { return fundID == id }
            return false
        }
        if stillLinked { throw AppManagementError.sinkingFundStillReferenced }
        _ = try requireCivilToday()
        let restore = document
        document.planning.sinkingFunds.removeAll { $0.id == id }
        try commitPlanning(restoring: restore)
    }

    private func commitPlanning(restoring restore: FinanceDocument) throws {
        do {
            try persistCurrentDocument()
        } catch {
            document = restore
            throw mappedPlanningError(error)
        }
        recalculate()
    }

    private func mappedPlanningError(_ error: Error) -> AppManagementError {
        if let management = error as? AppManagementError { return management }
        if let mapping = error as? PersistenceMappingError {
            if case let .invalidPlanning(reason) = mapping {
                return .planningInvalid(reason)
            }
            return .persistenceFailed(mapping.description)
        }
        return .persistenceFailed(String(describing: error))
    }

    // MARK: - External provider evidence

    /// Persisted master safety gate. Changing it never evaluates the Inbox;
    /// only a later successful evidence import may supply work to the engine.
    func setTrustedAutomationEnabled(_ enabled: Bool) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { throw BankReviewError.storeIsReadOnly }
        guard trustedAutomationEnabled != enabled else { return }
        _ = try requireCivilToday()
        let restore = appMetadata
        appMetadata.trustedAutomationEnabled = enabled
        do {
            try persistCurrentDocument()
        } catch {
            appMetadata = restore
            throw bankReviewError(error)
        }
        trustedAutomationEnabled = enabled
        if !enabled { trustedAutomationDiagnostic = nil }
    }

    /// Affirmative per-account live coverage established by complete provider
    /// snapshots, keyed by remote opaque account id.
    ///
    /// Absence of an account is UNKNOWN, which fails review coverage closed.
    /// A legacy store that has not yet completed a snapshot under this build
    /// therefore has no coverage at all, which is the intended migration.
    var authoritativeLiveCoverage: [String: AuthoritativeLiveCoverage] {
        appMetadata.authoritativeLiveCoverage
    }

    /// The conservative global live window for a review held in `currency`.
    func liveCoverage(currency: Currency = .eur) -> LiveCoverageResolution {
        ReviewCoverageAdapter.liveCoverage(
            coverage: appMetadata.authoritativeLiveCoverage,
            bindings: document.externalAccountBindings,
            accounts: document.accounts,
            currency: currency
        )
    }

    // MARK: - Period review

    /// One period review, computed on demand.
    ///
    /// Ephemeral by construction: nothing here is written, and the request and
    /// result are discarded when the screen moves on. The store's job is to
    /// state what it knows; `ReviewEngine` decides what it means and this
    /// returns the engine's answer in the screens' own vocabulary.
    ///
    /// Nil when the selected period cannot be constructed or reviewed. The
    /// screen says so. It never falls back to a clean review, a zero review,
    /// or a review of some other period the arithmetic could reach.
    func review(_ selection: ReviewPeriodSelection) -> InsightsPresentation? {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard let computed = computeReview(selection) else { return nil }
        return ReviewPresentationMapper.present(
            computed.result,
            selection: selection,
            calendarInterval: computed.calendarInterval,
            canGoBack: selection.offset > computed.earliestOffset,
            canGoForward: selection.offset < 0,
            live: computed.live,
            labels: reviewLabels,
            // The read-only preview, exactly as before: the screen that only
            // reads a period decides nothing about it.
            verification: endedMonthVerification(
                computed, selection: selection, confirmedAcknowledgments: .noDecisions
            )?.presentation,
            showsHistoricalHomePointer: selection.offset < 0
        )
    }

    /// The ended month's verification, re-evaluated carrying the acknowledgment
    /// decisions a person has explicitly confirmed in a live interaction.
    ///
    /// Ephemeral in both directions. The authority arrives as an argument and
    /// leaves with the caller: nothing is written, nothing is read back, and
    /// the store remembers no decision between two calls. `.noDecisions` — the
    /// default, and what `review(_:)` passes — reproduces the read-only preview
    /// exactly, so a screen that never confirms anything sees what it always saw.
    ///
    /// Nil when the selection is not an ended calendar month, or cannot be
    /// reviewed at all.
    func endedMonthVerification(
        _ selection: ReviewPeriodSelection,
        confirmedAcknowledgments: PeriodCheckpointConfirmedAcknowledgments = .noDecisions
    ) -> EndedMonthVerification? {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard let computed = computeReview(selection) else { return nil }
        return endedMonthVerification(
            computed,
            selection: selection,
            confirmedAcknowledgments: confirmedAcknowledgments
        )
    }

    /// The one production ended-month checkpoint write.
    ///
    /// Recomputes review and readiness from current store state, reads the
    /// exact chain tip once, and hands that same observation to both the
    /// baseline comparison and `CheckpointClosePolicy`. Identity and append
    /// time are minted only after classification requires an append.
    ///
    /// `makeCandidateIdentity` and `sampleClosedAt` supply append metadata
    /// only. Production uses `UUID.init` and the existing operation instant;
    /// neither provider is invoked until classification produces an append plan.
    func writeEndedMonthCheckpoint(
        _ selection: ReviewPeriodSelection,
        confirmedAcknowledgments: PeriodCheckpointConfirmedAcknowledgments = .noDecisions,
        makeCandidateIdentity: @escaping () -> UUID = UUID.init,
        sampleClosedAt: (() -> Date)? = nil
    ) -> EndedMonthCheckpointWriteResult {
        let previous = beginOperation()
        defer { operationDate = previous }

        if loadFailure != nil {
            return .notWritable(.storeFailedToLoad)
        }
        if isFixed {
            return .notWritable(.storeIsReadOnly)
        }
        if selection.scope == .week {
            return .notWritable(.weeklySelection)
        }

        guard let computed = computeReview(selection) else {
            return .notWritable(.reviewUnavailable)
        }
        guard computed.calendarInterval.end < computed.asOf else {
            return .notWritable(.periodNotEnded)
        }

        let period = SemanticInterval(computed.result.interval)
        let kind = computed.result.kind
        let tip = checkpoints.latestRevision(inPeriod: period, kind: kind)
        let readiness = AttentionComposition.readiness(
            for: endedMonthCompositionInput(
                computed,
                confirmedAcknowledgments: confirmedAcknowledgments,
                checkpointBaseline: PeriodCheckpointBaselineReader.source(for: tip)
            )
        )
        let closedAt = sampleClosedAt ?? { self.operationInstant() }
        return EndedMonthCheckpointWriter.write(
            readiness: readiness,
            chainTip: tip,
            repository: checkpoints,
            makeCandidateIdentity: makeCandidateIdentity,
            closedAt: closedAt
        )
    }

    /// One computed review of the selected period, with the facts the screens
    /// read beside it.
    private struct ComputedReview {
        let asOf: Day
        let live: LiveCoverageResolution
        let result: ReviewResult
        let calendarInterval: ReviewInterval
        let earliestOffset: Int
    }

    /// The single place a period review is built. Both entry points above read
    /// this, so the verification preview and the acknowledgment interaction can
    /// never be looking at two different reviews of the same period.
    private func computeReview(_ selection: ReviewPeriodSelection) -> ComputedReview? {
        guard let asOf = civilToday() else { return nil }
        let archiveMetadata = (try? history.metadata()) ?? nil
        let archiveCutoff = archiveMetadata.flatMap { DomainMapper.day($0.archiveCutoff) }
        let live = liveCoverage()
        let request = ReviewRequestBuilder.makeRequest(
            document: document,
            selection: selection,
            asOf: asOf,
            categoryKeys: categoryKeysByTransaction,
            incomeSources: document.incomeSources,
            coverage: ReviewCoverageAdapter.coverageInput(
                archiveCutoff: archiveCutoff,
                // Archive records are not reconstructed into the engine yet, so
                // no archive-era period is offered rather than one being shown
                // with no records in it.
                history: nil,
                live: live
            )
        )
        let earliest = ReviewRequestBuilder.earliestOffset(
            scope: selection.scope, asOf: asOf, archiveCutoff: archiveCutoff
        )
        guard let request,
              let result = try? ReviewEngine.review(request),
              let calendarInterval = ReviewRequestBuilder.calendarInterval(selection, asOf: asOf)
        else { return nil }
        return ComputedReview(
            asOf: asOf,
            live: live,
            result: result,
            calendarInterval: calendarInterval,
            earliestOffset: earliest
        )
    }

    /// The one place the ended-month checkpoint input is assembled.
    ///
    /// Confirmed authority is the only thing a caller may vary here, and it is
    /// passed through to the evaluator untouched. Reading this verification —
    /// with or without decisions — closes nothing and writes no revision.
    private func endedMonthVerification(
        _ computed: ComputedReview,
        selection: ReviewPeriodSelection,
        confirmedAcknowledgments: PeriodCheckpointConfirmedAcknowledgments
    ) -> EndedMonthVerification? {
        guard selection.scope == .month, computed.calendarInterval.end < computed.asOf else {
            return nil
        }
        let period = SemanticInterval(computed.result.interval)
        let kind = computed.result.kind
        let tip = checkpoints.latestRevision(inPeriod: period, kind: kind)
        let input = endedMonthCompositionInput(
            computed,
            confirmedAcknowledgments: confirmedAcknowledgments,
            checkpointBaseline: PeriodCheckpointBaselineReader.source(for: tip)
        )
        let readiness = AttentionComposition.readiness(for: input)
        return EndedMonthVerification(
            readiness: readiness,
            presentation: PeriodVerificationMapper.present(
                readiness,
                periodLabel: input.periodLabel,
                observations: snapshot.syncedObservations,
                expectedPayments: snapshot.expectedPayments,
                correspondence: PeriodVerificationCorrespondence.explain(
                    previous: tip,
                    current: readiness
                )
            )
        )
    }

    /// Shared facts for the ended-month preview and the write action.
    ///
    /// The baseline source is supplied. The preview reads the exact tip once
    /// and passes `source(for:)` into composition and correspondence; the
    /// write action still passes `source(for:)` of the one tip it already
    /// observed.
    private func endedMonthCompositionInput(
        _ computed: ComputedReview,
        confirmedAcknowledgments: PeriodCheckpointConfirmedAcknowledgments,
        checkpointBaseline: PeriodCheckpointBaselineSource
    ) -> AttentionComposition.Input {
        AttentionComposition.Input(
            document: document,
            asOf: computed.asOf,
            accountNames: reviewLabels.accounts,
            forecast: snapshotEvaluation.forecast,
            review: computed.result,
            occurrences: expectedOccurrences(),
            observations: snapshot.syncedObservations,
            freshness: bankFreshness,
            // The same authoritative map `computeReview` built the
            // review request with. Category policy is decided once and
            // read twice — never recomputed for the checkpoint.
            categoryKeys: categoryKeysByTransaction,
            checkpointBaseline: checkpointBaseline,
            confirmedAcknowledgments: confirmedAcknowledgments,
            period: computed.result.interval,
            periodKind: computed.result.kind,
            periodLabel: ReviewPresentationMapper.monthLabel(
                computed.result.interval.start.monthKey
            )
        )
    }

    private var reviewLabels: ReviewPresentationMapper.Labels {
        ReviewPresentationMapper.Labels(
            budgetLines: Dictionary(
                document.planning.budgets.map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            ),
            goals: Dictionary(
                document.planning.plannedPurchases.map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            ),
            // The merchant the app already shows for that row. No raw provider
            // text and no counterparty is introduced here.
            transactions: transactionPresentation.compactMapValues(\.merchant),
            accounts: Dictionary(
                document.accounts.map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            ),
            // The same plan items Home resolves a risk trigger through, so
            // both screens name the same payment the same way.
            riskTriggers: Dictionary(
                document.planning.recurringObligations.map { ($0.id, $0.name) }
                    + document.incomeSources.map { ($0.id, $0.name) }
                    + document.installments.map {
                        ($0.id, DisplayDescriptor.instalmentTitle(
                            purchaseDescription: $0.purchaseDescription, provider: $0.provider
                        ))
                    }
                    + document.debts.map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    /// Persists provider evidence first. Only after that write succeeds may the
    /// independently gated automation phase evaluate newly reachable rows.
    @discardableResult
    func importBankEvidence(
        _ batch: ExternalEvidenceBatch,
        authoritativePendingSnapshots: [ExternalProvider: AuthoritativePendingSnapshot]? = nil,
        authoritativeLiveCoverage: [String: AuthoritativeLiveCoverage]? = nil
    ) throws -> TrustedRuleProcessingResult {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { throw BankReviewError.storeIsReadOnly }
        guard !batch.observations.isEmpty || !batch.balances.isEmpty || !batch.candidates.isEmpty
                || authoritativePendingSnapshots != nil
                || authoritativeLiveCoverage != nil
        else { return .empty }
        _ = try requireCivilToday()
        let beforeImport = document
        let restoreDocument = document
        let restoreMetadata = appMetadata
        do {
            try ExternalEvidenceReview.importBatch(batch, into: &document)
            if let authoritativePendingSnapshots {
                let observations = Dictionary(
                    uniqueKeysWithValues: document.externalObservations.map { ($0.id, $0) }
                )
                let resolutions = Dictionary(
                    uniqueKeysWithValues: document.observationResolutions.map {
                        ($0.observationID, $0.state)
                    }
                )
                for (provider, snapshot) in authoritativePendingSnapshots {
                    guard snapshot.observationIDs.allSatisfy({ id in
                        guard let observation = observations[id] else { return false }
                        return observation.provider == provider
                            && observation.identity == .provisionalSnapshot
                            && observation.status == .pending
                            && !observation.eligibleForEconomicActual
                            && resolutions[id] == .provisional
                    }) else {
                        throw PersistenceMappingError.invalidExternalEvidence(
                            "authoritative pending membership does not match imported provisional evidence"
                        )
                    }
                    // Merge provider scopes. A response that establishes one
                    // provider must not silently erase another provider whose
                    // authority was not present in that response.
                    appMetadata.authoritativePendingSnapshots[provider] = snapshot
                }
            }
            if let authoritativeLiveCoverage {
                // Same save, same rollback: coverage cannot come to claim a
                // window whose evidence import did not land.
                appMetadata.authoritativeLiveCoverage = LiveCoverageAuthority.merged(
                    previous: appMetadata.authoritativeLiveCoverage,
                    established: authoritativeLiveCoverage
                )
            }
            try persistCurrentDocument()
        } catch {
            document = restoreDocument
            appMetadata = restoreMetadata
            throw bankReviewError(error)
        }
        recalculate()

        guard trustedAutomationEnabled else {
            trustedAutomationDiagnostic = nil
            return .empty
        }
        let newlyEligible = Self.newlyEligibleTrustedAutomationObservationIDs(
            before: beforeImport,
            after: document
        )
        let candidates = newlyEligible.union(
            appMetadata.trustedAutomationRetryObservationIDs
        )
        guard !candidates.isEmpty else {
            trustedAutomationDiagnostic = nil
            return .empty
        }

        let result: TrustedRuleProcessingResult
        do {
            result = try processTrustedRules(observationIDs: candidates)
        } catch {
            result = TrustedRuleProcessingResult(
                evaluatedObservationCount: candidates.count,
                appliedObservationIDs: [],
                ambiguousObservationIDs: [],
                failedObservationIDs: candidates.sorted()
            )
        }
        let retryPersistenceFailed = persistTrustedAutomationRetryState(
            result,
            evaluatedIDs: candidates
        )
        trustedAutomationDiagnostic = retryPersistenceFailed
            ? "Some trusted automation could not be queued for retry. The bank evidence is saved for review."
            : Self.trustedAutomationDiagnostic(for: result)
        return result
    }

    func importBankEvidence(from provider: any BankSyncProviding) async throws {
        try await readAllEvidence(from: provider)
    }

    /// Explicitly attaches provider evidence to a transaction already entered
    /// by the person. It creates no second economic actual and moves no balance.
    func matchObservation(_ observationID: String, toTransaction transactionID: String) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        let eventNow = operationInstant()
        guard !isFixed else { throw BankReviewError.storeIsReadOnly }
        guard let observation = document.externalObservations.first(where: { $0.id == observationID }),
              let transaction = document.transactions.first(where: { $0.id == transactionID }) else {
            throw BankReviewError.unknownObservation
        }
        let role = ExternalEvidenceReview.suggestedRole(
            observation: observation, transaction: transaction, in: document
        )
        _ = try requireCivilToday()
        let restore = document
        do {
            try ExternalEvidenceReview.linkExistingTransaction(
                transactionID: transactionID,
                evidence: [ExternalEvidenceAssignment(observationID: observationID, role: role)],
                resolvedAt: eventNow,
                in: &document
            )
            try proposeTrustedRuleDrafts(in: &document, at: eventNow)
            try persistCurrentDocument()
        } catch {
            document = restore
            throw bankReviewError(error)
        }
        recalculate()
    }

    /// Confirms a debit as spending. A unique cross-provider candidate may be
    /// included only when its second observation id is passed by an explicit UI
    /// action; the candidate itself never links anything.
    @discardableResult
    func createExpense(
        from observationID: String,
        userLabel: String,
        including relatedObservationID: String? = nil,
        settlingExpectedPaymentID: String? = nil,
        allowingPotentialDuplicate: Bool = false
    ) throws -> String {
        if !allowingPotentialDuplicate,
           let observation = document.externalObservations.first(where: {
               $0.id == observationID
           }),
           let conflict = mapper.duplicateConflict(for: observation, in: document) {
            throw BankReviewError.invalidAction(
                "This may already be accounted for. \(conflict.warning) Confirm the duplicate warning before creating another transaction."
            )
        }
        return try createSingleLegActual(
            from: observationID,
            kind: .expense,
            userLabel: userLabel,
            including: relatedObservationID,
            settlingExpectedPaymentID: settlingExpectedPaymentID
        )
    }

    @discardableResult
    func createIncome(from observationID: String, userLabel: String) throws -> String {
        try createSingleLegActual(
            from: observationID,
            kind: .income,
            userLabel: userLabel,
            including: nil,
            settlingExpectedPaymentID: nil
        )
    }

    @discardableResult
    private func createSingleLegActual(
        from observationID: String,
        kind: TransactionKind,
        userLabel: String,
        including relatedObservationID: String?,
        settlingExpectedPaymentID: String?
    ) throws -> String {
        let previous = beginOperation()
        defer { operationDate = previous }
        let eventNow = operationInstant()
        guard !isFixed else { throw BankReviewError.storeIsReadOnly }
        guard let selected = document.externalObservations.first(where: { $0.id == observationID }) else {
            throw BankReviewError.unknownObservation
        }

        var movement = selected
        var merchantEvidence: ExternalObservation?
        if let relatedObservationID {
            guard let related = document.externalObservations.first(where: { $0.id == relatedObservationID }),
                  let pairing = document.crossProviderCandidates.first(where: {
                      $0.state == .unique
                          && Set([$0.bankObservationID, $0.walletObservationID].compactMap { $0 })
                            == Set([observationID, relatedObservationID])
                  }) else {
                throw BankReviewError.invalidAction("That provider pairing is not a unique candidate.")
            }
            guard let bank = document.externalObservations.first(where: { $0.id == pairing.bankObservationID }) else {
                throw BankReviewError.unknownObservation
            }
            movement = bank
            merchantEvidence = bank.id == selected.id ? related : selected
        }

        switch kind {
        case .expense where !movement.amount.isNegative:
            throw BankReviewError.invalidAction("A positive account movement cannot create an expense here.")
        case .income where !movement.amount.isPositive:
            throw BankReviewError.invalidAction("A negative account movement cannot create income here.")
        default:
            break
        }

        guard let binding = document.externalAccountBindings.first(where: { $0.id == movement.bindingID }),
              document.accounts.contains(where: { $0.id == binding.localAccountID }) else {
            throw BankReviewError.unknownAccount
        }
        let occurrence = try settlingExpectedPaymentID.map { id -> OccurrenceID in
            guard let value = DomainMapper.occurrenceID(id) else {
                throw BankReviewError.invalidAction("That expected payment is no longer available.")
            }
            return value
        }
        let transactionID = "transaction-\(UUID().uuidString.lowercased())"
        let valueDay = try merchantEvidence?.suggestedEconomicDate
            ?? movement.suggestedEconomicDate
            ?? requireCivilToday()
        let transaction = Transaction(
            id: transactionID,
            date: valueDay,
            kind: kind,
            legs: [AccountLeg(accountID: binding.localAccountID, amount: movement.amount)],
            factivity: .observed,
            lifecycle: .cleared,
            bookedDate: movement.bookingDate,
            datePrecision: movement.suggestedEconomicDate == nil ? .estimated : .exact,
            provenance: Provenance(
                source: "EXTERNAL-EVIDENCE-REVIEW",
                evidenceGrade: .userConfirmed,
                reference: movement.id
            )
        )
        var evidence = [
            ExternalEvidenceAssignment(observationID: movement.id, role: .accountMovement)
        ]
        if let merchantEvidence {
            evidence.append(
                ExternalEvidenceAssignment(
                    observationID: merchantEvidence.id,
                    role: .merchantEnrichment
                )
            )
        }

        _ = try requireCivilToday()
        let restoreDocument = document
        let restorePresentation = transactionPresentation
        do {
            try ExternalEvidenceReview.createTransaction(
                transaction,
                evidence: evidence,
                settling: occurrence,
                resolvedAt: eventNow,
                in: &document
            )
            transactionPresentation[transactionID] = .init(
                categoryKey: kind == .income ? "income" : nil,
                merchant: userLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : userLabel
            )
            if kind == .expense {
                try proposeTrustedRuleDrafts(in: &document, at: eventNow)
            }
            try persistCurrentDocument()
        } catch {
            document = restoreDocument
            transactionPresentation = restorePresentation
            throw bankReviewError(error)
        }
        recalculate()
        return transactionID
    }

    /// Explicit owned-account movement. No FX is inferred: both accounts must
    /// already carry the same currency as the observation.
    @discardableResult
    func createTransfer(from observationID: String, counterpartAccountID: String) throws -> String {
        let previous = beginOperation()
        defer { operationDate = previous }
        let eventNow = operationInstant()
        guard !isFixed else { throw BankReviewError.storeIsReadOnly }
        guard let observation = document.externalObservations.first(where: { $0.id == observationID }),
              let binding = document.externalAccountBindings.first(where: { $0.id == observation.bindingID }),
              let boundAccount = document.accounts.first(where: { $0.id == binding.localAccountID }),
              let counterpart = document.accounts.first(where: { $0.id == counterpartAccountID }) else {
            throw BankReviewError.unknownAccount
        }
        guard counterpart.id != boundAccount.id,
              counterpart.currency == observation.amount.currency,
              boundAccount.currency == observation.amount.currency else {
            throw BankReviewError.invalidAction("Choose another account in the same currency. No FX rate is inferred.")
        }
        let kind: TransactionKind = counterpart.kind == .cash || boundAccount.kind == .cash
            ? .cashWithdrawal : .transfer
        let transactionID = "transaction-\(UUID().uuidString.lowercased())"
        let valueDay = try observation.suggestedEconomicDate ?? requireCivilToday()
        let transaction = Transaction(
            id: transactionID,
            date: valueDay,
            kind: kind,
            legs: [
                AccountLeg(accountID: boundAccount.id, amount: observation.amount),
                AccountLeg(accountID: counterpart.id, amount: observation.amount.negated)
            ],
            factivity: .observed,
            lifecycle: .cleared,
            bookedDate: observation.bookingDate,
            provenance: Provenance(
                source: "EXTERNAL-EVIDENCE-REVIEW",
                evidenceGrade: .userConfirmed,
                reference: observation.id
            )
        )
        _ = try requireCivilToday()
        let restore = document
        do {
            try ExternalEvidenceReview.createTransaction(
                transaction,
                evidence: [ExternalEvidenceAssignment(
                    observationID: observation.id, role: .accountMovement
                )],
                resolvedAt: eventNow,
                in: &document
            )
            try persistCurrentDocument()
        } catch {
            document = restore
            throw bankReviewError(error)
        }
        recalculate()
        return transactionID
    }

    func markObservationNoEconomicEffect(_ observationID: String) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        let eventNow = operationInstant()
        guard !isFixed else { throw BankReviewError.storeIsReadOnly }
        _ = try requireCivilToday()
        let restore = document
        do {
            try ExternalEvidenceReview.markNoEconomicEffect(
                observationID: observationID, resolvedAt: eventNow, in: &document
            )
            try persistCurrentDocument()
        } catch {
            document = restore
            throw bankReviewError(error)
        }
        recalculate()
    }

    /// One serialized production boundary for applying already-approved rules.
    /// Callers supply the newly imported observation ids; this method reloads
    /// decisions from the current document, then Core rechecks the authoritative
    /// manual eligibility path immediately before every mutation.
    @discardableResult
    func processTrustedRules(observationIDs: Set<String>) throws -> TrustedRuleProcessingResult {
        guard !isFixed else { throw BankReviewError.storeIsReadOnly }
        guard trustedAutomationEnabled else { return .empty }
        let orderedIDs = observationIDs.sorted()
        guard !orderedIDs.isEmpty else { return .empty }

        var applied: [String] = []
        var ambiguous: [String] = []
        var failed: [String] = []
        for observationID in orderedIDs {
            // The master switch is re-read at the mutation boundary. The
            // @MainActor store prevents another UI mutation from interleaving
            // inside one application, but no preview result is trusted here.
            guard trustedAutomationEnabled else { break }
            let automatic = TrustedRuleEngine.decisions(for: observationID, in: document)
                .filter { $0.mode == .automaticResolution }
            guard automatic.count <= 1 else {
                ambiguous.append(observationID)
                continue
            }
            guard let decision = automatic.first else { continue }
            do {
                try applyTrustedRule(
                    decision.ruleID,
                    to: observationID
                )
                applied.append(observationID)
            } catch {
                failed.append(observationID)
            }
        }
        return TrustedRuleProcessingResult(
            evaluatedObservationCount: orderedIDs.count,
            appliedObservationIDs: applied,
            ambiguousObservationIDs: ambiguous,
            failedObservationIDs: failed
        )
    }

    /// One observation is one economic persistence unit. A failure restores
    /// this candidate and does not undo prior successful observations or the
    /// separately persisted provider-evidence import.
    private func applyTrustedRule(_ ruleID: String, to observationID: String) throws {
        let previous = beginOperation(independent: true)
        defer { operationDate = previous }
        let eventNow = operationInstant()
        _ = try requireCivilToday()
        var candidate = document
        var candidatePresentation = transactionPresentation
        let application = try TrustedRuleEngine.applyAutomatically(
            ruleID: ruleID,
            observationID: observationID,
            at: eventNow,
            in: &candidate
        )
        candidatePresentation[application.transaction.id] = .init(
            categoryKey: application.categoryKey,
            merchant: application.userLabel
        )
        try ExternalEvidenceReview.validate(candidate)

        let restoreDocument = document
        let restorePresentation = transactionPresentation
        document = candidate
        transactionPresentation = candidatePresentation
        do {
            try persistCurrentDocument()
        } catch {
            document = restoreDocument
            transactionPresentation = restorePresentation
            throw bankReviewError(error)
        }
        recalculate()
    }

    private static func newlyEligibleTrustedAutomationObservationIDs(
        before: FinanceDocument,
        after: FinanceDocument
    ) -> Set<String> {
        let beforeObservations = Dictionary(
            before.externalObservations.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let beforeResolutions = Dictionary(
            before.observationResolutions.map { ($0.observationID, $0.state) },
            uniquingKeysWith: { first, _ in first }
        )
        let afterResolutions = Dictionary(
            after.observationResolutions.map { ($0.observationID, $0.state) },
            uniquingKeysWith: { first, _ in first }
        )
        let activeBindings = Set(
            after.externalAccountBindings.filter(\.isActive).map(\.id)
        )

        return Set(after.externalObservations.compactMap { observation in
            guard activeBindings.contains(observation.bindingID),
                  observation.eligibleForEconomicActual,
                  let resolution = afterResolutions[observation.id],
                  resolution == .unreviewed else { return nil }
            let current = TrustedAutomationObservationSignature(
                observation,
                resolution: resolution
            )
            guard let previousObservation = beforeObservations[observation.id],
                  let previousResolution = beforeResolutions[observation.id] else {
                return observation.id
            }
            let previous = TrustedAutomationObservationSignature(
                previousObservation,
                resolution: previousResolution
            )
            return current == previous ? nil : observation.id
        })
    }

    private func persistTrustedAutomationRetryState(
        _ result: TrustedRuleProcessingResult,
        evaluatedIDs: Set<String>
    ) -> Bool {
        let previous = beginOperation()
        defer { operationDate = previous }
        var retry = appMetadata.trustedAutomationRetryObservationIDs
        retry.subtract(evaluatedIDs)
        retry.formUnion(result.failedObservationIDs)
        retry.formUnion(result.ambiguousObservationIDs)
        guard retry != appMetadata.trustedAutomationRetryObservationIDs else { return false }
        guard civilToday() != nil else { return true }
        appMetadata.trustedAutomationRetryObservationIDs = retry
        do {
            try persistCurrentDocument()
            return false
        } catch {
            // Evidence and any completed per-observation applications are
            // already durable. Keep the retry set in memory and surface a safe
            // diagnostic; a later successful store write can persist it.
            return true
        }
    }

    private static func trustedAutomationDiagnostic(
        for result: TrustedRuleProcessingResult
    ) -> String? {
        if !result.failedObservationIDs.isEmpty {
            return "Some trusted automation could not be completed. The bank evidence is saved for review."
        }
        if !result.ambiguousObservationIDs.isEmpty {
            return "Some new activity remains for review because multiple trusted rules match."
        }
        return nil
    }

    /// Explicit user reversal of one automatic application. The generated
    /// transaction remains historical as a reversed record. Current holdings
    /// recompute from the stored anchor; the reversal does not rewrite it.
    func reverseTrustedRuleApplication(_ applicationAuditEventID: String) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        let eventNow = operationInstant()
        guard !isFixed else { throw BankReviewError.storeIsReadOnly }
        _ = try requireCivilToday()
        var candidate = document
        _ = try TrustedRuleEngine.reverseApplication(
            auditEventID: applicationAuditEventID,
            reversalEventID: "rule-audit-\(UUID().uuidString.lowercased())",
            at: eventNow,
            in: &candidate
        )
        try ExternalEvidenceReview.validate(candidate)

        let restore = document
        document = candidate
        do {
            try persistCurrentDocument()
        } catch {
            document = restore
            throw bankReviewError(error)
        }
        recalculate()
    }

    /// Explicitly clears one persisted reversal veto. This authorizes a future
    /// processing attempt but does not apply anything itself.
    func authorizeTrustedRuleReapplication(ruleID: String, observationID: String) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        let eventNow = operationInstant()
        guard !isFixed else { throw BankReviewError.storeIsReadOnly }
        _ = try requireCivilToday()
        var candidate = document
        try TrustedRuleEngine.clearReapplicationSuppression(
            ruleID: ruleID,
            observationID: observationID,
            at: eventNow,
            auditEventID: "rule-audit-\(UUID().uuidString.lowercased())",
            in: &candidate
        )
        try ExternalEvidenceReview.validate(candidate)

        let restore = document
        document = candidate
        do {
            try persistCurrentDocument()
        } catch {
            document = restore
            throw bankReviewError(error)
        }
        recalculate()
    }

    /// Converts legitimate prior manual confirmations into inactive proposals.
    /// The detector is pure and the draft is persisted in the same atomic write
    /// as the explicit confirmation that made it eligible.
    private func proposeTrustedRuleDrafts(in candidate: inout FinanceDocument, at now: Date) throws {
        let metadata = candidate.transactions.compactMap { transaction -> TrustedRuleConfirmationMetadata? in
            guard let presentation = transactionPresentation[transaction.id] else { return nil }
            return TrustedRuleConfirmationMetadata(
                transactionID: transaction.id,
                categoryKey: presentation.categoryKey,
                userLabel: presentation.merchant
            )
        }
        let proposals = TrustedRuleEngine.proposalCandidates(
            in: candidate,
            confirmationMetadata: metadata
        )
        var knownFingerprints = Set(candidate.trustedRules.map(\.semanticFingerprint))
        for proposal in proposals {
            let evaluation = proposal.makeRule(id: "proposal", createdAt: now)
            guard knownFingerprints.insert(evaluation.semanticFingerprint).inserted else { continue }
            let confirmedAt = proposal.supportingConfirmations.map(\.confirmedAt).max() ?? now
            let rule = proposal.makeRule(
                id: "trusted-rule-\(UUID().uuidString.lowercased())",
                createdAt: max(now, confirmedAt)
            )
            try TrustedRuleEngine.addDraft(
                rule,
                auditEventID: "rule-audit-\(UUID().uuidString.lowercased())",
                in: &candidate
            )
        }
    }

    /// Activates matching as suggestions only. This intentionally changes no
    /// observation resolution, evidence link, balance, or transaction.
    func approveTrustedRuleForSuggestions(_ ruleID: String) throws {
        try approveTrustedRule(ruleID, trustLevel: .suggestionOnly)
    }

    /// Grants automatic trust only when FinanceCore's Phase 2.6 definition
    /// policy allows it. Approval itself does not process existing Inbox rows.
    func approveTrustedRuleForAutomaticHandling(_ ruleID: String) throws {
        try approveTrustedRule(ruleID, trustLevel: .approvedAutomatic)
    }

    private func approveTrustedRule(
        _ ruleID: String,
        trustLevel: TrustedRuleTrustLevel
    ) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        let eventNow = operationInstant()
        guard !isFixed else { throw BankReviewError.storeIsReadOnly }
        guard document.trustedRules.contains(where: { $0.id == ruleID }) else {
            throw BankReviewError.unknownRule
        }
        _ = try requireCivilToday()
        let restore = document
        do {
            try TrustedRuleEngine.approve(
                ruleID: ruleID,
                trustLevel: trustLevel,
                at: eventNow,
                auditEventID: "rule-audit-\(UUID().uuidString.lowercased())",
                in: &document
            )
            try persistCurrentDocument()
        } catch {
            document = restore
            throw bankReviewError(error)
        }
        recalculate()
    }

    /// Disabling is forward-only: it persists an audit event and leaves every
    /// transaction and reviewed observation exactly as it was.
    func disableTrustedRule(_ ruleID: String) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        let eventNow = operationInstant()
        guard !isFixed else { throw BankReviewError.storeIsReadOnly }
        guard document.trustedRules.contains(where: { $0.id == ruleID }) else {
            throw BankReviewError.unknownRule
        }
        _ = try requireCivilToday()
        let restore = document
        do {
            try TrustedRuleEngine.disable(
                ruleID: ruleID,
                at: eventNow,
                auditEventID: "rule-audit-\(UUID().uuidString.lowercased())",
                in: &document
            )
            try persistCurrentDocument()
        } catch {
            document = restore
            throw bankReviewError(error)
        }
        recalculate()
    }

    // MARK: - Live bank sync

    /// Pairs this device with the private sync service.
    ///
    /// The code is used once and never written anywhere: it is a bearer
    /// credential for ten minutes, and the opaque device id it returns is not.
    @discardableResult
    func pairDevice(code: String, label: String) async -> Bool {
        guard let provider = liveClient() else {
            bankSyncActivity = .failed(BankSyncClientError.notConfigured.message)
            return false
        }
        bankSyncActivity = .syncing
        do {
            _ = try await provider.pair(code: code, label: label)
            pairingState = .paired
            bankSyncActivity = .idle
        } catch {
            bankSyncActivity = .failed(Self.syncMessage(error))
            return false
        }
        // Pairing is finished the moment the code is claimed, and the code is
        // single use: the screen must say so immediately rather than staying
        // busy behind a long bank round-trip, or the natural response is to tap
        // again and be told the (now spent) code was rejected.
        await refreshFromService()
        return true
    }

    /// Reads what the service already holds, without asking it to contact the
    /// banks.
    ///
    /// This is what makes account mapping possible straight after pairing: the
    /// backend has been syncing on its own schedule for a while, so its
    /// accounts and evidence are already there to be read in a second or two.
    func refreshFromService() async {
        guard let client = liveClient() else { return }
        do {
            try await readAllEvidence(from: LiveBankSyncProvider(client: client))
        } catch let error as BankSyncClientError {
            if error == .deviceRevoked || error == .unauthorized { pairingState = .revoked }
            bankSyncActivity = .failed(error.message)
        } catch {
            bankSyncActivity = .failed(Self.syncMessage(error))
        }
    }

    /// Forgets this device's pairing and its signing key.
    func unpairDevice() {
        try? identityStore.clear()
        pairingState = BankSyncConfiguration.baseURL() == nil ? .notConfigured : .unpaired
        remoteAccounts = []
        remoteConnections = []
        bankSyncActivity = .idle
    }

    /// Sync Now: ask the backend to talk to the banks, then read the result.
    ///
    /// Failure is contained here. A sync that cannot happen leaves every
    /// balance, transaction, plan and already-synced Inbox item exactly as it
    /// was — the app is not a client of the network, it is a local ledger that
    /// can occasionally be told about a bank.
    func syncNow() async {
        guard let client = liveClient() else {
            bankSyncActivity = .failed(BankSyncClientError.notConfigured.message)
            return
        }
        await syncNow(using: LiveBankSyncProvider(client: client))
    }

    func syncNow(using provider: any BankSyncProviding) async {
        bankSyncActivity = .syncing
        do {
            try await provider.runRemoteSync()
            try await readAllEvidence(from: provider)
            bankSyncActivity = .succeeded(at: clock())
        } catch let error as BankSyncClientError {
            if error == .deviceRevoked || error == .unauthorized { pairingState = .revoked }
            bankSyncActivity = .failed(error.message)
        } catch {
            bankSyncActivity = .failed(Self.syncMessage(error))
        }
    }

    /// Reads every page of evidence, then imports once.
    ///
    /// Importing per page would leave a partial sync visible if a later page
    /// failed; one import keeps the document's evidence graph consistent.
    private func readAllEvidence(from provider: any BankSyncProviding) async throws {
        var since: String?
        var combined = ExternalEvidenceBatch()
        var directory: BankSyncSnapshot?
        var finalPendingAuthority: PendingSnapshotAuthority = .unavailable
        var reachedTerminalPage = false
        // Bounded: a runaway cursor must not loop forever against a live service.
        for _ in 0..<20 {
            let page = try await provider.fetchSnapshot(
                bindings: document.externalAccountBindings,
                // Opaque keyset cursor from `nextSince`. Not a timestamp.
                since: since
            )
            // Connections/accounts are complete on every page too. Retaining
            // the final page keeps displayed provider freshness aligned with
            // the pending membership authority chosen below.
            directory = page
            combined.observations.append(contentsOf: page.batch.observations)
            combined.balances.append(contentsOf: page.batch.balances)
            combined.candidates.append(contentsOf: page.batch.candidates)
            // Pending is a complete current snapshot on every booked-evidence
            // page. Keep the final successfully received page, not a union of
            // states observed at different moments during the page walk.
            finalPendingAuthority = page.pendingAuthority
            guard let next = page.nextSince, !next.isEmpty else {
                reachedTerminalPage = true
                break
            }
            since = next
        }
        guard reachedTerminalPage else {
            // Hitting the safety cap with another cursor is incomplete, not a
            // successful twenty-page snapshot.
            throw BankSyncClientError.malformedResponse
        }

        let authoritativePendingSnapshots: [ExternalProvider: AuthoritativePendingSnapshot]?
        switch finalPendingAuthority {
        case .unavailable:
            authoritativePendingSnapshots = nil
        case let .authoritative(snapshots):
            authoritativePendingSnapshots = snapshots
        case .invalid:
            throw BankSyncClientError.malformedResponse
        }

        // Only a terminal page walk reaches here, so the final directory is a
        // complete provider statement rather than a page-shaped fragment.
        let authoritativeLiveCoverage = directory.map {
            LiveCoverageAuthority.coverage(
                accounts: $0.accounts,
                connections: $0.connections,
                bindings: document.externalAccountBindings
            )
        }

        _ = try importBankEvidence(
            combined,
            authoritativePendingSnapshots: authoritativePendingSnapshots,
            authoritativeLiveCoverage: authoritativeLiveCoverage
        )
        if let directory { applyRemoteDirectory(directory) }
    }

    /// Remote accounts and connections are read-through, not stored.
    ///
    /// Keeping them out of `FinanceDocument` means an export stays a financial
    /// document rather than a record of which backend accounts exist.
    private func applyRemoteDirectory(_ snapshot: BankSyncSnapshot) {
        let previous = beginOperation()
        defer { operationDate = previous }
        if !snapshot.accounts.isEmpty { remoteAccounts = snapshot.accounts }
        if !snapshot.connections.isEmpty { remoteConnections = snapshot.connections }
        recalculate()
    }

    /// Binds one remote account to one local account.
    ///
    /// The cutover defaults to the day the local account's balance was last
    /// stated: everything up to and including that day is already inside the
    /// opening figure, so replaying it would double-count. The person sees the
    /// date before agreeing to it.
    func mapRemoteAccount(
        _ remoteAccountID: String,
        toLocalAccount localAccountID: String,
        boundary: CalendarDay? = nil
    ) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        let eventNow = operationInstant()
        guard !isFixed else { throw BankReviewError.storeIsReadOnly }
        guard let remote = remoteAccounts.first(where: { $0.id == remoteAccountID }) else {
            throw BankReviewError.unknownAccount
        }
        guard document.accounts.contains(where: { $0.id == localAccountID }) else {
            throw BankReviewError.unknownAccount
        }
        guard !document.externalAccountBindings.contains(where: {
            $0.remoteOpaqueAccountID == remoteAccountID || $0.localAccountID == localAccountID
        }) else {
            throw BankReviewError.invalidAction("That account is already mapped.")
        }

        let cutover: Day
        if let boundary {
            guard let day = DomainMapper.day(boundary) else {
                throw BankReviewError.invalidAction("That cutover date is not a calendar day.")
            }
            cutover = day
        } else if let day = defaultBoundary(for: localAccountID) {
            cutover = day
        } else {
            throw BankReviewError.invalidAction("That cutover date is not a calendar day.")
        }
        _ = try requireCivilToday()
        let restore = document
        document.externalAccountBindings.append(
            ExternalAccountBinding(
                id: "binding-\(remoteAccountID)",
                provider: remote.provider,
                remoteOpaqueAccountID: remoteAccountID,
                localAccountID: localAccountID,
                syncStartBoundary: cutover,
                createdAt: eventNow
            )
        )
        do {
            try ExternalEvidenceReview.validate(document)
            try persistCurrentDocument()
        } catch {
            document = restore
            throw bankReviewError(error)
        }
        recalculate()
    }

    /// The opening-balance date for the local account, or today when it has no
    /// stated balance. Never earlier: a boundary before the opening figure is
    /// exactly the double-count this exists to prevent.
    func defaultBoundary(for localAccountID: String) -> Day? {
        document.balances.first { $0.accountID == localAccountID }?.asOf
            ?? civilToday()
    }

    /// The same default, for a `DatePicker`.
    func defaultBoundaryDay(for localAccountID: String) -> CalendarDay? {
        defaultBoundary(for: localAccountID).map(DomainMapper.civilDay)
    }

    /// Removes a mapping. Evidence already reviewed stays readable; the
    /// binding simply stops producing new work.
    func unmapRemoteAccount(bindingID: String) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { throw BankReviewError.storeIsReadOnly }
        guard let index = document.externalAccountBindings.firstIndex(where: { $0.id == bindingID })
        else { throw BankReviewError.unknownAccount }
        _ = try requireCivilToday()
        let restore = document
        document.externalAccountBindings[index].isActive = false
        do {
            try persistCurrentDocument()
        } catch {
            document = restore
            throw bankReviewError(error)
        }
        recalculate()
    }

    private func liveClient() -> BankSyncClient? {
        guard let baseURL = BankSyncConfiguration.baseURL() else { return nil }
        return BankSyncClient(baseURL: baseURL, identity: identityStore)
    }

    /// Sanitizes anything that reaches a person.
    ///
    /// A URLError code, a decoding path or a provider string would leak the
    /// service's shape and tell them nothing they can act on.
    private static func syncMessage(_ error: Error) -> String {
        if let sync = error as? BankSyncClientError { return sync.message }
        if let review = error as? BankReviewError { return review.message }
        if let identity = error as? DeviceIdentityError { return identity.message }
        return "Sync could not complete. Nothing on this device was changed."
    }

    private func bankReviewError(_ error: Error) -> BankReviewError {
        if let review = error as? BankReviewError { return review }
        if let evidence = error as? ExternalEvidenceError {
            return .invalidAction(evidence.description)
        }
        if let rule = error as? TrustedRuleError {
            return .invalidAction(rule.description)
        }
        return .persistenceFailed(Self.safeReason(error))
    }

    // MARK: - Forecast/facade

    private func recalculate() {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed else { return }
        currentDayEvaluation = nil
        let evaluation = makeSnapshotEvaluation(scenario: scenario)
        publishedEvaluation = PublishedFinanceEvaluation(
            snapshot: evaluation, attention: publishedEvaluation.attention
        )
    }

    func snapshot(under scenario: PlanScenario) -> FinanceAppSnapshot {
        let previous = beginOperation()
        defer { operationDate = previous }
        return isFixed ? snapshot : makeSnapshotEvaluation(scenario: scenario).snapshot
    }

    private func makeSnapshotEvaluation(scenario: PlanScenario) -> SnapshotEvaluationContext {
        guard let start = civilToday() else {
            return SnapshotEvaluationContext(snapshot: publishedEvaluation.snapshot.snapshot, projection: .failure)
        }
        var banking = mapper.bankingSurface(
            document: document,
            transactionPresentation: transactionPresentation,
            asOf: start
        )
        let directory = mapper.syncDirectory(
            connections: remoteConnections,
            remoteAccounts: remoteAccounts,
            document: document
        )
        banking.connections = directory.connections
        banking.remoteAccounts = directory.accounts
        banking.pendingSnapshots = appMetadata.authoritativePendingSnapshots
            .map { provider, pending in
                CurrentPendingProviderSnapshot(
                    id: provider.rawValue,
                    providerName: DomainMapper.providerDisplayName(provider),
                    authoritativeAt: pending.authoritativeAt,
                    observationIDs: pending.observationIDs
                )
            }
            .sorted { $0.id < $1.id }
        guard !document.accounts.isEmpty, !document.balances.isEmpty else {
            var empty = FinanceAppSnapshot.empty(asOf: DomainMapper.civilDay(start))
            empty.scenario = scenario
            empty.horizonDays = forecastHorizonDays
            empty.plannedPurchases = mapper.plannedPurchases(document)
            empty.sinkingFunds = mapper.sinkingFunds(document)
            empty.safetyReserve = document.planning.safetyFloor.map(DomainMapper.amount)
            empty.firstBelowReserveDate = nil
            return SnapshotEvaluationContext(
                snapshot: empty.withBanking(banking), projection: .notRequired
            )
        }

        // A horizon whose end day does not exist is a projection that did not
        // happen, reported through the same failure the engine's own errors
        // take. Nothing is shortened and no shell is dressed up as a run.
        guard let horizonEnd = start.advanced(by: forecastHorizonDays - 1) else {
            return SnapshotEvaluationContext(
                snapshot: projectionFailureSnapshot(
                    start: start, scenario: scenario, banking: banking
                ),
                projection: .failure
            )
        }
        let request = ForecastComposer.makeRequest(
            from: document,
            startDate: start,
            endDate: horizonEnd,
            scenario: DomainMapper.scenario(scenario)
        )
        do {
            let result = try forecastRunner(request)
            let overview = FinanceOverview.snapshot(
                document: document,
                result: result,
                today: start,
                horizonDays: safeToSpendWindowDays
            )
            let snapshot = try mapper.snapshot(
                DomainMapper.Inputs(
                    today: start,
                    horizonDays: forecastHorizonDays,
                    document: document,
                    forecast: result,
                    overview: overview,
                    transactionPresentation: transactionPresentation,
                    incomeSourceActive: appMetadata.incomeSourceActive,
                    lastExpenseAccountID: appMetadata.lastExpenseAccountID,
                    lastIncomeAccountID: appMetadata.lastIncomeAccountID
                )
            )
            .withBanking(banking)
            return SnapshotEvaluationContext(
                snapshot: expectedPaymentsSurface().map {
                    snapshot.withReconciliation(
                        expectedPayments: $0,
                        reconciliations: reconciliationsByTransaction()
                    )
                } ?? snapshot,
                projection: .success(result)
            )
        } catch {
            return SnapshotEvaluationContext(
                snapshot: projectionFailureSnapshot(
                    start: start, scenario: scenario, banking: banking
                ),
                projection: .failure
            )
        }
    }

    /// The snapshot shown when no projection was produced.
    private func projectionFailureSnapshot(
        start: Day,
        scenario: PlanScenario,
        banking: DomainMapper.BankingSurface
    ) -> FinanceAppSnapshot {
        let shell = mapper.snapshotWithoutProjection(
            document: document,
            today: start,
            scenario: scenario,
            horizonDays: forecastHorizonDays,
            incomeSourceActive: appMetadata.incomeSourceActive,
            lastExpenseAccountID: appMetadata.lastExpenseAccountID,
            lastIncomeAccountID: appMetadata.lastIncomeAccountID
        )
        guard let expected = expectedPaymentsSurface() else { return shell.withBanking(banking) }
        return shell
            .withReconciliation(
                expectedPayments: expected,
                reconciliations: reconciliationsByTransaction()
            )
            .withBanking(banking)
    }

    /// Builds attention from the exact forecast retained beside this snapshot.
    /// There is intentionally no `ForecastEngine.run` call in this path.
    private func makeAttentionPresentation(
        from evaluation: SnapshotEvaluationContext, freshness: BankFreshness
    ) -> AttentionPresentation {
        guard let asOf = civilToday() else { return .initial() }
        let accountNames = Dictionary(
            document.accounts.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let unavailableAccounts = Set(document.accounts.compactMap { account -> String? in
            guard account.isActive,
                  account.satisfies(.euroBankPayment())
            else { return nil }
            return CurrentHoldings.effective(
                accountID: account.id, asOf: asOf, in: document
            ).hasUsableAmount ? nil : account.id
        })
        let currentPeriod = ReviewInterval.month(asOf.monthKey)
        // Home's current-attention domain stays on today. The ended-month
        // verification proposal, when there is one, is about the most recently
        // ended calendar month — the same period Insights opens at offset -1.
        let endedSelection = ReviewPeriodSelection(scope: .month, offset: -1)
        let endedReview = computeReview(endedSelection)
        let checkpointPeriod: ReviewInterval
        let checkpointReview: ReviewResult?
        let checkpointLabel: String
        if let ended = endedReview, ended.result.interval.end < asOf {
            checkpointPeriod = ended.result.interval
            checkpointReview = ended.result
            checkpointLabel = ReviewPresentationMapper.monthLabel(
                ended.result.interval.start.monthKey
            )
        } else {
            checkpointPeriod = currentPeriod
            checkpointReview = nil
            checkpointLabel = ReviewPresentationMapper.monthLabel(asOf.monthKey)
        }
        let output = AttentionComposition.evaluate(
            AttentionComposition.Input(
                document: document,
                asOf: asOf,
                accountNames: accountNames,
                forecast: evaluation.forecast,
                review: checkpointReview,
                occurrences: expectedOccurrences(),
                observations: evaluation.snapshot.syncedObservations,
                freshness: freshness,
                accountsWithoutUsableAmount: unavailableAccounts,
                categoryKeys: categoryKeysByTransaction,
                checkpointBaseline: PeriodCheckpointBaselineReader.source(
                    from: checkpoints,
                    period: SemanticInterval(checkpointPeriod),
                    kind: .monthly
                ),
                period: checkpointPeriod,
                periodKind: .monthly,
                periodLabel: checkpointLabel
            )
        )
        return AttentionPresentationMapper.present(
            output.attention,
            snapshot: evaluation.snapshot,
            heroIsAvailable: evaluation.safeToUseIsAvailable,
            // Not `safeToUseIsAvailable`: that is the forecast having *run*.
            // This is everything a statement about funding rests on being
            // usable, which is the only basis on which Plan may call a plan
            // funded. A run whose risk was rejected as incoherent, and a gap
            // suppressed because a balance could not be established, both
            // leave no candidate behind — and without this, either absence
            // would read as safety.
            planFundingIsEstablished:
                AttentionFactAdapters.fundingGapDependencies.allSatisfy {
                    output.availability.status($0).isAvailable
                }
        )
    }

    // MARK: - Reconciliation
    //
    // Expected occurrences are expanded on demand and never stored: the rule
    // and the calendar already say what they are. What *is* stored is which
    // occurrences have been answered, and by what.

    /// How far back reconciliation looks. Wide enough to still catch a charge
    /// that was missed for a couple of cycles, narrow enough that the list
    /// stays a to-do rather than an archive.
    private var reconciliationLookbackDays: Int { 120 }

    private var ledger: ReconciliationLedger {
        ReconciliationLedger(document.planning.settlements)
    }

    private func reconciliationContext() -> ReconciliationContext? {
        guard let today = civilToday() else { return nil }
        return ReconciliationContext(
            document: document,
            ledger: ledger,
            today: today,
            titles: transactionPresentation.compactMapValues { $0.merchant }
        )
    }

    /// Dated occurrences across the reconciliation lookback and the forecast
    /// horizon.
    ///
    /// Nil when that window cannot be built. An expansion that did not happen
    /// is reported as one: an empty list here would say every commitment in
    /// the window is answered for, which is a different claim entirely.
    private func expectedOccurrences() -> [ExpectedOccurrence]? {
        guard let start = civilToday() else { return nil }
        guard let from = start.advanced(by: -reconciliationLookbackDays),
              let to = start.advanced(by: forecastHorizonDays - 1)
        else { return nil }
        return OccurrenceExpander.occurrences(
            in: document, from: from, to: to, asOf: start, ledger: ledger
        )
    }

    private func expectedPaymentsSurface() -> [ExpectedPayment]? {
        let accountNames = Dictionary(
            document.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }
        )
        return expectedOccurrences()?.map {
            DomainMapper.expectedPayment($0, accountNames: accountNames)
        }
    }

    private func reconciliationsByTransaction() -> [String: ReconciliationSummary] {
        let obligations = Dictionary(
            document.planning.recurringObligations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }
        )
        let transactions = Dictionary(
            document.transactions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }
        )
        let accountNames = Dictionary(
            document.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }
        )
        var result: [String: ReconciliationSummary] = [:]
        for settlement in document.planning.settlements {
            guard let actualID = settlement.actualTransactionID,
                  let actual = transactions[actualID],
                  let obligation = obligations[settlement.obligationID]
            else { continue }
            let account = actual.legs.first { $0.isOutflow }?.accountID
            result[actualID] = ReconciliationSummary(
                ruleName: obligation.name,
                expectedDate: DomainMapper.civilDay(settlement.expectedDay),
                actualDate: DomainMapper.civilDay(actual.date),
                accountLabel: account.map { accountNames[$0] ?? $0 },
                amountDifferenceAccepted: settlement.acceptedAmountDifference
            )
        }
        return result
    }

    /// Plausible expected payments for one recorded transaction.
    func matches(forTransaction id: String) -> [PaymentMatch] {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard let context = reconciliationContext() else { return [] }
        return surfaceMatches(ReconciliationMatcher.candidates(forActual: id, in: context))
    }

    /// Plausible recorded transactions for one expected payment.
    func matches(forExpectedPayment id: String) -> [PaymentMatch] {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard let occurrence = DomainMapper.occurrenceID(id),
              let context = reconciliationContext()
        else { return [] }
        return surfaceMatches(
            ReconciliationMatcher.candidates(forOccurrence: occurrence, in: context)
        )
    }

    private func surfaceMatches(_ candidates: [MatchCandidate]) -> [PaymentMatch] {
        let accountNames = Dictionary(
            document.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }
        )
        return candidates.map { DomainMapper.paymentMatch($0, accountNames: accountNames) }
    }

    /// Links a recorded transaction to an expected payment.
    ///
    /// The link is only ever made from here, by an explicit act. Nothing in
    /// the matcher writes, and no score is high enough to skip this call.
    func matchPayment(
        expectedPaymentID: String,
        transactionID: String,
        acceptingAmountDifference: Bool = false
    ) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed, loadFailure == nil else { throw AppReconciliationError.storeIsReadOnly }
        guard let occurrence = DomainMapper.occurrenceID(expectedPaymentID) else {
            throw AppReconciliationError.unknownExpectedPayment
        }
        guard document.transactions.contains(where: { $0.id == transactionID }) else {
            throw AppReconciliationError.unknownTransaction
        }
        let current = ledger
        guard !current.isResolved(obligationID: occurrence.obligationID, day: occurrence.expectedDay) else {
            throw AppReconciliationError.alreadyResolved
        }
        guard current.settlement(forActual: transactionID) == nil else {
            throw AppReconciliationError.transactionAlreadyMatched
        }

        // The proposal has to still be on the table, and an inexact amount has
        // to have been accepted deliberately.
        guard let context = reconciliationContext() else {
            throw AppReconciliationError.refused("The current day could not be read.")
        }
        let candidates = ReconciliationMatcher.candidates(
            forOccurrence: occurrence, in: context
        )
        guard let candidate = candidates.first(where: { $0.actualTransactionID == transactionID }) else {
            throw AppReconciliationError.refused(
                "That transaction is not a plausible match for this expected payment."
            )
        }
        if candidate.requiresAmountConfirmation && !acceptingAmountDifference {
            throw AppReconciliationError.amountDiffersWithoutConfirmation
        }

        try commitSettlement(
            .paid(
                id: DomainMapper.settlementID(occurrence),
                obligationID: occurrence.obligationID,
                expectedDay: occurrence.expectedDay,
                actualTransactionID: transactionID,
                acceptedAmountDifference: candidate.requiresAmountConfirmation,
                provenance: Provenance(source: "MANUAL-RECONCILIATION", evidenceGrade: .userConfirmed)
            )
        )
    }

    /// Resolves an occurrence without a payment: skipped this cycle, or not
    /// coming at all. Neither touches the recurring rule.
    func skipExpectedPayment(id: String) throws {
        try resolve(id) { occurrence in
            .skipped(
                id: DomainMapper.settlementID(occurrence),
                obligationID: occurrence.obligationID,
                expectedDay: occurrence.expectedDay,
                provenance: Provenance(source: "MANUAL-RECONCILIATION", evidenceGrade: .userConfirmed)
            )
        }
    }

    func markExpectedPaymentNoLongerDue(id: String) throws {
        try resolve(id) { occurrence in
            .noLongerDue(
                id: DomainMapper.settlementID(occurrence),
                obligationID: occurrence.obligationID,
                expectedDay: occurrence.expectedDay,
                provenance: Provenance(source: "MANUAL-RECONCILIATION", evidenceGrade: .userConfirmed)
            )
        }
    }

    private func resolve(
        _ expectedPaymentID: String,
        _ make: (OccurrenceID) -> ObligationSettlement
    ) throws {
        guard !isFixed, loadFailure == nil else { throw AppReconciliationError.storeIsReadOnly }
        guard let occurrence = DomainMapper.occurrenceID(expectedPaymentID) else {
            throw AppReconciliationError.unknownExpectedPayment
        }
        guard !ledger.isResolved(obligationID: occurrence.obligationID, day: occurrence.expectedDay) else {
            throw AppReconciliationError.alreadyResolved
        }
        try commitSettlement(make(occurrence))
    }

    /// Undoes a reconciliation. The transaction and the rule both stay; only
    /// the link between them goes, and the occurrence becomes a question again.
    func unmatchExpectedPayment(id: String) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        guard !isFixed, loadFailure == nil else { throw AppReconciliationError.storeIsReadOnly }
        guard let occurrence = DomainMapper.occurrenceID(id) else {
            throw AppReconciliationError.unknownExpectedPayment
        }
        _ = try requireCivilToday()
        let restore = document.planning.settlements
        document.planning.settlements.removeAll { $0.occurrence == occurrence }
        guard document.planning.settlements.count != restore.count else { return }
        do {
            try persistCurrentDocument()
        } catch {
            document.planning.settlements = restore
            throw AppReconciliationError.persistenceFailed(String(describing: error))
        }
        recalculate()
    }

    private func commitSettlement(_ settlement: ObligationSettlement) throws {
        let previous = beginOperation()
        defer { operationDate = previous }
        _ = try requireCivilToday()
        let restore = document.planning.settlements
        document.planning.settlements.append(settlement)
        do {
            try ReconciliationLedger.validate(document.planning.settlements, against: document)
            try persistCurrentDocument()
        } catch let problem as ReconciliationError {
            document.planning.settlements = restore
            throw AppReconciliationError.refused(problem.description)
        } catch {
            document.planning.settlements = restore
            throw AppReconciliationError.persistenceFailed(String(describing: error))
        }
        recalculate()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
