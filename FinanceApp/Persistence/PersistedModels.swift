import Foundation
import SwiftData
import FinanceCore

/// The production store is an app-owned, normalized projection of
/// `FinanceDocument`. The document remains the import/export contract; it is
/// deliberately not persisted as one opaque JSON value.
///
/// Phase 1 data was pre-alpha fixture data, so this is a clean schema reset.
/// There is intentionally no migration stage from the disposable UUID/two-leg
/// schema. Once real user data exists, every later schema change must ship a
/// real migration plan.

/// Why stored rows could not be read back as financial truth.
///
/// Every case is a refusal, not a repair. A stored token this build does not
/// recognise is either corruption or a document from a version that means
/// something different by it; turning it into a plausible default — `expense`,
/// `observed`, `bank` — would convert unreadable data into confidently wrong
/// accounting, which is the one outcome worse than failing to open.
enum PersistenceMappingError: Error, Equatable, CustomStringConvertible {
    case invalidCurrencyMetadata
    case unrepresentableDay
    case unrepresentableMonth
    case unsupportedEncodedValue
    case corruptDay(Int32)
    case corruptMonth(Int32)
    /// A stored value that no longer decodes, e.g. a recurrence blob.
    case corruptEncodedValue(field: String, value: String)
    /// A stored token outside the vocabulary this build understands.
    case unknownEnumValue(field: String, value: String)
    case unsupportedSchemaVersion(found: String, supported: [String])
    /// More than one current balance for one account. The store keeps one row
    /// per account, so a second would silently replace the first.
    case duplicateAccountBalance(accountID: String)
    case duplicateAccountIdentifier(id: String)
    case duplicateTransactionIdentifier(id: String)
    case missingDocumentRoot
    /// A reconciliation that breaks one of the settlement invariants — an
    /// occurrence settled twice, one actual spent on two occurrences, a link
    /// to something that is not there. Never repaired by dropping the row:
    /// silently discarding a reconciliation would put a paid obligation back
    /// into the forecast as unpaid.
    case invalidReconciliation(String)
    case invalidExternalEvidence(String)
    case invalidPlanning(String)
    case unrepresentableOperationalMoney
    case invalidDocument

    var description: String {
        switch self {
        case .invalidDocument: "The financial document has inconsistent records or currency relationships."
        case .invalidCurrencyMetadata: "stored currency metadata is invalid"
        case .unrepresentableDay: "this calendar day cannot be stored"
        case .unrepresentableMonth: "this calendar month cannot be stored"
        case .unsupportedEncodedValue: "a nested value could not be encoded for storage"
        case let .corruptDay(value): "stored day ordinal \(value) is not a calendar day"
        case let .corruptMonth(value): "stored month ordinal \(value) is not a calendar month"
        case let .corruptEncodedValue(field, value): "stored value for '\(field)' is unreadable (\(value))"
        case let .unknownEnumValue(field, value): "stored '\(field)' value '\(value)' is not a value this build understands"
        case let .unsupportedSchemaVersion(found, supported):
            "document schema \(found) is not supported (supported: \(supported.joined(separator: ", ")))"
        case let .duplicateAccountBalance(accountID): "more than one current balance for account '\(accountID)'"
        case let .duplicateAccountIdentifier(id): "more than one account with identifier '\(id)'"
        case let .duplicateTransactionIdentifier(id): "more than one transaction with identifier '\(id)'"
        case .missingDocumentRoot: "the operational document root is missing"
        case let .invalidReconciliation(reason): "reconciliation is not valid: \(reason)"
        case let .invalidExternalEvidence(reason): "external evidence is not valid: \(reason)"
        case let .invalidPlanning(reason): "planning is not valid: \(reason)"
        case .unrepresentableOperationalMoney:
            "an amount cannot be safely used in operational calculations"
        }
    }
}

/// Which document schemas this build will read or write.
///
/// Writing always produces `current`. Reading additionally accepts the earlier
/// additive minor versions, because refusing them would strand exports taken
/// before a field existed — a 1.1.0 document is a 1.3.0 document with nothing
/// reconciled or externally evidenced, which this build can represent exactly. A version
/// that is *not* on this list is refused rather than decoded on the assumption
/// that its fields still mean what they used to; anything needing real
/// migration logic gets that logic and a place here, together.
enum PersistedSchema {
    static let current = Interchange.currentSchemaVersion
    static let supported: [String] = Interchange.readableSchemaVersions.sorted()

    static func validate(_ version: String) throws {
        guard supported.contains(version) else {
            throw PersistenceMappingError.unsupportedSchemaVersion(found: version, supported: supported)
        }
    }
}

enum PersistenceCoding {
    static func ordinal(_ day: Day) throws -> Int32 {
        guard let value = day.checkedPersistenceOrdinal else {
            throw PersistenceMappingError.unrepresentableDay
        }
        return value
    }

    static func ordinal(_ day: Day?) throws -> Int32? {
        try day.map { try ordinal($0) }
    }

    static func ordinal(_ month: MonthKey) throws -> Int32 {
        guard let value = month.checkedPersistenceOrdinal else {
            throw PersistenceMappingError.unrepresentableMonth
        }
        return value
    }

    static func ordinal(_ month: MonthKey?) throws -> Int32? {
        try month.map { try ordinal($0) }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try JSONEncoder().encode(value) }
        catch { throw PersistenceMappingError.unsupportedEncodedValue }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, field: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch {
            throw PersistenceMappingError.corruptEncodedValue(
                field: field,
                value: String(data: data.prefix(64), encoding: .utf8) ?? "\(data.count) bytes"
            )
        }
    }

    /// A stored token read back as the enum it names, or a refusal.
    static func decodeEnum<T: RawRepresentable>(
        _ type: T.Type,
        _ raw: T.RawValue,
        field: String
    ) throws -> T {
        guard let value = T(rawValue: raw) else {
            throw PersistenceMappingError.unknownEnumValue(field: field, value: "\(raw)")
        }
        return value
    }
}

extension Day {
    /// Existing Int32 YYYYMMDD representation, when it can round-trip.
    var checkedPersistenceOrdinal: Int32? {
        guard (0...Int(Int32.max) / 10_000).contains(year) else { return nil }
        return Int32(exactly: year * 10_000 + month * 100 + day)
    }

    init?(persistenceOrdinal value: Int32) {
        let integer = Int(value)
        guard let decoded = Day(
            validatingYear: integer / 10_000, month: (integer / 100) % 100, day: integer % 100
        ), decoded.checkedPersistenceOrdinal == value else { return nil }
        self = decoded
    }
}

extension MonthKey {
    var checkedPersistenceOrdinal: Int32? {
        guard (0...Int(Int32.max) / 100).contains(year) else { return nil }
        return Int32(exactly: year * 100 + month)
    }

    init?(persistenceOrdinal value: Int32) {
        let integer = Int(value)
        guard let decoded = MonthKey(validatingYear: integer / 100, month: integer % 100),
              decoded.checkedPersistenceOrdinal == value else { return nil }
        self = decoded
    }
}

private extension Currency {
    static func persisted(code: String, exponent: Int) throws -> Currency {
        do { return try Currency.validating(code: code, exponent: exponent) }
        catch { throw PersistenceMappingError.invalidCurrencyMetadata }
    }
}

private extension PaymentRail {
    static func persisted(_ token: String) -> PaymentRail {
        switch token {
        case PaymentRail.sepaCreditTransfer.id: .sepaCreditTransfer
        case PaymentRail.sepaDirectDebit.id: .sepaDirectDebit
        case PaymentRail.cardDebit.id: .cardDebit
        case PaymentRail.electronicPayment.id: .electronicPayment
        case PaymentRail.physicalCash.id: .physicalCash
        default: PaymentRail(id: token, summary: token)
        }
    }
}

@Model
final class StoredDocumentMeta {
    #Unique<StoredDocumentMeta>([\.identifier])

    var identifier: String = "primary"
    var schemaVersion: String = Interchange.currentSchemaVersion
    var documentKind: String = ""
    var note: String?
    var documentRevision: String = ""
    var writtenByCoreCommit: String = "130fe2f502baaaceb17c8523fb2dc50bccb91ffa"
    var writtenOnDay: Int32 = 0
    var defaultScenarioRaw: String?
    var safetyFloorMinor: Int64?
    var safetyFloorCurrencyCode: String?
    var safetyFloorCurrencyExponent: Int?
    var monthlyCeilingMinor: Int64?
    var monthlyCeilingCurrencyCode: String?
    var monthlyCeilingCurrencyExponent: Int?

    init(document: FinanceDocument, writtenOn: Day) throws {
        let encodedWrittenOnDay = try PersistenceCoding.ordinal(writtenOn)

        schemaVersion = document.schemaVersion
        documentKind = document.documentKind
        note = document.note
        documentRevision = UUID().uuidString
        writtenOnDay = encodedWrittenOnDay
        defaultScenarioRaw = document.planning.defaultScenario?.rawValue
        safetyFloorMinor = document.planning.safetyFloor?.minorUnits
        safetyFloorCurrencyCode = document.planning.safetyFloor?.currency.code
        safetyFloorCurrencyExponent = document.planning.safetyFloor?.currency.minorUnitDigits
        monthlyCeilingMinor = document.planning.monthlyEconomicCeiling?.minorUnits
        monthlyCeilingCurrencyCode = document.planning.monthlyEconomicCeiling?.currency.code
        monthlyCeilingCurrencyExponent = document.planning.monthlyEconomicCeiling?.currency.minorUnitDigits
    }

    var defaultScenario: Scenario? {
        get throws {
            try defaultScenarioRaw.map {
                try PersistenceCoding.decodeEnum(Scenario.self, $0, field: "planning.defaultScenario")
            }
        }
    }

    var safetyFloor: Money? {
        get throws {
            guard let safetyFloorMinor,
                  let safetyFloorCurrencyCode,
                  let safetyFloorCurrencyExponent else { return nil }
            return Money(
                minorUnits: safetyFloorMinor,
                currency: try .persisted(code: safetyFloorCurrencyCode, exponent: safetyFloorCurrencyExponent)
            )
        }
    }

    var monthlyEconomicCeiling: Money? {
        get throws {
            guard let monthlyCeilingMinor,
                  let monthlyCeilingCurrencyCode,
                  let monthlyCeilingCurrencyExponent else { return nil }
            return Money(
                minorUnits: monthlyCeilingMinor,
                currency: try .persisted(code: monthlyCeilingCurrencyCode, exponent: monthlyCeilingCurrencyExponent)
            )
        }
    }
}

@Model
final class StoredAccount {
    #Unique<StoredAccount>([\.identifier])

    var identifier: String = ""
    var documentSequence: Int = 0
    var name: String = ""
    var kindRaw: String = AccountKind.bank.rawValue
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    /// Stable semantic tokens, never OptionSet bit positions.
    var railTokens: [String] = []
    var isActive: Bool = true
    var drawOrder: Int = 0

    init(_ account: Account, sequence: Int) {
        identifier = account.id
        documentSequence = sequence
        name = account.name
        kindRaw = account.kind.rawValue
        currencyCode = account.currency.code
        currencyExponent = account.currency.minorUnitDigits
        railTokens = account.supportedRails.map(\.id).sorted()
        isActive = account.isActive
        drawOrder = account.drawOrder
    }

    var asDomain: Account {
        get throws {
            Account(
                id: identifier,
                name: name,
                currency: try .persisted(code: currencyCode, exponent: currencyExponent),
                kind: try PersistenceCoding.decodeEnum(AccountKind.self, kindRaw, field: "account.kind"),
                supportedRails: Set(railTokens.map(PaymentRail.persisted)),
                isActive: isActive,
                drawOrder: drawOrder
            )
        }
    }
}

@Model
final class StoredAccountBalance {
    #Unique<StoredAccountBalance>([\.identifier])
    #Index<StoredAccountBalance>([\.asOfDay])

    var identifier: String = ""
    var documentSequence: Int = 0
    var accountIdentifier: String = ""
    var amountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    var asOfDay: Int32 = 0
    var statusRaw: String = BalanceStatus.observed.rawValue

    init(_ balance: AccountBalance, sequence: Int) throws {
        let encodedAsOfDay = try PersistenceCoding.ordinal(balance.asOf)

        identifier = balance.accountID
        documentSequence = sequence
        accountIdentifier = balance.accountID
        amountMinor = balance.balance.minorUnits
        currencyCode = balance.balance.currency.code
        currencyExponent = balance.balance.currency.minorUnitDigits
        asOfDay = encodedAsOfDay
        statusRaw = balance.status.rawValue
    }

    var asDomain: AccountBalance {
        get throws {
            guard let day = Day(persistenceOrdinal: asOfDay) else {
                throw PersistenceMappingError.corruptDay(asOfDay)
            }
            return AccountBalance(
                accountID: accountIdentifier,
                balance: Money(
                    minorUnits: amountMinor,
                    currency: try .persisted(code: currencyCode, exponent: currencyExponent)
                ),
                asOf: day,
                status: try PersistenceCoding.decodeEnum(BalanceStatus.self, statusRaw, field: "balance.status")
            )
        }
    }
}

@Model
final class StoredTransaction {
    #Unique<StoredTransaction>([\.identifier])
    #Index<StoredTransaction>([\.valueDay])

