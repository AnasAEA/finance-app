import Foundation
import FinanceCore

/// Reads a chosen file as a `FinanceDocument` and describes it, without writing
/// anything and without letting a single byte of it reach a log, an error
/// message or the screen verbatim.
///
/// Three gates, in order, none of which touches the store:
///
/// 1. **decode** — is this a `FinanceDocument` at all;
/// 2. **schema validate** — is it a version this build implements;
/// 3. **semantic validate** — does it say things that can all be true at once.
///
/// Only after all three does anything get built for the screen, and only after
/// the person confirms does anything get written. The separation is the point:
/// a document this build cannot read must not first destroy the one it can.
enum DocumentImporter {

    // MARK: - Reading

    /// Reads the bytes at `url`, decodes them, and throws them away.
    ///
    /// The `Data` is local to this call. The app keeps no copy of the chosen
    /// file: what survives is the normalized graph, which is the thing the app
    /// actually uses. A second copy of a document holding someone's salary and
    /// arrears is a liability with no reader.
    static func read(contentsOf url: URL) throws -> FinanceDocument {
        // A file handed over by the document picker lives outside the app
        // container and needs its scope opened before it can be read.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // The underlying error can name a path outside the container. The
            // path is not the person's money, but it is not ours to print
            // either, and nothing downstream can act on it.
            throw AppImportError.fileUnreadable
        }
        return try decode(data)
    }

    /// Gate 1 and gate 2: decode, then check the schema version.
    static func decode(_ data: Data) throws -> FinanceDocument {
        let document: FinanceDocument
        do {
            document = try Interchange.decode(data)
        } catch InterchangeError.unsupportedSchemaVersion(let found) {
            throw AppImportError.unsupportedSchemaVersion(found: found, supported: PersistedSchema.supported)
        } catch let error as DecodingError {
            throw sanitized(error)
        } catch {
            throw AppImportError.notAFinanceDocument(field: nil, reason: .notJSON)
        }

        do {
            try PersistedSchema.validate(document.schemaVersion)
        } catch {
            throw AppImportError.unsupportedSchemaVersion(
                found: document.schemaVersion,
                supported: PersistedSchema.supported
            )
        }
        return document
    }

    /// A `DecodingError` reduced to its shape and its field path.
    ///
    /// `debugDescription` is deliberately dropped. FinanceCore's own decoders
    /// quote the offending value into it — `"Invalid money string '960.00
    /// EUR'"`, `"transaction 'tx-rent-august': ownership over-allocation:
    /// 900.00 EUR allocated against 800.00 EUR"` — and that is the file's
    /// contents. The coding path is structure, not content, and structure is
    /// what a person needs in order to go and fix the export.
    private static func sanitized(_ error: DecodingError) -> AppImportError {
        switch error {
        case let .keyNotFound(key, context):
            .notAFinanceDocument(field: path(context.codingPath + [key]), reason: .missingField)
        case let .typeMismatch(_, context):
            .notAFinanceDocument(field: path(context.codingPath), reason: .wrongType)
        case let .valueNotFound(_, context):
            .notAFinanceDocument(field: path(context.codingPath), reason: .missingField)
        case let .dataCorrupted(context):
            .notAFinanceDocument(field: path(context.codingPath), reason: .unreadableValue)
        @unknown default:
            .notAFinanceDocument(field: nil, reason: .unreadableValue)
        }
    }

    /// `["balances", 2, "asOf"]` → `balances[2].asOf`. Keys and indices only.
    private static func path(_ codingPath: [any CodingKey]) -> String? {
        guard !codingPath.isEmpty else { return nil }
        var rendered = ""
        for key in codingPath {
            if let index = key.intValue {
                rendered += "[\(index)]"
            } else {
                rendered += rendered.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return rendered.isEmpty ? nil : rendered
    }

    // MARK: - Gate 3: semantic validation

    /// What has to hold across the whole document before any of it is written.
    ///
    /// Structural duplicates are caught again by `StoredDocumentGraph.validate`
    /// on the way to disk; catching them here as well is what lets the preview
    /// refuse *before* showing a person a summary of a document that will not
    /// import. Every check is a refusal, never a repair: dropping the second
    /// balance or inventing the missing account would turn a broken export into
    /// a plausible, silently wrong one.
    static func semanticValidate(_ document: FinanceDocument) throws {
        func fail(_ problem: AppImportError.SemanticProblem) -> AppImportError {
            .inconsistentDocument(problem)
        }

        guard !StoredDocumentGraph.containsUnrepresentableOperationalMoney(document) else {
            throw fail(.unrepresentableAmount)
        }

        guard !document.accounts.isEmpty else { throw fail(.noAccounts) }

        var accountsByID: [String: Account] = [:]
        for account in document.accounts {
            guard accountsByID.updateValue(account, forKey: account.id) == nil else {
                throw fail(.duplicateAccount(id: account.id))
            }
        }

        var balancesByAccount: [String: AccountBalance] = [:]
        for balance in document.balances {
            guard let account = accountsByID[balance.accountID] else {
                throw fail(.balanceForUnknownAccount(accountID: balance.accountID))
            }
            guard balancesByAccount.updateValue(balance, forKey: balance.accountID) == nil else {
                throw fail(.duplicateBalance(accountID: balance.accountID))
            }
            guard balance.balance.currency == account.currency else {
                throw fail(.balanceCurrencyMismatch(accountID: balance.accountID))
            }
        }

        // An account with no balance is not neutral: the holdings list is built
        // from balances, so it would import and then be invisible on every
        // screen — present in the store, absent from the money.
        for account in document.accounts where balancesByAccount[account.id] == nil {
            throw fail(.accountWithoutBalance(accountID: account.id))
        }

        try requireUniqueIdentifiers(document)

        do {
            try PlanningValidation.validate(document)
        } catch {
            throw fail(.invalidPlanning)
        }

        for transaction in document.transactions + document.expectedTransactions {
            for leg in transaction.legs where accountsByID[leg.accountID] == nil {
                throw fail(
                    .transactionOnUnknownAccount(
                        transactionID: transaction.id,
                        accountID: leg.accountID
                    )
                )
            }
        }

        for source in document.incomeSources {
            guard let arrival = source.arrivesOnAccount else { continue }
            guard accountsByID[arrival] != nil else {
                throw fail(.incomeSourceOnUnknownAccount(sourceID: source.id, accountID: arrival))
            }
        }

        for accountID in document.planning.carriedEURValues.keys where accountsByID[accountID] == nil {
            throw fail(.carriedValueForUnknownAccount(accountID: accountID))
        }

        // External observations and links are durable backup data in 1.3.
        // Validate them before showing an import preview; confirm must not be
        // the first point where a broken evidence graph is discovered.
        do {
            try ExternalEvidenceReview.validate(document)
        } catch {
            throw fail(.invalidExternalEvidence)
        }
    }

    private static func requireUniqueIdentifiers(_ document: FinanceDocument) throws {
        func requireUnique(_ kind: String, _ ids: [String]) throws {
            var seen: Set<String> = []
            for id in ids where !seen.insert(id).inserted {
                throw AppImportError.inconsistentDocument(.duplicateRecord(kind: kind, id: id))
            }
        }
        // Observed and expected share one identifier space: they are stored in
        // one table and are one document's worth of events.
        try requireUnique(
            "transaction",
            (document.transactions + document.expectedTransactions).map(\.id)
        )
        try requireUnique("income source", document.incomeSources.map(\.id))
        try requireUnique("instalment plan", document.installments.map(\.id))
        try requireUnique("debt", document.debts.map(\.id))
        try requireUnique("recurring commitment", document.planning.recurringObligations.map(\.id))
        try requireUnique("budget", document.planning.budgets.map(\.id))
        try requireUnique("planned purchase", document.planning.plannedPurchases.map(\.id))
        try requireUnique("sinking fund", document.planning.sinkingFunds.map(\.id))
    }

    // MARK: - Preview

    /// The summary shown before anything is written.
    ///
    /// Headline liquidity is the same `CurrentHoldings` split Home uses, so the
    /// preview and the Home screen that follows it cannot disagree. Account
    /// rows keep the stored observed anchors and their as-of days so a stale
    /// opening figure can still be corrected.
    static func preview(of document: FinanceDocument, today: Day) throws -> ImportPreview {
        let balances = Dictionary(
            document.balances.map { ($0.accountID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let current = Dictionary(
            uniqueKeysWithValues: CurrentHoldings.overlayBalances(in: document, asOf: today).map {
                ($0.accountID, $0)
            }
        )

        let electronic = CurrentHoldings.euroFinancialAccountLiquidity(in: document, asOf: today)
        var cashByCurrency: [String: Amount] = [:]
        var accounts: [ImportAccountPreview] = []

        for account in document.accounts.sorted(by: { $0.drawOrder < $1.drawOrder }) {
            guard let balance = balances[account.id] else { continue }
            let isCash = account.kind == .cash
            let spendable = !isCash && account.currency == .eur
            if isCash, let holding = current[account.id] {
                let amount = DomainMapper.amount(holding.balance)
                cashByCurrency[amount.currencyCode] = cashByCurrency[amount.currencyCode]
                    .map { $0 + amount } ?? amount
            }
            accounts.append(
                ImportAccountPreview(
                    id: account.id,
                    name: account.name,
                    kind: holdingKind(account.kind),
                    currencyCode: account.currency.code,
                    fractionDigits: account.currency.minorUnitDigits,
                    balance: DomainMapper.amount(balance.balance),
                    asOf: DomainMapper.civilDay(balance.asOf),
                    freshness: try freshness(of: balance.asOf, today: today, accountID: account.id),
                    isSpendableHere: spendable,
                    isActive: account.isActive
                )
            )
        }

        let debtOutstanding = document.debts
            .filter { $0.status == .active }
            .reduce(Int64(0)) { $0 + $1.originalAmount.minorUnits }
        let installmentRemaining = document.installments
            .filter { $0.status == .active }
            .reduce(Int64(0)) { $0 + $1.remainingAmount.minorUnits }

        return ImportPreview(
            sourceLabel: document.documentKind,
            schemaVersion: document.schemaVersion,
            note: document.note,
            accounts: accounts,
            electronicLiquidity: DomainMapper.amount(electronic),
            physicalCash: cashByCurrency.values
                .sorted { $0.currencyCode < $1.currencyCode }
                .map(CurrencyTotal.init(amount:)),
            debtOutstanding: Amount(minorUnits: debtOutstanding, currencyCode: Currency.eur.code),
            debtCount: document.debts.filter { $0.status == .active }.count,
            unscheduledDebtCount: document.debts
                .filter { $0.status == .active && $0.paymentSchedule.isEmpty }.count,
            installmentCount: document.installments.filter { $0.status == .active }.count,
            installmentRemaining: Amount(
                minorUnits: installmentRemaining,
                currencyCode: Currency.eur.code
            ),
            recurringCommitmentCount: document.planning.recurringObligations
                .filter { $0.commitmentStatus == .committed }.count,
            uncommittedCommitmentCount: document.planning.recurringObligations
                .filter { $0.commitmentStatus != .committed }.count,
            incomeSourceCount: document.incomeSources.count,
            observedTransactionCount: document.transactions.count,
            expectedTransactionCount: document.expectedTransactions.count,
            budgetCount: document.planning.budgets.count
        )
    }

    /// How old a stored anchor is, as an exact number of days.
    ///
    /// An age that cannot be expressed is not "today" and not zero days old.
    /// It is a balance whose vintage this import cannot state, so the file is
    /// refused — sanitized, by account identifier, never by date or amount.
    private static func freshness(
        of asOf: Day, today: Day, accountID: String
    ) throws -> BalanceFreshness {
        guard let offset = asOf.days(until: today) else {
            throw AppImportError.inconsistentDocument(.undatableBalance(accountID: accountID))
        }
        if offset == 0 { return .today }
        guard offset < 0 else { return .daysOld(offset) }
        // `offset < 0`; `magnitude` never negates, so `Int.min` is safe here —
        // and a distance that extreme is not representable in the first place.
        guard let ahead = Int(exactly: offset.magnitude) else {
            throw AppImportError.inconsistentDocument(.undatableBalance(accountID: accountID))
        }
        return .dated(daysAhead: ahead)
    }

    private static func holdingKind(_ kind: AccountKind) -> HoldingKind {
        switch kind {
        case .bank: .bank
        case .wallet: .wallet
        case .cash: .cash
        }
    }

    // MARK: - Corrections

    /// Applies the balances the reviewer confirmed or corrected.
    ///
    /// A corrected balance is `observed` as of the day the person stated: they
    /// looked at the account and said what was in it, which is exactly what
    /// that status means. An untouched balance keeps the export's own figure,
    /// date and status.
    static func applying(
        _ corrections: [ImportBalanceCorrection],
        to document: FinanceDocument
    ) throws -> FinanceDocument {
        guard !corrections.isEmpty else { return document }
        let byAccount = Dictionary(
            corrections.map { ($0.accountID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var corrected = document
        corrected.balances = try document.balances.map { balance in
            guard let correction = byAccount[balance.accountID] else { return balance }
            // A correction denominated in another currency is not a correction
            // of this balance. Dropping it keeps the export's own figure rather
            // than writing a euro number onto a dirham pocket.
            guard correction.balance.currencyCode == balance.balance.currency.code else {
                return balance
            }
            guard let asOf = DomainMapper.day(correction.asOf) else {
                throw AppImportError.inconsistentDocument(.undatableBalance(accountID: balance.accountID))
            }
            return AccountBalance(
                accountID: balance.accountID,
                balance: DomainMapper.money(correction.balance),
                asOf: asOf,
                status: .observed
            )
        }
        return corrected
    }

    // MARK: - Result

    /// Describes what a store actually holds, for the post-import confirmation.
    static func summary(of document: FinanceDocument, today: Day) throws -> ImportSummary {
        let preview = try preview(of: document, today: today)
        return ImportSummary(
            accountCount: document.accounts.count,
            recurringCommitmentCount: document.planning.recurringObligations.count,
            incomeSourceCount: document.incomeSources.count,
            installmentCount: document.installments.count,
            expectedTransactionCount: document.expectedTransactions.count,
            observedTransactionCount: document.transactions.count,
            debtOutstanding: preview.debtOutstanding,
            electronicLiquidity: preview.electronicLiquidity,
            physicalCash: preview.physicalCash
        )
    }
}