    var identifier: String = ""
    var documentSequence: Int = 0
    var valueDay: Int32 = 0
    var bookedDay: Int32?
    var kindRaw: String = TransactionKind.expense.rawValue
    var factivityRaw: String = Factivity.observed.rawValue
    var lifecycleRaw: String = TransactionLifecycle.cleared.rawValue
    var datePrecisionRaw: String = DatePrecision.exact.rawValue
    var certaintyRaw: Int?
    var linkedTransactionIdentifier: String?
    var incomeSourceIdentifier: String?
    var installmentPlanIdentifier: String?
    var note: String?
    var provenanceSource: String = ""
    var provenanceEvidenceGradeRaw: String = Provenance.EvidenceGrade.unresolved.rawValue
    var provenanceReference: String?
    var appCategoryKey: String?
    var appMerchant: String?

    @Relationship(deleteRule: .cascade, inverse: \StoredAccountLeg.transaction)
    var legs: [StoredAccountLeg] = []

    @Relationship(deleteRule: .cascade, inverse: \StoredOwnershipSplit.transaction)
    var ownership: [StoredOwnershipSplit] = []

    init(
        _ transaction: Transaction,
        sequence: Int,
        categoryKey: String? = nil,
        merchant: String? = nil
    ) throws {
        let encodedValueDay = try PersistenceCoding.ordinal(transaction.date)
        let encodedBookedDay = try PersistenceCoding.ordinal(transaction.bookedDate)
        let encodedLegs = try transaction.legs.enumerated().map {
            try StoredAccountLeg($0.element, transactionID: transaction.id, sequence: $0.offset, valueDay: transaction.date)
        }

        identifier = transaction.id
        documentSequence = sequence
        valueDay = encodedValueDay
        bookedDay = encodedBookedDay
        kindRaw = transaction.kind.rawValue
        factivityRaw = transaction.factivity.rawValue
        lifecycleRaw = transaction.lifecycle.rawValue
        datePrecisionRaw = transaction.datePrecision.rawValue
        certaintyRaw = transaction.certainty?.rawValue
        linkedTransactionIdentifier = transaction.linkedTransactionID
        incomeSourceIdentifier = transaction.incomeSourceID
        installmentPlanIdentifier = transaction.installmentPlanID
        note = transaction.note
        provenanceSource = transaction.provenance.source
        provenanceEvidenceGradeRaw = transaction.provenance.evidenceGrade.rawValue
        provenanceReference = transaction.provenance.reference
        appCategoryKey = categoryKey
        appMerchant = merchant

        legs = encodedLegs
        ownership = (transaction.ownership ?? []).enumerated().map {
            StoredOwnershipSplit($0.element, transactionID: transaction.id, sequence: $0.offset)
        }
        legs.forEach { $0.transaction = self }
        ownership.forEach { $0.transaction = self }
    }

    /// The stored factivity, refused rather than defaulted when unrecognised.
    /// Partitioning observed facts from expectations on a guessed value would
    /// move a plan into history, or history into a plan.
    var factivity: Factivity {
        get throws {
            try PersistenceCoding.decodeEnum(Factivity.self, factivityRaw, field: "transaction.factivity")
        }
    }

    var asDomain: Transaction {
        get throws {
            guard let date = Day(persistenceOrdinal: valueDay) else {
                throw PersistenceMappingError.corruptDay(valueDay)
            }
            let booked: Day?
            if let bookedDay {
                guard let value = Day(persistenceOrdinal: bookedDay) else {
                    throw PersistenceMappingError.corruptDay(bookedDay)
                }
                booked = value
            } else {
                booked = nil
            }

            let domainLegs = try legs.sorted { $0.sequence < $1.sequence }.map { try $0.asDomain }
            let splits = try ownership.sorted { $0.sequence < $1.sequence }.map { try $0.asDomain }
            return Transaction(
                id: identifier,
                date: date,
                kind: try PersistenceCoding.decodeEnum(TransactionKind.self, kindRaw, field: "transaction.kind"),
                legs: domainLegs,
                ownership: splits.isEmpty ? nil : splits,
                linkedTransactionID: linkedTransactionIdentifier,
                incomeSourceID: incomeSourceIdentifier,
                installmentPlanID: installmentPlanIdentifier,
                factivity: try factivity,
                lifecycle: try PersistenceCoding.decodeEnum(TransactionLifecycle.self, lifecycleRaw, field: "transaction.lifecycle"),
                bookedDate: booked,
                datePrecision: try PersistenceCoding.decodeEnum(DatePrecision.self, datePrecisionRaw, field: "transaction.datePrecision"),
                certainty: try certaintyRaw.map {
                    try PersistenceCoding.decodeEnum(IncomeCertainty.self, $0, field: "transaction.certainty")
                },
                note: note,
                provenance: Provenance(
                    source: provenanceSource,
                    evidenceGrade: try PersistenceCoding.decodeEnum(
                        Provenance.EvidenceGrade.self,
                        provenanceEvidenceGradeRaw,
                        field: "transaction.provenance.evidenceGrade"
                    ),
                    reference: provenanceReference
                )
            )
        }
    }
}

@Model
final class StoredAccountLeg {
    #Unique<StoredAccountLeg>([\.identifier])
    #Index<StoredAccountLeg>([\.accountIdentifier, \.valueDay])

    var identifier: String = ""
    var sequence: Int = 0
    var accountIdentifier: String = ""
    var amountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    /// Semantic string token. FinanceCore 1.1.0 does not expose roles yet.
    var roleRaw: String = "principal"
    var valueDay: Int32 = 0
    var transaction: StoredTransaction?

    init(_ leg: AccountLeg, transactionID: String, sequence: Int, valueDay: Day) throws {
        let encodedValueDay = try PersistenceCoding.ordinal(valueDay)

        identifier = "\(transactionID)#leg-\(sequence)"
        self.sequence = sequence
        accountIdentifier = leg.accountID
        amountMinor = leg.amount.minorUnits
        currencyCode = leg.amount.currency.code
        currencyExponent = leg.amount.currency.minorUnitDigits
        self.valueDay = encodedValueDay
    }

    var asDomain: AccountLeg {
        get throws {
            AccountLeg(
                accountID: accountIdentifier,
                amount: Money(
                    minorUnits: amountMinor,
                    currency: try .persisted(code: currencyCode, exponent: currencyExponent)
                )
            )
        }
    }
}

@Model
final class StoredOwnershipSplit {
    #Unique<StoredOwnershipSplit>([\.identifier])

    var identifier: String = ""
    var sequence: Int = 0
    var ownerIdentifier: String = ""
    var isSelf: Bool = false
    var amountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    /// Exact amounts are authoritative; shares are never floating point.
    var basisRaw: String = "exact_amount"
    var transaction: StoredTransaction?

    init(_ split: OwnershipSplit, transactionID: String, sequence: Int) {
        identifier = "\(transactionID)#owner-\(sequence)"
        self.sequence = sequence
        ownerIdentifier = split.ownerID
        isSelf = split.isSelf
        amountMinor = split.amount.minorUnits
        currencyCode = split.amount.currency.code
        currencyExponent = split.amount.currency.minorUnitDigits
    }

    var asDomain: OwnershipSplit {
        get throws {
            OwnershipSplit(
                ownerID: ownerIdentifier,
                isSelf: isSelf,
                amount: Money(
                    minorUnits: amountMinor,
                    currency: try .persisted(code: currencyCode, exponent: currencyExponent)
                )
            )
        }
    }
}

@Model
final class StoredIncomeSource {
    #Unique<StoredIncomeSource>([\.identifier])

    var identifier: String = ""
    var documentSequence: Int = 0
    var name: String = ""
    var amountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    var certaintyRaw: Int = IncomeCertainty.expected.rawValue
    var recurrenceData: Data = Data()
    var dependsOnIdentifiers: [String] = []
    var arrivesOnAccountIdentifier: String?
    var note: String?
    /// App workflow state, deliberately outside FinanceCore economics. A
    /// retired source still maps back to the same domain identity so historical
    /// `incomeSourceID` links continue to resolve.
    var appIsActive: Bool = true

    init(_ source: IncomeSource, sequence: Int, appIsActive: Bool = true) throws {
        let encodedRecurrenceData = try PersistenceCoding.encode(source.schedule)

        identifier = source.id
        documentSequence = sequence
        name = source.name
        amountMinor = source.amount.minorUnits
        currencyCode = source.amount.currency.code
        currencyExponent = source.amount.currency.minorUnitDigits
        certaintyRaw = source.certainty.rawValue
        recurrenceData = encodedRecurrenceData
        dependsOnIdentifiers = source.dependsOn
        arrivesOnAccountIdentifier = source.arrivesOnAccount
        note = source.note
        self.appIsActive = appIsActive
    }

    var asDomain: IncomeSource {
        get throws {
            IncomeSource(
                id: identifier,
                name: name,
                amount: Money(
                    minorUnits: amountMinor,
                    currency: try .persisted(code: currencyCode, exponent: currencyExponent)
                ),
                certainty: try PersistenceCoding.decodeEnum(IncomeCertainty.self, certaintyRaw, field: "income.certainty"),
                schedule: try PersistenceCoding.decode(RecurrenceSpec.self, from: recurrenceData, field: "income.schedule"),
                dependsOn: dependsOnIdentifiers,
                arrivesOnAccount: arrivesOnAccountIdentifier,
                note: note
            )
        }
    }
}

/// The last complete current-pending view imported for one provider.
///
/// This is app-local transport state, not part of `FinanceDocument`: provider
/// evidence remains append-only history there. Absence of a row means the app
/// has never established authority for that provider; a row whose identifiers
/// are empty means the provider authoritatively reported no current pending
/// evidence.
struct AuthoritativePendingSnapshot: Codable, Hashable, Sendable {
    let authoritativeAt: Date
    let observationIDs: Set<String>
}

extension AuthoritativePendingSnapshot {
    private enum CodingKeys: String, CodingKey { case authoritativeAt, observationIDs }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authoritativeAt = try c.decode(Date.self, forKey: .authoritativeAt)
        let ids = try c.decode([String].self, forKey: .observationIDs)
        guard Set(ids).count == ids.count else { throw AppImportError.invalidBackupMetadata }
        observationIDs = Set(ids)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(authoritativeAt, forKey: .authoritativeAt)
        try c.encode(observationIDs.sorted(), forKey: .observationIDs)
    }
}

@Model
final class StoredAuthoritativePendingSnapshot {
    #Unique<StoredAuthoritativePendingSnapshot>([\.providerRaw])

    var providerRaw: String = ""
    var authoritativeAt: Date = Date.distantPast
    var observationIdentifiers: [String] = []

    init(
        provider: ExternalProvider,
        snapshot: AuthoritativePendingSnapshot
    ) {
        providerRaw = provider.rawValue
        authoritativeAt = snapshot.authoritativeAt
        observationIdentifiers = snapshot.observationIDs.sorted()
    }

    var provider: ExternalProvider { ExternalProvider(rawValue: providerRaw) }

    var snapshot: AuthoritativePendingSnapshot {
        AuthoritativePendingSnapshot(
            authoritativeAt: authoritativeAt,
            observationIDs: Set(observationIdentifiers)
        )
    }
}

/// One remote account's affirmative provider-fetch coverage window.
///
/// The backend records this only *after* a transaction fetch for that account
/// succeeds, from the window it actually requested — never from the dates of
/// the rows that came back. So an account is covered for a window in which the
/// bank reported nothing, which is the whole reason review coverage reads this
/// instead of observation dates.
///
/// Both bounds are **inclusive** civil days. Like pending membership this is
/// app-local operational metadata: it is not part of `FinanceDocument` and
/// never reaches the interchange schema. Absence of a value for an account
/// means UNKNOWN — never "covered for nothing" and never a window inferred
/// from the binding's `syncStartBoundary`.
struct AuthoritativeLiveCoverage: Codable, Hashable, Sendable {
    let provider: ExternalProvider
    let remoteOpaqueAccountID: String
    let localAccountID: String
    let syncedFrom: Day
    let syncedThrough: Day
    /// Provider `lastSuccessfulSyncAt` carried with the window that it
    /// authorised. Not a local request-completion clock.
    let authoritativeAt: Date

    var interval: ReviewInterval? {
        syncedFrom <= syncedThrough
            ? ReviewInterval(start: syncedFrom, end: syncedThrough)
            : nil
    }
}

@Model
final class StoredAuthoritativeLiveCoverage {
    #Unique<StoredAuthoritativeLiveCoverage>([\.providerRaw, \.remoteOpaqueAccountIdentifier])

    var providerRaw: String = ""
    /// Backend-generated `acct_…` handle only, matching the binding. No IBAN
    /// or provider identification hash reaches this layer.
    var remoteOpaqueAccountIdentifier: String = ""
    var localAccountIdentifier: String = ""
    var syncedFromDay: Int32 = 0
    var syncedThroughDay: Int32 = 0
    var authoritativeAt: Date = Date.distantPast

    init(_ coverage: AuthoritativeLiveCoverage) throws {
        let encodedSyncedFromDay = try PersistenceCoding.ordinal(coverage.syncedFrom)
        let encodedSyncedThroughDay = try PersistenceCoding.ordinal(coverage.syncedThrough)

        providerRaw = coverage.provider.rawValue
        remoteOpaqueAccountIdentifier = coverage.remoteOpaqueAccountID
        localAccountIdentifier = coverage.localAccountID
        syncedFromDay = encodedSyncedFromDay
        syncedThroughDay = encodedSyncedThroughDay
        authoritativeAt = coverage.authoritativeAt
    }

    /// A corrupt stored day makes the row unreadable rather than a guessed
    /// window: the account falls back to UNKNOWN, which is fail-closed.
    var asDomain: AuthoritativeLiveCoverage? {
        guard let from = Day(persistenceOrdinal: syncedFromDay),
              let through = Day(persistenceOrdinal: syncedThroughDay)
        else { return nil }
        return AuthoritativeLiveCoverage(
            provider: ExternalProvider(rawValue: providerRaw),
            remoteOpaqueAccountID: remoteOpaqueAccountIdentifier,
            localAccountID: localAccountIdentifier,
            syncedFrom: from,
            syncedThrough: through,
            authoritativeAt: authoritativeAt
        )
    }
}

@Model
final class StoredEntryPreferences {
    #Unique<StoredEntryPreferences>([\.identifier])

    var identifier: String = "primary"
    var lastExpenseAccountIdentifier: String?
    var lastIncomeAccountIdentifier: String?
    /// Additive local safety control. Older stores materialize the declared
    /// default and never opt into economic automation during migration.
    var trustedAutomationEnabled: Bool = false
    var trustedAutomationRetryObservationIdentifiers: [String] = []
    /// 0 = unknown legacy cache (do not reconstruct). 1+ = immutable-anchor
    /// current-holdings model. Lightweight default keeps old stores readable.
    var currentHoldingsModelVersion: Int = 0
    /// Opaque booked keyset checkpoint. This is app-local transport state,
    /// outside the financial document and its exports.
    var bankEvidenceCursor: String? = nil
    var bankEvidenceCursorBindingIDs: [String] = []
    var bankEvidenceCursorDeviceID: String? = nil

    init(
        lastExpenseAccountIdentifier: String?,
        lastIncomeAccountIdentifier: String?,
        trustedAutomationEnabled: Bool = false,
        trustedAutomationRetryObservationIdentifiers: [String] = [],
        currentHoldingsModelVersion: Int = 0,
        bankEvidenceCursor: String? = nil,
        bankEvidenceCursorBindingIDs: [String] = [],
        bankEvidenceCursorDeviceID: String? = nil
    ) {
        self.lastExpenseAccountIdentifier = lastExpenseAccountIdentifier
        self.lastIncomeAccountIdentifier = lastIncomeAccountIdentifier
        self.trustedAutomationEnabled = trustedAutomationEnabled
        self.trustedAutomationRetryObservationIdentifiers =
            trustedAutomationRetryObservationIdentifiers
        self.currentHoldingsModelVersion = currentHoldingsModelVersion
        self.bankEvidenceCursor = bankEvidenceCursor
        self.bankEvidenceCursorBindingIDs = bankEvidenceCursorBindingIDs
        self.bankEvidenceCursorDeviceID = bankEvidenceCursorDeviceID
    }
}

struct AppPersistenceMetadata: Hashable, Sendable {
    var incomeSourceActive: [String: Bool] = [:]
    var lastExpenseAccountID: String?
    var lastIncomeAccountID: String?
    var trustedAutomationEnabled = false
    var trustedAutomationRetryObservationIDs: Set<String> = []
    /// Provider absence is unknown; a present value may deliberately contain
    /// an empty set after a successful zero-pending snapshot.
    var authoritativePendingSnapshots: [ExternalProvider: AuthoritativePendingSnapshot] = [:]
    /// Keyed by remote opaque account id. Absence of a key is UNKNOWN
    /// coverage for that account, which fails review coverage closed.
    var authoritativeLiveCoverage: [String: AuthoritativeLiveCoverage] = [:]
    var currentHoldingsModelVersion = 0
    var bankEvidenceCursor: String? = nil
    var bankEvidenceCursorBindingIDs: [String] = []
    var bankEvidenceCursorDeviceID: String? = nil

    static let empty = AppPersistenceMetadata()
}

@Model
final class StoredRecurringObligation {
    #Unique<StoredRecurringObligation>([\.identifier])

    var identifier: String = ""
    var documentSequence: Int = 0
    var name: String = ""
    var amountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    var recurrenceData: Data = Data()
    var requiredCurrencyCode: String = "EUR"
    var requiredCurrencyExponent: Int = 2
    var requiredRailTokens: [String] = []
    var spendingClassRaw: String = SpendingClass.essential.rawValue
    var commitmentStatusRaw: String = CommitmentStatus.committed.rawValue
    /// The budget line this obligation is committed against, when the plan
    /// links it. Nil stays nil: no mapping is inferred here either.
    var budgetIdentifier: String?
    var note: String?

    init(_ obligation: RecurringObligation, sequence: Int) throws {
        let encodedRecurrenceData = try PersistenceCoding.encode(obligation.spec)

        identifier = obligation.id
        documentSequence = sequence
        name = obligation.name
        amountMinor = obligation.amount.minorUnits
        currencyCode = obligation.amount.currency.code
        currencyExponent = obligation.amount.currency.minorUnitDigits
        recurrenceData = encodedRecurrenceData
        requiredCurrencyCode = obligation.requirement.currency.code
        requiredCurrencyExponent = obligation.requirement.currency.minorUnitDigits
        requiredRailTokens = obligation.requirement.acceptableRails.map(\.id).sorted()
        spendingClassRaw = obligation.spendingClass.rawValue
        commitmentStatusRaw = obligation.commitmentStatus.rawValue
        budgetIdentifier = obligation.budgetID
        note = obligation.note
    }

    var asDomain: RecurringObligation {
        get throws {
            RecurringObligation(
                id: identifier,
                name: name,
                amount: Money(
                    minorUnits: amountMinor,
                    currency: try .persisted(code: currencyCode, exponent: currencyExponent)
                ),
                spec: try PersistenceCoding.decode(RecurrenceSpec.self, from: recurrenceData, field: "obligation.spec"),
                requirement: PaymentRequirement(
                    currency: try .persisted(code: requiredCurrencyCode, exponent: requiredCurrencyExponent),
                    acceptableRails: Set(requiredRailTokens.map(PaymentRail.persisted))
                ),
                spendingClass: try PersistenceCoding.decodeEnum(SpendingClass.self, spendingClassRaw, field: "obligation.spendingClass"),
                commitmentStatus: try PersistenceCoding.decodeEnum(CommitmentStatus.self, commitmentStatusRaw, field: "obligation.commitmentStatus"),
                budgetID: budgetIdentifier,
                note: note
            )
        }
    }
}

@Model
final class StoredBudgetAllocation {
    #Unique<StoredBudgetAllocation>([\.identifier])

    var identifier: String = ""
    var documentSequence: Int = 0
    var name: String = ""
    var spendingClassRaw: String = SpendingClass.flexible.rawValue
    var monthlyAmountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    var effectiveFromMonth: Int32 = 0
    var effectiveThroughMonth: Int32?
    /// Defaults to `suggested`: a row written before confirmation existed
    /// cannot be read as the person having agreed to its target.
    var confirmationRaw: String = BudgetConfirmation.suggested.rawValue
    var categoryKeys: [String] = []

    @Relationship(deleteRule: .cascade, inverse: \StoredBudgetOverride.budget)
    var overrides: [StoredBudgetOverride] = []

    init(_ budget: BudgetAllocation, sequence: Int) throws {
        let encodedEffectiveFromMonth = try PersistenceCoding.ordinal(budget.effectiveFrom)
        let encodedEffectiveThroughMonth = try PersistenceCoding.ordinal(budget.effectiveThrough)
        let encodedOverrides = try budget.monthlyOverrides.sorted { $0.key < $1.key }.map {
            try StoredBudgetOverride(month: $0.key, amount: $0.value, budgetID: budget.id)
        }

        identifier = budget.id
        documentSequence = sequence
        name = budget.name
        spendingClassRaw = budget.spendingClass.rawValue
        monthlyAmountMinor = budget.monthlyAmount.minorUnits
        currencyCode = budget.monthlyAmount.currency.code
        currencyExponent = budget.monthlyAmount.currency.minorUnitDigits
        effectiveFromMonth = encodedEffectiveFromMonth
        effectiveThroughMonth = encodedEffectiveThroughMonth
        confirmationRaw = budget.confirmation.rawValue
        categoryKeys = budget.categoryKeys
        overrides = encodedOverrides
        overrides.forEach { $0.budget = self }
    }

    var asDomain: BudgetAllocation {
        get throws {
            guard let from = MonthKey(persistenceOrdinal: effectiveFromMonth) else {
                throw PersistenceMappingError.corruptMonth(effectiveFromMonth)
            }
            let through: MonthKey?
            if let effectiveThroughMonth {
                guard let value = MonthKey(persistenceOrdinal: effectiveThroughMonth) else {
                    throw PersistenceMappingError.corruptMonth(effectiveThroughMonth)
                }
                through = value
            } else {
                through = nil
            }
            return BudgetAllocation(
                id: identifier,
                name: name,
                spendingClass: try PersistenceCoding.decodeEnum(SpendingClass.self, spendingClassRaw, field: "budget.spendingClass"),
                monthlyAmount: Money(
                    minorUnits: monthlyAmountMinor,
                    currency: try .persisted(code: currencyCode, exponent: currencyExponent)
                ),
                effectiveFrom: from,
                effectiveThrough: through,
                monthlyOverrides: try Dictionary(
                    uniqueKeysWithValues: overrides.map { (try $0.month, try $0.amount) }
                ),
                confirmation: try PersistenceCoding.decodeEnum(
                    BudgetConfirmation.self, confirmationRaw, field: "budget.confirmation"
                ),
                categoryKeys: categoryKeys
            )
        }
    }
}

@Model
final class StoredBudgetOverride {
    #Unique<StoredBudgetOverride>([\.identifier])

    var identifier: String = ""
    var monthOrdinal: Int32 = 0
    var amountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    var budget: StoredBudgetAllocation?

    init(month: MonthKey, amount: Money, budgetID: String) throws {
        let encodedMonthOrdinal = try PersistenceCoding.ordinal(month)
        let encodedIdentifier = try Self.persistedIdentifier(month: month, budgetID: budgetID)

        monthOrdinal = encodedMonthOrdinal
        identifier = encodedIdentifier
        amountMinor = amount.minorUnits
        currencyCode = amount.currency.code
        currencyExponent = amount.currency.minorUnitDigits
    }

    /// ID generation has the same domain as the row's ordinal, even when used
    /// before constructing a model. Ordinary IDs are byte-for-byte unchanged.
    static func persistedIdentifier(month: MonthKey, budgetID: String) throws -> String {
        _ = try PersistenceCoding.ordinal(month)
        return "\(budgetID)#\(month.isoString)"
    }

    var month: MonthKey {
        get throws {
            guard let month = MonthKey(persistenceOrdinal: monthOrdinal) else {
                throw PersistenceMappingError.corruptMonth(monthOrdinal)
            }
            return month
        }
    }

    var amount: Money {
        get throws {
            Money(
                minorUnits: amountMinor,
                currency: try .persisted(code: currencyCode, exponent: currencyExponent)
            )
        }
    }
}

@Model
final class StoredPlannedPurchase {
    #Unique<StoredPlannedPurchase>([\.identifier])

    var identifier: String = ""
    var documentSequence: Int = 0
    var name: String = ""
    var targetAmountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    var targetDay: Int32?
    var statusRaw: String = PlannedPurchaseStatus.planned.rawValue
    var fundingKindRaw: String = "cash_on_purchase"
    var sinkingFundIdentifier: String?
    var reservedAmountMinor: Int64 = 0
    var purchasedTransactionIdentifier: String?
    var installmentPlanIdentifier: String?
    var budgetIdentifier: String?
    var requiredCurrencyCode: String = "EUR"
    var requiredCurrencyExponent: Int = 2
    var requiredRailTokens: [String] = []
    var note: String?

    init(_ purchase: PlannedPurchase, sequence: Int) throws {
        let encodedTargetDay = try PersistenceCoding.ordinal(purchase.targetDate)

        identifier = purchase.id
        documentSequence = sequence
        name = purchase.name
        targetAmountMinor = purchase.targetAmount.minorUnits
        currencyCode = purchase.targetAmount.currency.code
        currencyExponent = purchase.targetAmount.currency.minorUnitDigits
        targetDay = encodedTargetDay
        statusRaw = purchase.status.rawValue
        switch purchase.funding {
        case .cashOnPurchase:
            fundingKindRaw = "cash_on_purchase"
            sinkingFundIdentifier = nil
        case let .sinkingFund(id):
            fundingKindRaw = "sinking_fund"
            sinkingFundIdentifier = id
        case .financing:
            fundingKindRaw = "financing"
            sinkingFundIdentifier = nil
        }
        reservedAmountMinor = purchase.reservedAmount.minorUnits
        purchasedTransactionIdentifier = purchase.purchasedTransactionID
        installmentPlanIdentifier = purchase.installmentPlanID
        budgetIdentifier = purchase.budgetID
        requiredCurrencyCode = purchase.requirement.currency.code
        requiredCurrencyExponent = purchase.requirement.currency.minorUnitDigits
        requiredRailTokens = purchase.requirement.acceptableRails.map(\.id).sorted()
        note = purchase.note
    }

    var asDomain: PlannedPurchase {
        get throws {
            let targetDate: Day?
            if let targetDay {
                guard let day = Day(persistenceOrdinal: targetDay) else {
                    throw PersistenceMappingError.corruptDay(targetDay)
                }
                targetDate = day
            } else {
                targetDate = nil
            }
            let currency = try Currency.persisted(code: currencyCode, exponent: currencyExponent)
            let funding: PlannedPurchaseFunding
            switch fundingKindRaw {
            case "cash_on_purchase":
                funding = .cashOnPurchase
            case "sinking_fund":
                guard let sinkingFundIdentifier else {
                    throw PersistenceMappingError.corruptEncodedValue(
                        field: "plannedPurchase.funding", value: fundingKindRaw
                    )
                }
                funding = .sinkingFund(id: sinkingFundIdentifier)
            case "financing":
                funding = .financing
            default:
                throw PersistenceMappingError.unknownEnumValue(
                    field: "plannedPurchase.funding", value: fundingKindRaw
                )
            }
            return PlannedPurchase(
                id: identifier,
                name: name,
                targetAmount: Money(minorUnits: targetAmountMinor, currency: currency),
                targetDate: targetDate,
                status: try PersistenceCoding.decodeEnum(
                    PlannedPurchaseStatus.self, statusRaw, field: "plannedPurchase.status"
                ),
                funding: funding,
                reservedAmount: Money(minorUnits: reservedAmountMinor, currency: currency),
                purchasedTransactionID: purchasedTransactionIdentifier,
                installmentPlanID: installmentPlanIdentifier,
                budgetID: budgetIdentifier,
                requirement: PaymentRequirement(
                    currency: try .persisted(code: requiredCurrencyCode, exponent: requiredCurrencyExponent),
                    acceptableRails: Set(requiredRailTokens.map(PaymentRail.persisted))
                ),
                note: note
            )
        }
    }
}

@Model
final class StoredSinkingFund {
    #Unique<StoredSinkingFund>([\.identifier])

    var identifier: String = ""
    var documentSequence: Int = 0
    var name: String = ""
    var goalIdentifier: String?
    var targetAmountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    var reservedAmountMinor: Int64 = 0
    var contributionAmountMinor: Int64?
    var contributionScheduleData: Data?
    var custodyKindRaw: String = "virtual"
    var dedicatedAccountIdentifier: String?
    var statusRaw: String = SinkingFundStatus.active.rawValue
    var note: String?

    init(_ fund: SinkingFund, sequence: Int) throws {
        let encodedContributionScheduleData = try fund.contributionSchedule.map { try PersistenceCoding.encode($0) }

        identifier = fund.id
        documentSequence = sequence
        name = fund.name
        goalIdentifier = fund.goalID
        targetAmountMinor = fund.targetAmount.minorUnits
        currencyCode = fund.targetAmount.currency.code
        currencyExponent = fund.targetAmount.currency.minorUnitDigits
        reservedAmountMinor = fund.reservedAmount.minorUnits
        contributionAmountMinor = fund.contributionAmount?.minorUnits
        contributionScheduleData = encodedContributionScheduleData
        switch fund.custody {
        case .virtualReservation:
            custodyKindRaw = "virtual"
            dedicatedAccountIdentifier = nil
        case let .dedicatedAccount(accountID):
            custodyKindRaw = "dedicated_account"
            dedicatedAccountIdentifier = accountID
        }
        statusRaw = fund.status.rawValue
        note = fund.note
    }

    var asDomain: SinkingFund {
        get throws {
            let currency = try Currency.persisted(code: currencyCode, exponent: currencyExponent)
            let custody: SinkingFundCustody
            switch custodyKindRaw {
            case "virtual":
                custody = .virtualReservation
            case "dedicated_account":
                guard let dedicatedAccountIdentifier else {
                    throw PersistenceMappingError.corruptEncodedValue(
                        field: "sinkingFund.custody", value: custodyKindRaw
                    )
                }
                custody = .dedicatedAccount(accountID: dedicatedAccountIdentifier)
            default:
                throw PersistenceMappingError.unknownEnumValue(
                    field: "sinkingFund.custody", value: custodyKindRaw
                )
            }
            let contribution: Money?
            if let contributionAmountMinor {
                contribution = Money(minorUnits: contributionAmountMinor, currency: currency)
            } else {
                contribution = nil
            }
            let schedule: RecurrenceSpec?
            if let contributionScheduleData {
                schedule = try PersistenceCoding.decode(
                    RecurrenceSpec.self, from: contributionScheduleData, field: "sinkingFund.contributionSchedule"
                )
            } else {
                schedule = nil
            }
            return SinkingFund(
                id: identifier,
                name: name,
                goalID: goalIdentifier,
                targetAmount: Money(minorUnits: targetAmountMinor, currency: currency),
                reservedAmount: Money(minorUnits: reservedAmountMinor, currency: currency),
                contributionAmount: contribution,
                contributionSchedule: schedule,
                custody: custody,
                status: try PersistenceCoding.decodeEnum(
                    SinkingFundStatus.self, statusRaw, field: "sinkingFund.status"
                ),
                note: note
            )
        }
    }
}

@Model
final class StoredInstallmentPlan {
    #Unique<StoredInstallmentPlan>([\.identifier])

    var identifier: String = ""
    var documentSequence: Int = 0
    var provider: String = ""
    var purchaseDescription: String = ""
    var note: String?
    var purchaseDay: Int32?
    var originalAmountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    var requiredCurrencyCode: String = "EUR"
    var requiredCurrencyExponent: Int = 2
    var requiredRailTokens: [String] = []
    var commitmentStatusRaw: String = CommitmentStatus.committed.rawValue
    var statusRaw: String = InstallmentPlan.Status.active.rawValue

    @Relationship(deleteRule: .cascade, inverse: \StoredInstallment.plan)
    var installments: [StoredInstallment] = []

    init(_ plan: InstallmentPlan, sequence: Int) throws {
        let encodedPurchaseDay = try PersistenceCoding.ordinal(plan.purchaseDate)
        let encodedInstallments = try plan.installments.map { try StoredInstallment($0, planID: plan.id) }

        identifier = plan.id
        documentSequence = sequence
        provider = plan.provider
        purchaseDescription = plan.purchaseDescription
        note = plan.note
        purchaseDay = encodedPurchaseDay
        originalAmountMinor = plan.originalPurchaseAmount.minorUnits
        currencyCode = plan.originalPurchaseAmount.currency.code
        currencyExponent = plan.originalPurchaseAmount.currency.minorUnitDigits
        requiredCurrencyCode = plan.paymentRequirement.currency.code
        requiredCurrencyExponent = plan.paymentRequirement.currency.minorUnitDigits
        requiredRailTokens = plan.paymentRequirement.acceptableRails.map(\.id).sorted()
        commitmentStatusRaw = plan.commitmentStatus.rawValue
        statusRaw = plan.status.rawValue
        installments = encodedInstallments
        installments.forEach { $0.plan = self }
    }

    var asDomain: InstallmentPlan {
        get throws {
            let purchaseDate: Day?
            if let purchaseDay {
                guard let value = Day(persistenceOrdinal: purchaseDay) else {
                    throw PersistenceMappingError.corruptDay(purchaseDay)
                }
                purchaseDate = value
            } else {
                purchaseDate = nil
            }
            return InstallmentPlan(
                id: identifier,
                provider: provider,
                purchaseDescription: purchaseDescription,
                note: note,
                purchaseDate: purchaseDate,
                originalPurchaseAmount: Money(
                    minorUnits: originalAmountMinor,
                    currency: try .persisted(code: currencyCode, exponent: currencyExponent)
                ),
                installments: try installments.sorted { $0.sequence < $1.sequence }.map { try $0.asDomain },
                paymentRequirement: PaymentRequirement(
                    currency: try .persisted(code: requiredCurrencyCode, exponent: requiredCurrencyExponent),
                    acceptableRails: Set(requiredRailTokens.map(PaymentRail.persisted))
                ),
                commitmentStatus: try PersistenceCoding.decodeEnum(CommitmentStatus.self, commitmentStatusRaw, field: "installmentPlan.commitmentStatus"),
                status: try PersistenceCoding.decodeEnum(InstallmentPlan.Status.self, statusRaw, field: "installmentPlan.status")
            )
        }
    }
}

@Model
final class StoredInstallment {
    #Unique<StoredInstallment>([\.identifier])
    #Index<StoredInstallment>([\.dueDay])

    var identifier: String = ""
    var sequence: Int = 0
    var dueDay: Int32 = 0
    var amountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    var statusRaw: String = PaymentStatus.scheduled.rawValue
    var paidOnDay: Int32?
    var plan: StoredInstallmentPlan?

    init(_ installment: Installment, planID: String) throws {
        let encodedDueDay = try PersistenceCoding.ordinal(installment.dueDate)
        let encodedPaidOnDay = try PersistenceCoding.ordinal(installment.paidOn)

        identifier = "\(planID)#installment-\(installment.sequence)"
        sequence = installment.sequence
        dueDay = encodedDueDay
        amountMinor = installment.amount.minorUnits
        currencyCode = installment.amount.currency.code
        currencyExponent = installment.amount.currency.minorUnitDigits
        statusRaw = installment.status.rawValue
        paidOnDay = encodedPaidOnDay
    }

    var asDomain: Installment {
        get throws {
            guard let dueDate = Day(persistenceOrdinal: dueDay) else {
                throw PersistenceMappingError.corruptDay(dueDay)
            }
            let paidOn: Day?
            if let paidOnDay {
                guard let value = Day(persistenceOrdinal: paidOnDay) else {
                    throw PersistenceMappingError.corruptDay(paidOnDay)
                }
                paidOn = value
            } else {
                paidOn = nil
            }
            return Installment(
                sequence: sequence,
                dueDate: dueDate,
                amount: Money(
                    minorUnits: amountMinor,
                    currency: try .persisted(code: currencyCode, exponent: currencyExponent)
                ),
                status: try PersistenceCoding.decodeEnum(PaymentStatus.self, statusRaw, field: "installment.status"),
                paidOn: paidOn
            )
        }
    }
}

@Model
final class StoredDebt {
    #Unique<StoredDebt>([\.identifier])

    var identifier: String = ""
    var documentSequence: Int = 0
    var name: String = ""
    var note: String?
    var originalAmountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    var requiredCurrencyCode: String = "EUR"
    var requiredCurrencyExponent: Int = 2
    var requiredRailTokens: [String] = []
    var commitmentStatusRaw: String = CommitmentStatus.committed.rawValue
    var statusRaw: String = Debt.Status.active.rawValue

    @Relationship(deleteRule: .cascade, inverse: \StoredScheduledPayment.debt)
    var paymentSchedule: [StoredScheduledPayment] = []

    init(_ debt: Debt, sequence: Int) throws {
        let encodedPaymentSchedule = try debt.paymentSchedule.enumerated().map {
            try StoredScheduledPayment($0.element, debtID: debt.id, sequence: $0.offset)
        }

        identifier = debt.id
        documentSequence = sequence
        name = debt.name
        note = debt.note
        originalAmountMinor = debt.originalAmount.minorUnits
        currencyCode = debt.originalAmount.currency.code
        currencyExponent = debt.originalAmount.currency.minorUnitDigits
        requiredCurrencyCode = debt.paymentRequirement.currency.code
        requiredCurrencyExponent = debt.paymentRequirement.currency.minorUnitDigits
        requiredRailTokens = debt.paymentRequirement.acceptableRails.map(\.id).sorted()
        commitmentStatusRaw = debt.commitmentStatus.rawValue
        statusRaw = debt.status.rawValue
        paymentSchedule = encodedPaymentSchedule
        paymentSchedule.forEach { $0.debt = self }
    }

    var asDomain: Debt {
        get throws {
            Debt(
                id: identifier,
                name: name,
                note: note,
                originalAmount: Money(
                    minorUnits: originalAmountMinor,
                    currency: try .persisted(code: currencyCode, exponent: currencyExponent)
                ),
                paymentSchedule: try paymentSchedule.sorted { $0.sequence < $1.sequence }.map { try $0.asDomain },
                paymentRequirement: PaymentRequirement(
                    currency: try .persisted(code: requiredCurrencyCode, exponent: requiredCurrencyExponent),
                    acceptableRails: Set(requiredRailTokens.map(PaymentRail.persisted))
                ),
                commitmentStatus: try PersistenceCoding.decodeEnum(CommitmentStatus.self, commitmentStatusRaw, field: "debt.commitmentStatus"),
                status: try PersistenceCoding.decodeEnum(Debt.Status.self, statusRaw, field: "debt.status")
            )
        }
    }
}

@Model
final class StoredScheduledPayment {
    #Unique<StoredScheduledPayment>([\.identifier])
    #Index<StoredScheduledPayment>([\.paymentDay])

    var identifier: String = ""
    var sequence: Int = 0
    var paymentDay: Int32 = 0
    var amountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    var statusRaw: String = PaymentStatus.scheduled.rawValue
    var paidOnDay: Int32?
    var debt: StoredDebt?

    init(_ payment: ScheduledPayment, debtID: String, sequence: Int) throws {
        let encodedPaymentDay = try PersistenceCoding.ordinal(payment.day)
        let encodedPaidOnDay = try PersistenceCoding.ordinal(payment.paidOn)

        identifier = "\(debtID)#payment-\(sequence)"
        self.sequence = sequence
        paymentDay = encodedPaymentDay
        amountMinor = payment.amount.minorUnits
        currencyCode = payment.amount.currency.code
        currencyExponent = payment.amount.currency.minorUnitDigits
        statusRaw = payment.status.rawValue
        paidOnDay = encodedPaidOnDay
    }

    var asDomain: ScheduledPayment {
        get throws {
            guard let day = Day(persistenceOrdinal: paymentDay) else {
                throw PersistenceMappingError.corruptDay(paymentDay)
            }
            let paidOn: Day?
            if let paidOnDay {
                guard let value = Day(persistenceOrdinal: paidOnDay) else {
                    throw PersistenceMappingError.corruptDay(paidOnDay)
                }
                paidOn = value
            } else {
                paidOn = nil
            }
            return ScheduledPayment(
                day: day,
                amount: Money(
                    minorUnits: amountMinor,
                    currency: try .persisted(code: currencyCode, exponent: currencyExponent)
                ),
                status: try PersistenceCoding.decodeEnum(PaymentStatus.self, statusRaw, field: "scheduledPayment.status"),
                paidOn: paidOn
            )
        }
    }
}

@Model
final class StoredCarriedValue {
    #Unique<StoredCarriedValue>([\.accountIdentifier])

    var accountIdentifier: String = ""
    var amountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2

    init(accountID: String, amount: Money) {
        accountIdentifier = accountID
        amountMinor = amount.minorUnits
        currencyCode = amount.currency.code
        currencyExponent = amount.currency.minorUnitDigits
    }

    var amount: Money {
        get throws {
            Money(
                minorUnits: amountMinor,
                currency: try .persisted(code: currencyCode, exponent: currencyExponent)
            )
        }
    }
}

/// One resolved expected occurrence.
///
/// Its own row rather than a field on the obligation: an occurrence is settled,
/// never a rule, so editing or ending a rule must leave these untouched. The
/// uniqueness constraints are the two reconciliation invariants made
/// structural — one settlement per occurrence, and one occurrence per actual.
@Model
final class StoredObligationSettlement {
    #Unique<StoredObligationSettlement>([\.identifier], [\.obligationIdentifier, \.expectedDay])
    #Index<StoredObligationSettlement>([\.actualTransactionIdentifier])

    var identifier: String = ""
    var documentSequence: Int = 0
    var obligationIdentifier: String = ""
    /// The occurrence's planned/inferred day — its identity, never the date
    /// the money actually moved.
    var expectedDay: Int32 = 0
    var resolutionRaw: String = OccurrenceResolution.paid.rawValue
    var actualTransactionIdentifier: String?
    var acceptedAmountDifference: Bool = false
    var note: String?
    var provenanceSource: String = ""
    var provenanceEvidenceGradeRaw: String = Provenance.EvidenceGrade.unresolved.rawValue
    var provenanceReference: String?

    init(_ settlement: ObligationSettlement, sequence: Int) throws {
        let encodedExpectedDay = try PersistenceCoding.ordinal(settlement.expectedDay)

        identifier = settlement.id
        documentSequence = sequence
        obligationIdentifier = settlement.obligationID
        expectedDay = encodedExpectedDay
        resolutionRaw = settlement.resolution.rawValue
        actualTransactionIdentifier = settlement.actualTransactionID
        acceptedAmountDifference = settlement.acceptedAmountDifference
        note = settlement.note
        provenanceSource = settlement.provenance.source
        provenanceEvidenceGradeRaw = settlement.provenance.evidenceGrade.rawValue
        provenanceReference = settlement.provenance.reference
    }

    var asDomain: ObligationSettlement {
        get throws {
            guard let day = Day(persistenceOrdinal: expectedDay) else {
                throw PersistenceMappingError.corruptDay(expectedDay)
            }
            return ObligationSettlement(
                id: identifier,
                obligationID: obligationIdentifier,
                expectedDay: day,
                resolution: try PersistenceCoding.decodeEnum(
                    OccurrenceResolution.self, resolutionRaw, field: "settlement.resolution"
                ),
                actualTransactionID: actualTransactionIdentifier,
                acceptedAmountDifference: acceptedAmountDifference,
                note: note,
                provenance: Provenance(
                    source: provenanceSource,
                    evidenceGrade: try PersistenceCoding.decodeEnum(
                        Provenance.EvidenceGrade.self,
                        provenanceEvidenceGradeRaw,
                        field: "settlement.provenance.evidenceGrade"
                    ),
                    reference: provenanceReference
                )
            )
        }
    }
}

// MARK: - External provider evidence (schema 1.3)

@Model
final class StoredExternalAccountBinding {
    #Unique<StoredExternalAccountBinding>([\.identifier], [\.providerRaw, \.remoteOpaqueAccountIdentifier])
    #Index<StoredExternalAccountBinding>([\.localAccountIdentifier])

    var identifier: String = ""
    var documentSequence: Int = 0
    var providerRaw: String = ""
    /// Backend-generated `acct_…` identity only. No IBAN, session uid or
    /// provider identification hash is accepted by this layer.
    var remoteOpaqueAccountIdentifier: String = ""
    var localAccountIdentifier: String = ""
    var syncStartDay: Int32 = 0
    var isActive: Bool = true
    var createdAt: Date = Date.distantPast

    init(_ binding: ExternalAccountBinding, sequence: Int) throws {
        let encodedSyncStartDay = try PersistenceCoding.ordinal(binding.syncStartBoundary)

        identifier = binding.id
        documentSequence = sequence
        providerRaw = binding.provider.rawValue
        remoteOpaqueAccountIdentifier = binding.remoteOpaqueAccountID
        localAccountIdentifier = binding.localAccountID
        syncStartDay = encodedSyncStartDay
        isActive = binding.isActive
        createdAt = binding.createdAt
    }

    var asDomain: ExternalAccountBinding {
        get throws {
            guard let boundary = Day(persistenceOrdinal: syncStartDay) else {
                throw PersistenceMappingError.corruptDay(syncStartDay)
            }
            return ExternalAccountBinding(
                id: identifier,
                provider: ExternalProvider(rawValue: providerRaw),
                remoteOpaqueAccountID: remoteOpaqueAccountIdentifier,
                localAccountID: localAccountIdentifier,
                syncStartBoundary: boundary,
                isActive: isActive,
                createdAt: createdAt
            )
        }
    }
}

@Model
final class StoredExternalObservation {
    #Unique<StoredExternalObservation>([\.identifier])
    #Index<StoredExternalObservation>([\.bindingIdentifier, \.bookingDay], [\.statusRaw])

    var identifier: String = ""
    var documentSequence: Int = 0
    var bindingIdentifier: String = ""
    var providerRaw: String = ""
    var identityRaw: String = ExternalObservationIdentity.durable.rawValue
    var statusRaw: String = ExternalObservationStatus.booked.token
    var creditDebitRaw: String = ExternalCreditDebitIndicator.debit.token
    var amountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    var bookingDay: Int32?
    var transactionDay: Int32?
    var valueDay: Int32?
    var derivedTransactionDay: Int32?
    var derivedDateProvenanceRaw: String?
    var rawMerchantText: String?
    var structuredMerchantName: String?
    var merchantEmail: String?
    var remittance: String?
    var bankTransactionCode: String?
    var bankTransactionSubCode: String?
    var providerEligibleForEconomicActual: Bool = false
    var observedAt: Date = Date.distantPast

    init(_ observation: ExternalObservation, sequence: Int) throws {
        let encodedBookingDay = try PersistenceCoding.ordinal(observation.bookingDate)
        let encodedTransactionDay = try PersistenceCoding.ordinal(observation.transactionDate)
        let encodedValueDay = try PersistenceCoding.ordinal(observation.valueDate)
        let encodedDerivedTransactionDay = try PersistenceCoding.ordinal(observation.derivedTransactionDate)

        identifier = observation.id
        documentSequence = sequence
        bindingIdentifier = observation.bindingID
        providerRaw = observation.provider.rawValue
        identityRaw = observation.identity.rawValue
        statusRaw = observation.status.token
        creditDebitRaw = observation.creditDebitIndicator.token
        amountMinor = observation.amount.minorUnits
        currencyCode = observation.amount.currency.code
        currencyExponent = observation.amount.currency.minorUnitDigits
        bookingDay = encodedBookingDay
        transactionDay = encodedTransactionDay
        valueDay = encodedValueDay
        derivedTransactionDay = encodedDerivedTransactionDay
        derivedDateProvenanceRaw = observation.derivedDateProvenance?.token
        rawMerchantText = observation.rawMerchantText
        structuredMerchantName = observation.structuredMerchantName
        merchantEmail = observation.merchantEmail
        remittance = observation.remittance
        bankTransactionCode = observation.bankTransactionCode
        bankTransactionSubCode = observation.bankTransactionSubCode
        providerEligibleForEconomicActual = observation.providerEligibleForEconomicActual
        observedAt = observation.observedAt
    }

    var asDomain: ExternalObservation {
        get throws {
            func day(_ value: Int32?) throws -> Day? {
                guard let value else { return nil }
                guard let day = Day(persistenceOrdinal: value) else {
                    throw PersistenceMappingError.corruptDay(value)
                }
                return day
            }
            return ExternalObservation(
                id: identifier,
                bindingID: bindingIdentifier,
                provider: ExternalProvider(rawValue: providerRaw),
                identity: try PersistenceCoding.decodeEnum(
                    ExternalObservationIdentity.self, identityRaw, field: "externalObservation.identity"
                ),
                status: ExternalObservationStatus(providerToken: statusRaw),
                creditDebitIndicator: ExternalCreditDebitIndicator(providerToken: creditDebitRaw),
                amount: Money(
                    minorUnits: amountMinor,
                    currency: try .persisted(code: currencyCode, exponent: currencyExponent)
                ),
                bookingDate: try day(bookingDay),
                transactionDate: try day(transactionDay),
                valueDate: try day(valueDay),
                derivedTransactionDate: try day(derivedTransactionDay),
                derivedDateProvenance: derivedDateProvenanceRaw.map(DerivedExternalDateProvenance.init),
                rawMerchantText: rawMerchantText,
                structuredMerchantName: structuredMerchantName,
                merchantEmail: merchantEmail,
                remittance: remittance,
                bankTransactionCode: bankTransactionCode,
                bankTransactionSubCode: bankTransactionSubCode,
                eligibleForEconomicActual: providerEligibleForEconomicActual,
                observedAt: observedAt
            )
        }
    }
}

@Model
final class StoredProviderBalanceSnapshot {
    #Unique<StoredProviderBalanceSnapshot>([\.identifier])
    #Index<StoredProviderBalanceSnapshot>([\.bindingIdentifier, \.balanceType])

    var identifier: String = ""
    var documentSequence: Int = 0
    var bindingIdentifier: String = ""
    var providerRaw: String = ""
    var balanceType: String = ""
    var name: String?
    var amountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    var referenceDay: Int32?
    var observedAt: Date = Date.distantPast

    init(_ snapshot: ProviderBalanceSnapshot, sequence: Int) throws {
        let encodedReferenceDay = try PersistenceCoding.ordinal(snapshot.referenceDate)

        identifier = snapshot.id
        documentSequence = sequence
        bindingIdentifier = snapshot.bindingID
        providerRaw = snapshot.provider.rawValue
        balanceType = snapshot.balanceType
        name = snapshot.name
        amountMinor = snapshot.amount.minorUnits
        currencyCode = snapshot.amount.currency.code
        currencyExponent = snapshot.amount.currency.minorUnitDigits
        referenceDay = encodedReferenceDay
        observedAt = snapshot.observedAt
    }

    var asDomain: ProviderBalanceSnapshot {
        get throws {
            let reference: Day?
            if let referenceDay {
                guard let day = Day(persistenceOrdinal: referenceDay) else {
                    throw PersistenceMappingError.corruptDay(referenceDay)
                }
                reference = day
            } else {
                reference = nil
            }
            return ProviderBalanceSnapshot(
                id: identifier,
                bindingID: bindingIdentifier,
                provider: ExternalProvider(rawValue: providerRaw),
                balanceType: balanceType,
                name: name,
                amount: Money(
                    minorUnits: amountMinor,
                    currency: try .persisted(code: currencyCode, exponent: currencyExponent)
                ),
                referenceDate: reference,
                observedAt: observedAt
            )
        }
    }
}

@Model
final class StoredExternalEvidenceLink {
    #Unique<StoredExternalEvidenceLink>([\.identifier], [\.observationIdentifier, \.roleRaw])
    #Index<StoredExternalEvidenceLink>([\.transactionIdentifier])

    var identifier: String = ""
    var documentSequence: Int = 0
    var observationIdentifier: String = ""
    var transactionIdentifier: String = ""
    var roleRaw: String = ExternalEvidenceRole.supportingEvidence.rawValue

    init(_ link: ExternalEvidenceLink, sequence: Int) {
        identifier = link.id
        documentSequence = sequence
        observationIdentifier = link.observationID
        transactionIdentifier = link.transactionID
        roleRaw = link.role.rawValue
    }

    var asDomain: ExternalEvidenceLink {
        get throws {
            ExternalEvidenceLink(
                id: identifier,
                observationID: observationIdentifier,
                transactionID: transactionIdentifier,
                role: try PersistenceCoding.decodeEnum(
                    ExternalEvidenceRole.self, roleRaw, field: "externalEvidenceLink.role"
                )
            )
        }
    }
}

@Model
final class StoredObservationResolution {
    #Unique<StoredObservationResolution>([\.observationIdentifier])

    var observationIdentifier: String = ""
    var documentSequence: Int = 0
    var stateRaw: String = ObservationResolutionState.unreviewed.rawValue
    var resolvedAt: Date?

    init(_ resolution: ExternalObservationResolution, sequence: Int) {
        observationIdentifier = resolution.observationID
        documentSequence = sequence
        stateRaw = resolution.state.rawValue
        resolvedAt = resolution.resolvedAt
    }

    var asDomain: ExternalObservationResolution {
        get throws {
            ExternalObservationResolution(
                observationID: observationIdentifier,
                state: try PersistenceCoding.decodeEnum(
                    ObservationResolutionState.self, stateRaw, field: "observationResolution.state"
                ),
                resolvedAt: resolvedAt
            )
        }
    }
}

@Model
final class StoredCrossProviderCandidate {
    #Unique<StoredCrossProviderCandidate>([\.identifier])
    #Index<StoredCrossProviderCandidate>([\.bankObservationIdentifier])

    var identifier: String = ""
    var documentSequence: Int = 0
    var bankObservationIdentifier: String = ""
    var walletObservationIdentifier: String?
    var stateRaw: String = CrossProviderCandidateState.unresolved.token
    var candidateCount: Int = 0
    var amountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    var dayOffset: Int?
    var rule: String = ""
    var computedAt: Date = Date.distantPast

    init(_ candidate: CrossProviderCandidate, sequence: Int) {
        identifier = candidate.id
        documentSequence = sequence
        bankObservationIdentifier = candidate.bankObservationID
        walletObservationIdentifier = candidate.walletObservationID
        stateRaw = candidate.state.token
        candidateCount = candidate.candidateCount
        amountMinor = candidate.amount.minorUnits
        currencyCode = candidate.amount.currency.code
        currencyExponent = candidate.amount.currency.minorUnitDigits
        dayOffset = candidate.dayOffset
        rule = candidate.rule
        computedAt = candidate.computedAt
    }

    var asDomain: CrossProviderCandidate {
        get throws {
            CrossProviderCandidate(
                id: identifier,
                bankObservationID: bankObservationIdentifier,
                walletObservationID: walletObservationIdentifier,
                state: CrossProviderCandidateState(providerToken: stateRaw),
                candidateCount: candidateCount,
                amount: Money(
                    minorUnits: amountMinor,
                    currency: try .persisted(code: currencyCode, exponent: currencyExponent)
                ),
                dayOffset: dayOffset,
                rule: rule,
                computedAt: computedAt
            )
        }
    }
}

@Model
final class StoredTrustedRule {
    #Unique<StoredTrustedRule>([\.identifier])
    #Index<StoredTrustedRule>([\.lifecycleRaw], [\.trustLevelRaw], [\.bindingIdentifier])

    var identifier: String = ""
    var documentSequence: Int = 0
    var title: String = ""
    var providerRaw: String = ""
    var bindingIdentifier: String = ""
    var merchantFieldRaw: String = TrustedMerchantEvidenceField.structuredMerchantName.rawValue
    var merchantValue: String = ""
    var directionRaw: String = TrustedRuleDirection.debit.rawValue
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    var exactMinorUnits: Int64?
    var bankTransactionCode: String?
    var transactionKindRaw: String = TransactionKind.expense.rawValue
    var categoryKey: String?
    var userLabel: String?
    var recurringObligationIdentifier: String?
    var incomeSourceIdentifier: String?
    var trustLevelRaw: String = TrustedRuleTrustLevel.suggestionOnly.rawValue
    var lifecycleRaw: String = TrustedRuleLifecycle.draft.rawValue
    var createdAt: Date = Date.distantPast
    var approvedAt: Date?
    var disabledAt: Date?
    var supportingConfirmationsData: Data = Data()

    init(_ rule: TrustedRule, sequence: Int) throws {
        let encodedSupportingConfirmationsData = try PersistenceCoding.encode(rule.supportingConfirmations)

        identifier = rule.id
        documentSequence = sequence
        title = rule.title
        providerRaw = rule.predicate.provider.rawValue
        bindingIdentifier = rule.predicate.bindingID
        merchantFieldRaw = rule.predicate.merchantField.rawValue
        merchantValue = rule.predicate.merchantValue
        directionRaw = rule.predicate.direction.rawValue
        currencyCode = rule.predicate.currencyCode
        currencyExponent = rule.predicate.currencyExponent
        exactMinorUnits = rule.predicate.exactMinorUnits
        bankTransactionCode = rule.predicate.bankTransactionCode
        transactionKindRaw = rule.interpretation.transactionKind.rawValue
        categoryKey = rule.interpretation.categoryKey
        userLabel = rule.interpretation.userLabel
        recurringObligationIdentifier = rule.interpretation.recurringObligationID
        incomeSourceIdentifier = rule.interpretation.incomeSourceID
        trustLevelRaw = rule.trustLevel.rawValue
        lifecycleRaw = rule.lifecycle.rawValue
        createdAt = rule.createdAt
        approvedAt = rule.approvedAt
        disabledAt = rule.disabledAt
        supportingConfirmationsData = encodedSupportingConfirmationsData
    }

    var asDomain: TrustedRule {
        get throws {
            TrustedRule(
                id: identifier,
                title: title,
                predicate: TrustedRulePredicate(
                    provider: ExternalProvider(rawValue: providerRaw),
                    bindingID: bindingIdentifier,
                    merchantField: try PersistenceCoding.decodeEnum(
                        TrustedMerchantEvidenceField.self,
                        merchantFieldRaw,
                        field: "trustedRule.merchantField"
                    ),
                    merchantValue: merchantValue,
                    direction: try PersistenceCoding.decodeEnum(
                        TrustedRuleDirection.self,
                        directionRaw,
                        field: "trustedRule.direction"
                    ),
                    currencyCode: currencyCode,
                    currencyExponent: currencyExponent,
                    exactMinorUnits: exactMinorUnits,
                    bankTransactionCode: bankTransactionCode
                ),
                interpretation: TrustedRuleInterpretation(
                    transactionKind: try PersistenceCoding.decodeEnum(
                        TransactionKind.self,
                        transactionKindRaw,
                        field: "trustedRule.transactionKind"
                    ),
                    categoryKey: categoryKey,
                    userLabel: userLabel,
                    recurringObligationID: recurringObligationIdentifier,
                    incomeSourceID: incomeSourceIdentifier
                ),
                supportingConfirmations: try PersistenceCoding.decode(
                    [TrustedRuleSupport].self,
                    from: supportingConfirmationsData,
                    field: "trustedRule.supportingConfirmations"
                ),
                createdAt: createdAt,
                trustLevel: try PersistenceCoding.decodeEnum(
                    TrustedRuleTrustLevel.self,
                    trustLevelRaw,
                    field: "trustedRule.trustLevel"
                ),
                lifecycle: try PersistenceCoding.decodeEnum(
                    TrustedRuleLifecycle.self,
                    lifecycleRaw,
                    field: "trustedRule.lifecycle"
                ),
                approvedAt: approvedAt,
                disabledAt: disabledAt
            )
        }
    }
}

@Model
final class StoredTrustedRuleAuditEvent {
    #Unique<StoredTrustedRuleAuditEvent>([\.identifier])
    #Index<StoredTrustedRuleAuditEvent>([\.ruleIdentifier, \.occurredAt], [\.observationIdentifier])

    var identifier: String = ""
    var documentSequence: Int = 0
    var ruleIdentifier: String = ""
    var ruleSemanticFingerprint: String = ""
    var kindRaw: String = TrustedRuleAuditKind.created.rawValue
    var occurredAt: Date = Date.distantPast
    var observationIdentifier: String?
    var transactionIdentifier: String?
    var sourceAuditEventIdentifier: String?
    var explanation: String = ""

    init(_ event: TrustedRuleAuditEvent, sequence: Int) {
        identifier = event.id
        documentSequence = sequence
        ruleIdentifier = event.ruleID
        ruleSemanticFingerprint = event.ruleSemanticFingerprint
        kindRaw = event.kind.rawValue
        occurredAt = event.occurredAt
        observationIdentifier = event.observationID
        transactionIdentifier = event.transactionID
        sourceAuditEventIdentifier = event.sourceAuditEventID
        explanation = event.explanation
    }

    var asDomain: TrustedRuleAuditEvent {
        get throws {
            TrustedRuleAuditEvent(
                id: identifier,
                ruleID: ruleIdentifier,
                ruleSemanticFingerprint: ruleSemanticFingerprint,
                kind: try PersistenceCoding.decodeEnum(
                    TrustedRuleAuditKind.self,
                    kindRaw,
                    field: "trustedRuleAudit.kind"
                ),
                occurredAt: occurredAt,
                observationID: observationIdentifier,
                transactionID: transactionIdentifier,
                sourceAuditEventID: sourceAuditEventIdentifier,
                explanation: explanation
            )
        }
    }
}

@Model
final class StoredTrustedRuleObservationSuppression {
    #Unique<StoredTrustedRuleObservationSuppression>([\.identifier])
    #Index<StoredTrustedRuleObservationSuppression>(
        [\.ruleIdentifier, \.observationIdentifier],
        [\.createdAt]
    )

    var identifier: String = ""
    var documentSequence: Int = 0
    var ruleIdentifier: String = ""
    var observationIdentifier: String = ""
    var applicationAuditEventIdentifier: String = ""
    var reversalAuditEventIdentifier: String = ""
    var createdAt: Date = Date.distantPast
    var clearedAt: Date?
    var clearAuditEventIdentifier: String?

    init(_ suppression: TrustedRuleObservationSuppression, sequence: Int) {
        identifier = suppression.id
        documentSequence = sequence
        ruleIdentifier = suppression.ruleID
        observationIdentifier = suppression.observationID
        applicationAuditEventIdentifier = suppression.applicationAuditEventID
        reversalAuditEventIdentifier = suppression.reversalAuditEventID
        createdAt = suppression.createdAt
        clearedAt = suppression.clearedAt
        clearAuditEventIdentifier = suppression.clearAuditEventID
    }

    var asDomain: TrustedRuleObservationSuppression {
        TrustedRuleObservationSuppression(
            id: identifier,
            ruleID: ruleIdentifier,
            observationID: observationIdentifier,
            applicationAuditEventID: applicationAuditEventIdentifier,
            reversalAuditEventID: reversalAuditEventIdentifier,
            createdAt: createdAt,
            clearedAt: clearedAt,
            clearAuditEventID: clearAuditEventIdentifier
        )
    }
}

/// Whole-document persistence orchestration. Nested financial data remains
/// normalized and queryable; this type only coordinates the rows.
enum StoredDocumentGraph {
    static func loadAppMetadata(from context: ModelContext) throws -> AppPersistenceMetadata {
        let sourceRows = try context.fetch(FetchDescriptor<StoredIncomeSource>())
        let preferences = try context.fetch(FetchDescriptor<StoredEntryPreferences>()).first
        let pendingRows = try context.fetch(FetchDescriptor<StoredAuthoritativePendingSnapshot>())
        let coverageRows = try context.fetch(FetchDescriptor<StoredAuthoritativeLiveCoverage>())
        return AppPersistenceMetadata(
            incomeSourceActive: Dictionary(
                uniqueKeysWithValues: sourceRows.map { ($0.identifier, $0.appIsActive) }
            ),
            lastExpenseAccountID: preferences?.lastExpenseAccountIdentifier,
            lastIncomeAccountID: preferences?.lastIncomeAccountIdentifier,
            trustedAutomationEnabled: preferences?.trustedAutomationEnabled ?? false,
            trustedAutomationRetryObservationIDs: Set(
                preferences?.trustedAutomationRetryObservationIdentifiers ?? []
            ),
            authoritativePendingSnapshots: Dictionary(
                uniqueKeysWithValues: pendingRows.map { ($0.provider, $0.snapshot) }
            ),
            authoritativeLiveCoverage: Dictionary(
                coverageRows.compactMap(\.asDomain).map { ($0.remoteOpaqueAccountID, $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            currentHoldingsModelVersion: preferences?.currentHoldingsModelVersion ?? 0,
            bankEvidenceCursor: preferences?.bankEvidenceCursor,
            bankEvidenceCursorBindingIDs: preferences?.bankEvidenceCursorBindingIDs ?? [],
            bankEvidenceCursorDeviceID: preferences?.bankEvidenceCursorDeviceID
        )
    }

    static func load(from context: ModelContext) throws -> FinanceDocument? {
        guard let meta = try context.fetch(FetchDescriptor<StoredDocumentMeta>()).first else {
            return nil
        }

        try PersistedSchema.validate(meta.schemaVersion)

        let accounts = try context.fetch(FetchDescriptor<StoredAccount>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        let balances = try context.fetch(FetchDescriptor<StoredAccountBalance>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        // Partitioned on the decoded value, not on a raw-string comparison: an
        // unrecognised token would match neither list and disappear from the
        // document, which is the same silent loss by another route.
        let storedTransactions = try context.fetch(FetchDescriptor<StoredTransaction>())
            .sorted { $0.documentSequence < $1.documentSequence }
        var observed: [Transaction] = []
        var expected: [Transaction] = []
        for stored in storedTransactions {
            switch try stored.factivity {
            case .observed: observed.append(try stored.asDomain)
            case .expected: expected.append(try stored.asDomain)
            }
        }
        let income = try context.fetch(FetchDescriptor<StoredIncomeSource>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        let installments = try context.fetch(FetchDescriptor<StoredInstallmentPlan>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        let debts = try context.fetch(FetchDescriptor<StoredDebt>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        let budgets = try context.fetch(FetchDescriptor<StoredBudgetAllocation>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        let obligations = try context.fetch(FetchDescriptor<StoredRecurringObligation>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        let carried = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<StoredCarriedValue>())
                .map { ($0.accountIdentifier, try $0.amount) }
        )
        let settlements = try context.fetch(FetchDescriptor<StoredObligationSettlement>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        let plannedPurchases = try context.fetch(FetchDescriptor<StoredPlannedPurchase>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        let sinkingFunds = try context.fetch(FetchDescriptor<StoredSinkingFund>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        let externalBindings = try context.fetch(FetchDescriptor<StoredExternalAccountBinding>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        let externalObservations = try context.fetch(FetchDescriptor<StoredExternalObservation>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        let providerBalances = try context.fetch(FetchDescriptor<StoredProviderBalanceSnapshot>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        let evidenceLinks = try context.fetch(FetchDescriptor<StoredExternalEvidenceLink>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        let observationResolutions = try context.fetch(FetchDescriptor<StoredObservationResolution>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        let crossProviderCandidates = try context.fetch(FetchDescriptor<StoredCrossProviderCandidate>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        let trustedRules = try context.fetch(FetchDescriptor<StoredTrustedRule>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        let trustedRuleAuditEvents = try context.fetch(FetchDescriptor<StoredTrustedRuleAuditEvent>())
            .sorted { $0.documentSequence < $1.documentSequence }
            .map { try $0.asDomain }
        let trustedRuleObservationSuppressions = try context.fetch(
            FetchDescriptor<StoredTrustedRuleObservationSuppression>()
        )
        .sorted { $0.documentSequence < $1.documentSequence }
        .map(\.asDomain)

        let loaded = FinanceDocument(
            schemaVersion: meta.schemaVersion,
            documentKind: meta.documentKind,
            note: meta.note,
            accounts: accounts,
            balances: balances,
            transactions: observed,
            expectedTransactions: expected,
            incomeSources: income,
            installments: installments,
            debts: debts,
            planning: FinanceDocument.Planning(
                defaultScenario: try meta.defaultScenario,
                safetyFloor: try meta.safetyFloor,
                monthlyEconomicCeiling: try meta.monthlyEconomicCeiling,
                budgets: budgets,
                recurringObligations: obligations,
                carriedEURValues: carried,
                settlements: settlements,
                plannedPurchases: plannedPurchases,
                sinkingFunds: sinkingFunds
            ),
            externalAccountBindings: externalBindings,
            externalObservations: externalObservations,
            providerBalanceSnapshots: providerBalances,
            externalEvidenceLinks: evidenceLinks,
            observationResolutions: observationResolutions,
            crossProviderCandidates: crossProviderCandidates,
            trustedRules: trustedRules,
            trustedRuleAuditEvents: trustedRuleAuditEvents,
            trustedRuleObservationSuppressions: trustedRuleObservationSuppressions
        )
        guard !containsUnrepresentableOperationalMoney(loaded) else {
            throw PersistenceMappingError.unrepresentableOperationalMoney
        }
        try validate(loaded)
        return loaded
    }

    /// Full interchange export restores cold provisional evidence without
    /// loading it into the operational document on every app launch.
    static func loadForExport(from context: ModelContext) throws -> FinanceDocument? {
        guard var loaded = try load(from: context) else { return nil }
        let batches = try context.fetch(FetchDescriptor<StoredPendingEvidenceArchive>())
            .sorted { ($0.archivedAt, $0.identifier) < ($1.archivedAt, $1.identifier) }
        var known = Set(loaded.externalObservations.map(\.id))
        for batch in batches {
            let retired = try batch.decoded()
            guard retired.observations.allSatisfy({ known.insert($0.id).inserted }) else {
                throw PendingEvidenceArchive.ArchiveError.corrupt
            }
            loaded.externalObservations.append(contentsOf: retired.observations)
            loaded.observationResolutions.append(contentsOf: retired.resolutions)
        }
        try validate(loaded)
        return loaded
    }

    /// Adds one user-entered transaction without rebuilding unrelated rows.
    /// The full document is still validated first; one context save commits
    /// the row, its legs, preferences, and document revision together.
    static func appendUserTransaction(
        _ transaction: Transaction,
        in document: FinanceDocument,
        context: ModelContext,
        writtenOn: Day,
        presentation: DomainMapper.TransactionPresentation,
        appMetadata: AppPersistenceMetadata
    ) throws {
        try validate(document)
        guard document.transactions.last?.id == transaction.id else {
            throw PersistenceMappingError.duplicateTransactionIdentifier(id: transaction.id)
        }
        let id = transaction.id
        var existing = FetchDescriptor<StoredTransaction>(
            predicate: #Predicate { $0.identifier == id }
        )
        existing.fetchLimit = 1
        guard try context.fetch(existing).isEmpty else {
            throw PersistenceMappingError.duplicateTransactionIdentifier(id: id)
        }
        let stored = try StoredTransaction(
            transaction, sequence: document.transactions.count - 1,
            categoryKey: presentation.categoryKey, merchant: presentation.merchant
        )
        let encodedDay = try PersistenceCoding.ordinal(writtenOn)
        guard let meta = try context.fetch(FetchDescriptor<StoredDocumentMeta>()).first else {
            throw PersistenceMappingError.missingDocumentRoot
        }
        let storedPreferences = try context.fetch(FetchDescriptor<StoredEntryPreferences>()).first
        let preferences = storedPreferences ?? StoredEntryPreferences(
            lastExpenseAccountIdentifier: nil, lastIncomeAccountIdentifier: nil
        )

        do {
            context.insert(stored)
            if storedPreferences == nil { context.insert(preferences) }
            meta.documentRevision = UUID().uuidString
            meta.writtenOnDay = encodedDay
            meta.schemaVersion = document.schemaVersion
            preferences.lastExpenseAccountIdentifier = appMetadata.lastExpenseAccountID
            preferences.lastIncomeAccountIdentifier = appMetadata.lastIncomeAccountID
            preferences.currentHoldingsModelVersion = appMetadata.currentHoldingsModelVersion
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Commits only operational bank metadata when the financial document and
    /// provider evidence rows are unchanged. The document revision and every
    /// ledger row keep their identity.
    static func updateBankMetadata(
        _ appMetadata: AppPersistenceMetadata,
        in context: ModelContext
    ) throws {
        guard try context.fetch(FetchDescriptor<StoredDocumentMeta>()).first != nil else {
            throw PersistenceMappingError.missingDocumentRoot
        }
        // Encode before touching the context so an invalid day cannot leave
        // part of the old coverage staged for deletion.
        let coverageRows = try appMetadata.authoritativeLiveCoverage.mapValues {
            try StoredAuthoritativeLiveCoverage($0)
        }
        let storedPending = try context.fetch(FetchDescriptor<StoredAuthoritativePendingSnapshot>())
        let storedCoverage = try context.fetch(FetchDescriptor<StoredAuthoritativeLiveCoverage>())
        let storedPreferences = try context.fetch(FetchDescriptor<StoredEntryPreferences>()).first
        let preferences = storedPreferences ?? StoredEntryPreferences(
            lastExpenseAccountIdentifier: appMetadata.lastExpenseAccountID,
            lastIncomeAccountIdentifier: appMetadata.lastIncomeAccountID,
            trustedAutomationEnabled: appMetadata.trustedAutomationEnabled,
            trustedAutomationRetryObservationIdentifiers:
                appMetadata.trustedAutomationRetryObservationIDs.sorted(),
            currentHoldingsModelVersion: appMetadata.currentHoldingsModelVersion
        )

        do {
            if storedPreferences == nil { context.insert(preferences) }
            preferences.bankEvidenceCursor = appMetadata.bankEvidenceCursor
            preferences.bankEvidenceCursorBindingIDs = appMetadata.bankEvidenceCursorBindingIDs
            preferences.bankEvidenceCursorDeviceID = appMetadata.bankEvidenceCursorDeviceID

            let existingPendingProviders = Set(storedPending.map(\.providerRaw))
            for row in storedPending {
                if let snapshot = appMetadata.authoritativePendingSnapshots[row.provider] {
                    row.authoritativeAt = snapshot.authoritativeAt
                    row.observationIdentifiers = snapshot.observationIDs.sorted()
                } else {
                    context.delete(row)
                }
            }
            for (provider, snapshot) in appMetadata.authoritativePendingSnapshots
                where !existingPendingProviders.contains(provider.rawValue) {
                context.insert(StoredAuthoritativePendingSnapshot(provider: provider, snapshot: snapshot))
            }

            let existingCoverageIDs = Set(storedCoverage.map(\.remoteOpaqueAccountIdentifier))
            for row in storedCoverage {
                if let incoming = coverageRows[row.remoteOpaqueAccountIdentifier] {
                    row.providerRaw = incoming.providerRaw
                    row.localAccountIdentifier = incoming.localAccountIdentifier
                    row.syncedFromDay = incoming.syncedFromDay
                    row.syncedThroughDay = incoming.syncedThroughDay
                    row.authoritativeAt = incoming.authoritativeAt
                } else {
                    context.delete(row)
                }
            }
            for (id, incoming) in coverageRows where !existingCoverageIDs.contains(id) {
                context.insert(incoming)
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    static func replace(
        with source: FinanceDocument,
        in context: ModelContext,
        writtenOn: Day,
        presentation: [String: DomainMapper.TransactionPresentation] = [:],
        appMetadata: AppPersistenceMetadata = .empty,
        replaceArchivedHistory: Bool = false,
        beforeSave: (ModelContext) throws -> Void = { _ in }
    ) throws {
        try validate(source)
        try StoredTransactionCorrection.validate(StoredTransactionCorrection.load(from: context),
            document: source, presentation: presentation)
        let partition = PendingEvidenceArchive.partition(
            source,
            authority: appMetadata.authoritativePendingSnapshots,
            retryObservationIDs: appMetadata.trustedAutomationRetryObservationIDs
        )
        let document = partition.live
        try validate(document)
        let archive = partition.retired.observations.isEmpty
            ? nil : try StoredPendingEvidenceArchive(partition.retired)
        // Encode and construct the complete incoming graph before any
        // destructive purge. An unpersistable date must leave the stored
        // document unchanged; rollback still covers a later save failure.
        let meta = try StoredDocumentMeta(document: document, writtenOn: writtenOn)
        let accounts = document.accounts.enumerated().map { StoredAccount($0.element, sequence: $0.offset) }
        let balances = try document.balances.enumerated().map {
            try StoredAccountBalance($0.element, sequence: $0.offset)
        }
        let transactions = try document.transactions.enumerated().map {
            let metadata = presentation[$0.element.id]
            return try StoredTransaction(
                $0.element,
                sequence: $0.offset,
                categoryKey: metadata?.categoryKey,
                merchant: metadata?.merchant
            )
        }
        let expectedTransactions = try document.expectedTransactions.enumerated().map {
            let metadata = presentation[$0.element.id]
            return try StoredTransaction($0.element, sequence: $0.offset,
                categoryKey: metadata?.categoryKey, merchant: metadata?.merchant)
        }
        let incomeSources = try document.incomeSources.enumerated().map {
            try StoredIncomeSource(
                $0.element,
                sequence: $0.offset,
                appIsActive: appMetadata.incomeSourceActive[$0.element.id] ?? true
            )
        }
        let preferences = StoredEntryPreferences(
            lastExpenseAccountIdentifier: appMetadata.lastExpenseAccountID,
            lastIncomeAccountIdentifier: appMetadata.lastIncomeAccountID,
            trustedAutomationEnabled: appMetadata.trustedAutomationEnabled,
            trustedAutomationRetryObservationIdentifiers:
                appMetadata.trustedAutomationRetryObservationIDs.sorted(),
            currentHoldingsModelVersion: appMetadata.currentHoldingsModelVersion,
            bankEvidenceCursor: appMetadata.bankEvidenceCursor,
            bankEvidenceCursorBindingIDs: appMetadata.bankEvidenceCursorBindingIDs,
            bankEvidenceCursorDeviceID: appMetadata.bankEvidenceCursorDeviceID
        )
        let pendingSnapshots = appMetadata.authoritativePendingSnapshots
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { StoredAuthoritativePendingSnapshot(provider: $0.key, snapshot: $0.value) }
        let liveCoverage = try appMetadata.authoritativeLiveCoverage
            .sorted { $0.key < $1.key }
            .map { try StoredAuthoritativeLiveCoverage($0.value) }
        let installmentPlans = try document.installments.enumerated().map {
            try StoredInstallmentPlan($0.element, sequence: $0.offset)
        }
        let debts = try document.debts.enumerated().map {
            try StoredDebt($0.element, sequence: $0.offset)
        }
        let budgets = try document.planning.budgets.enumerated().map {
            try StoredBudgetAllocation($0.element, sequence: $0.offset)
        }
        let obligations = try document.planning.recurringObligations.enumerated().map {
            try StoredRecurringObligation($0.element, sequence: $0.offset)
        }
        let carried = document.planning.carriedEURValues.map {
            StoredCarriedValue(accountID: $0.key, amount: $0.value)
        }
        let settlements = try document.planning.settlements
            .sorted { $0.id < $1.id }
            .enumerated()
            .map { try StoredObligationSettlement($0.element, sequence: $0.offset) }
        let plannedPurchases = try document.planning.plannedPurchases.enumerated().map {
            try StoredPlannedPurchase($0.element, sequence: $0.offset)
        }
        let sinkingFunds = try document.planning.sinkingFunds.enumerated().map {
            try StoredSinkingFund($0.element, sequence: $0.offset)
        }
        let bindings = try document.externalAccountBindings.enumerated().map {
            try StoredExternalAccountBinding($0.element, sequence: $0.offset)
        }
        let observations = try document.externalObservations.enumerated().map {
            try StoredExternalObservation($0.element, sequence: $0.offset)
        }
        let providerBalances = try document.providerBalanceSnapshots.enumerated().map {
            try StoredProviderBalanceSnapshot($0.element, sequence: $0.offset)
        }
        let evidenceLinks = document.externalEvidenceLinks.enumerated().map {
            StoredExternalEvidenceLink($0.element, sequence: $0.offset)
        }
        let resolutions = document.observationResolutions.enumerated().map {
            StoredObservationResolution($0.element, sequence: $0.offset)
        }
        let candidates = document.crossProviderCandidates.enumerated().map {
            StoredCrossProviderCandidate($0.element, sequence: $0.offset)
        }
        let trustedRules = try document.trustedRules.enumerated().map {
            try StoredTrustedRule($0.element, sequence: $0.offset)
        }
        let trustedRuleEvents = document.trustedRuleAuditEvents.enumerated().map {
            StoredTrustedRuleAuditEvent($0.element, sequence: $0.offset)
        }
        let suppressions = document.trustedRuleObservationSuppressions.enumerated().map {
            StoredTrustedRuleObservationSuppression($0.element, sequence: $0.offset)
        }

        do {
            try purge(from: context)
            if replaceArchivedHistory {
                try context.fetch(FetchDescriptor<StoredPendingEvidenceArchive>())
                    .forEach(context.delete)
            }
            context.insert(meta)
            accounts.forEach(context.insert)
            balances.forEach(context.insert)
            transactions.forEach(context.insert)
            expectedTransactions.forEach(context.insert)
            incomeSources.forEach(context.insert)
            context.insert(preferences)
            pendingSnapshots.forEach(context.insert)
            liveCoverage.forEach(context.insert)
            installmentPlans.forEach(context.insert)
            debts.forEach(context.insert)
            budgets.forEach(context.insert)
            obligations.forEach(context.insert)
            carried.forEach(context.insert)
            settlements.forEach(context.insert)
            plannedPurchases.forEach(context.insert)
            sinkingFunds.forEach(context.insert)
            bindings.forEach(context.insert)
            observations.forEach(context.insert)
            providerBalances.forEach(context.insert)
            evidenceLinks.forEach(context.insert)
            resolutions.forEach(context.insert)
            candidates.forEach(context.insert)
            trustedRules.forEach(context.insert)
            trustedRuleEvents.forEach(context.insert)
            suppressions.forEach(context.insert)
            if let archive { context.insert(archive) }
            try beforeSave(context)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// What has to be true of a document before any of it is written.
    ///
    /// The store keeps one row per account and one balance row per account, so
    /// a document carrying two of either would lose one on the way in with
    /// nothing to show for it. Refusing the import says which record collided;
    /// "keep the later one" would quietly pick a balance nobody chose.
    static func validate(_ document: FinanceDocument) throws {
        try PersistedSchema.validate(document.schemaVersion)
        guard !containsUnrepresentableOperationalMoney(document) else {
            throw PersistenceMappingError.unrepresentableOperationalMoney
        }

        var seenAccounts: Set<String> = []
        for account in document.accounts {
            guard seenAccounts.insert(account.id).inserted else {
                throw PersistenceMappingError.duplicateAccountIdentifier(id: account.id)
            }
        }

        var seenBalances: Set<String> = []
        for balance in document.balances {
            guard seenBalances.insert(balance.accountID).inserted else {
                throw PersistenceMappingError.duplicateAccountBalance(accountID: balance.accountID)
            }
        }

        try OperationalDocumentValidation.validate(document)

        // Reconciliation invariants are checked here, on the way in, because
        // this is the boundary an untrusted document crosses.
        do {
            try ReconciliationLedger.validate(document.planning.settlements, against: document)
        } catch let problem as ReconciliationError {
            throw PersistenceMappingError.invalidReconciliation(problem.description)
        }
        do {
            try ExternalEvidenceReview.validate(document)
        } catch let problem as ExternalEvidenceError {
            throw PersistenceMappingError.invalidExternalEvidence(problem.description)
        }
        do {
            try PlanningValidation.validate(document)
        } catch let problem as PlanningValidationError {
            throw PersistenceMappingError.invalidPlanning(DomainMapper.planningValidationMessage(problem))
        }
    }

    /// The interchange format can round-trip Int64.min. Operational paths
    /// sometimes need its magnitude, which has no signed Int64 representation.
    /// Refuse it at the app boundary before a forecast or view can trap.
    static func containsUnrepresentableOperationalMoney(_ value: Any) -> Bool {
        if let money = value as? Money { return money.minorUnits == Int64.min }
        if let bag = value as? MoneyBag {
            return bag.currencies.contains { bag.amount(in: $0).minorUnits == Int64.min }
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .class { return false }
        return mirror.children.contains { containsUnrepresentableOperationalMoney($0.value) }
    }

    private static func purge(from context: ModelContext) throws {
        func remove<T: PersistentModel>(_ type: T.Type) throws {
            try context.fetch(FetchDescriptor<T>()).forEach(context.delete)
        }

        try remove(StoredAccountLeg.self)
        try remove(StoredOwnershipSplit.self)
        try remove(StoredBudgetOverride.self)
        try remove(StoredInstallment.self)
        try remove(StoredScheduledPayment.self)
        try remove(StoredTransaction.self)
        try remove(StoredBudgetAllocation.self)
        try remove(StoredInstallmentPlan.self)
        try remove(StoredDebt.self)
        try remove(StoredObligationSettlement.self)
        try remove(StoredPlannedPurchase.self)
        try remove(StoredSinkingFund.self)
        try remove(StoredExternalEvidenceLink.self)
        try remove(StoredObservationResolution.self)
        try remove(StoredCrossProviderCandidate.self)
        try remove(StoredTrustedRuleAuditEvent.self)
        try remove(StoredTrustedRuleObservationSuppression.self)
        try remove(StoredTrustedRule.self)
        try remove(StoredExternalObservation.self)
        try remove(StoredProviderBalanceSnapshot.self)
        try remove(StoredExternalAccountBinding.self)
        try remove(StoredRecurringObligation.self)
        try remove(StoredIncomeSource.self)
        try remove(StoredAuthoritativePendingSnapshot.self)
        try remove(StoredAuthoritativeLiveCoverage.self)
        try remove(StoredEntryPreferences.self)
        try remove(StoredCarriedValue.self)
        try remove(StoredAccountBalance.self)
        try remove(StoredAccount.self)
        try remove(StoredDocumentMeta.self)
    }
}

/// Independent audit rows survive ordinary document replacement. No cascade.
@Model
final class StoredTransactionCorrection {
    // Uniqueness uses serialized preflight plus chain validation. SwiftData
    // #Unique would upsert conflicting records and rewrite accepted history.
    #Index<StoredTransactionCorrection>([\.transactionIdentifier, \.revision])
    var identifier: String = ""
    var transactionIdentifier: String = ""
    var revision: Int = 0
    var recordedAt: Date = Date(timeIntervalSinceReferenceDate: 0)
    var beforeMerchant: String?
    var beforeCategoryKey: String?
    var afterMerchant: String?
    var afterCategoryKey: String?

    init(_ correction: TransactionMetadataCorrection) {
        identifier = correction.id
        transactionIdentifier = correction.transactionID
        revision = correction.revision
        recordedAt = correction.recordedAt
        beforeMerchant = correction.before.merchant
        beforeCategoryKey = correction.before.categoryKey
        afterMerchant = correction.after.merchant
        afterCategoryKey = correction.after.categoryKey
    }

    var asCorrection: TransactionMetadataCorrection {
        .init(id: identifier, transactionID: transactionIdentifier, revision: revision,
              recordedAt: recordedAt,
              before: .init(merchant: beforeMerchant, categoryKey: beforeCategoryKey),
              after: .init(merchant: afterMerchant, categoryKey: afterCategoryKey))
    }

    static func load(from context: ModelContext) throws -> [TransactionMetadataCorrection] {
        try context.fetch(FetchDescriptor<StoredTransactionCorrection>()).map(\.asCorrection)
            .sorted { ($0.transactionID, $0.revision) < ($1.transactionID, $1.revision) }
    }

    static func validate(_ corrections: [TransactionMetadataCorrection], document: FinanceDocument,
                         presentation: [String: DomainMapper.TransactionPresentation]? = nil) throws {
        guard Set(corrections.map(\.id)).count == corrections.count else { throw AppImportError.invalidBackupMetadata }
        for (id, chain) in Dictionary(grouping: corrections, by: \.transactionID) {
            guard let transaction = document.transactions.first(where: { $0.id == id }) else {
                throw AppImportError.invalidBackupMetadata
            }
            let ordered = chain.sorted { $0.revision < $1.revision }
            for (index, correction) in ordered.enumerated() {
                guard UUID(uuidString: correction.id) != nil, correction.revision == index + 1,
                      correction.recordedAt.timeIntervalSinceReferenceDate.isFinite,
                      correction.before != correction.after,
                      correction.after.merchant == TransactionMetadata.normalizedMerchant(correction.after.merchant),
                      (correction.after.merchant?.count ?? 0) <= 200,
                      index == 0 || correction.before == ordered[index - 1].after else {
                    throw AppImportError.invalidBackupMetadata
                }
                if correction.before.categoryKey != correction.after.categoryKey {
                    guard DomainMapper.supportsCategoryCorrection(transaction),
                          correction.after.categoryKey.map(DomainMapper.spendingCategoryKeys.contains) ?? true else {
                        throw AppImportError.invalidBackupMetadata
                    }
                }
            }
            if let presentation, let last = ordered.last {
                let current = presentation[id]
                guard last.after == TransactionMetadata(merchant: current?.merchant, categoryKey: current?.categoryKey) else {
                    throw AppImportError.invalidBackupMetadata
                }
            }
        }
    }

    /// One save changes metadata, revision and audit. The economic graph stays intact.
    static func append(_ correction: TransactionMetadataCorrection, in context: ModelContext,
                       writtenOn: Day) throws {
        guard !context.hasChanges else { throw AppCorrectionError.persistenceFailed }
        let id = correction.transactionID
        let stored = try context.fetch(FetchDescriptor<StoredTransaction>(predicate: #Predicate { $0.identifier == id }))
        let history = try load(from: context).filter { $0.transactionID == id }
        guard stored.count == 1, let transaction = stored.first,
              correction.revision == history.count + 1,
              correction.before == TransactionMetadata(merchant: transaction.appMerchant, categoryKey: transaction.appCategoryKey),
              history.last.map({ $0.after == correction.before }) ?? true else {
            throw AppCorrectionError.staleDraft
        }
        guard let meta = try context.fetch(FetchDescriptor<StoredDocumentMeta>()).first else {
            throw AppCorrectionError.storeUnreadable
        }
        let day = try PersistenceCoding.ordinal(writtenOn)
        do {
            transaction.appMerchant = correction.after.merchant
            transaction.appCategoryKey = correction.after.categoryKey
            context.insert(StoredTransactionCorrection(correction))
            meta.documentRevision = UUID().uuidString
            meta.writtenOnDay = day
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}

enum FinanceSchema {
    static let models: [any PersistentModel.Type] = [
        StoredDocumentMeta.self,
        StoredAccount.self,
        StoredAccountBalance.self,
        StoredTransaction.self,
        StoredTransactionCorrection.self,
        StoredAccountLeg.self,
        StoredOwnershipSplit.self,
        StoredIncomeSource.self,
        StoredAuthoritativePendingSnapshot.self,
        StoredPendingEvidenceArchive.self,
        StoredAuthoritativeLiveCoverage.self,
        StoredEntryPreferences.self,
        StoredRecurringObligation.self,
        StoredBudgetAllocation.self,
        StoredBudgetOverride.self,
        StoredInstallmentPlan.self,
        StoredInstallment.self,
        StoredDebt.self,
        StoredScheduledPayment.self,
        StoredCarriedValue.self,
        StoredObligationSettlement.self,
        StoredPlannedPurchase.self,
        StoredSinkingFund.self,
        StoredExternalAccountBinding.self,
        StoredExternalObservation.self,
        StoredProviderBalanceSnapshot.self,
        StoredExternalEvidenceLink.self,
        StoredObservationResolution.self,
        StoredCrossProviderCandidate.self,
        StoredTrustedRule.self,
        StoredTrustedRuleAuditEvent.self,
        StoredTrustedRuleObservationSuppression.self,
        StoredHistoryArchive.self,
        StoredHistoricalTransaction.self,
        StoredHistorySourceGap.self,
        // Checkpoint history shares the container and nothing else. It is
        // absent from `StoredDocumentGraph.purge` on purpose: an ordinary
        // document write must have no obligation to carry an accepted close
        // forward, because the first path that forgot would destroy it
        // silently. See `CheckpointPersistedModels.swift`.
        StoredPeriodCheckpointDataset.self,
        StoredPeriodCheckpointRevision.self,
        StoredPeriodCheckpointAcknowledgment.self
    ]
}
