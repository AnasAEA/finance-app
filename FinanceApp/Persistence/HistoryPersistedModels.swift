import Foundation
import SwiftData
import FinanceCore

/// Metadata for the one installed private archive. Import uses explicit
/// replace-by-archive semantics: a successful confirmation replaces this
/// graph as a unit, while a failure rolls the model context back.
@Model
final class StoredHistoryArchive {
    #Unique<StoredHistoryArchive>([\.identifier])
    #Index<StoredHistoryArchive>([\.cutoffDay])

    var identifier: String = ""
    var schemaVersion: String = ""
    var documentKind: String = ""
    var sourceRevision: String = ""
    var contentSHA256: String = ""
    var cutoffDay: Int32 = 0
    var firstDay: Int32 = 0
    var lastDay: Int32 = 0
    var recordCount: Int = 0
    var importedAt: Date = Date.distantPast
    var accountIdentifiers: [String] = []
    var accountNames: [String] = []
    var categoryIdentifiers: [String] = []
    var categoryNames: [String] = []
    var economicTypes: [String] = []
    var economicSources: [String] = []
    var currencies: [String] = []
    var sourceIdentifiers: [String] = []
    var sourceNames: [String] = []
    var statuses: [String] = []
    var provenanceValues: [String] = []

    init(
        identifier: String,
        schemaVersion: String,
        documentKind: String,
        sourceRevision: String,
        contentSHA256: String,
        cutoffDay: Int32,
        firstDay: Int32,
        lastDay: Int32,
        recordCount: Int,
        importedAt: Date,
        accountIdentifiers: [String],
        accountNames: [String],
        categoryIdentifiers: [String],
        categoryNames: [String],
        economicTypes: [String],
        economicSources: [String],
        currencies: [String],
        sourceIdentifiers: [String],
        sourceNames: [String],
        statuses: [String],
        provenanceValues: [String]
    ) {
        self.identifier = identifier
        self.schemaVersion = schemaVersion
        self.documentKind = documentKind
        self.sourceRevision = sourceRevision
        self.contentSHA256 = contentSHA256
        self.cutoffDay = cutoffDay
        self.firstDay = firstDay
        self.lastDay = lastDay
        self.recordCount = recordCount
        self.importedAt = importedAt
        self.accountIdentifiers = accountIdentifiers
        self.accountNames = accountNames
        self.categoryIdentifiers = categoryIdentifiers
        self.categoryNames = categoryNames
        self.economicTypes = economicTypes
        self.economicSources = economicSources
        self.currencies = currencies
        self.sourceIdentifiers = sourceIdentifiers
        self.sourceNames = sourceNames
        self.statuses = statuses
        self.provenanceValues = provenanceValues
    }
}

/// A query-oriented projection of one canonical historical record.
///
/// Archive data never has relationships to live balances, transactions or
/// planning rows. Keeping only archive identifiers as scalars makes the safety
/// boundary structural: no SwiftData traversal can make a history row part of
/// an operational calculation.
@Model
final class StoredHistoricalTransaction {
    #Unique<StoredHistoricalTransaction>([\.archiveIdentifier, \.identifier])
    #Index<StoredHistoricalTransaction>(
        [\.valueDay],
        [\.accountIdentifier, \.valueDay],
        [\.categoryIdentifier, \.valueDay],
        [\.economicTypeRaw, \.valueDay],
        [\.economicSourceRaw, \.valueDay],
        [\.currencyCode, \.valueDay],
        [\.sourceIdentifier, \.valueDay],
        [\.absoluteAmountMinor],
        [\.normalizedSearchText]
    )

    /// Stable historical id from the archive, preserved verbatim.
    var identifier: String = ""
    var archiveIdentifier: String = ""
    var valueDay: Int32 = 0
    var amountMinor: Int64 = 0
    var absoluteAmountMinor: Int64 = 0
    var currencyCode: String = "EUR"
    var currencyExponent: Int = 2
    var bookedAmountEURMinor: Int64?
    var economicAmountEURMinor: Int64?
    var personalAmountEURMinor: Int64?

    var accountIdentifier: String = ""
    var accountName: String = ""
    var railRaw: String = ""
    var merchant: String?
    var counterparty: String?
    var displayDescription: String = ""
    var originalDescription: String?

    var categoryIdentifier: String = "uncategorized"
    var categoryName: String = "Uncategorized"
    var categoryTop: String = "uncategorized"
    var categorySub: String?
    var economicTypeRaw: String = ""

    /// Canonical economic source. Optional with a `nil` default so an archive
    /// stored before this dimension existed migrates lightly, and so "no
    /// source" stays distinguishable from any real source token.
    var economicSourceRaw: String?
    var statusRaw: String = ""
    var sourceIdentifier: String = ""
    var sourceName: String = ""
    var provenanceRaw: String = ""
    var confidenceRaw: String = ""
    var economicViewRoleRaw: String = ""
    var isInternalTransfer: Bool = false
    var passThroughRaw: String = "none"
    var isFinancingLeg: Bool = false
    var crossInstitutionPairIdentifier: String?
    var refundIdentifier: String?
    var purchaseIdentifier: String?
    var financingIdentifier: String?
    var confirmationIdentifier: String?
    var linkedTransactionIdentifier: String?
    var groupIdentifier: String?
    var evidenceRuleIdentifier: String = ""
    var evidenceBasis: String = ""
    var evidenceUnresolvedReason: String?

    /// Pre-folded case/diacritic-insensitive text. The source strings remain
    /// available for display, but searches never normalize thousands of rows
    /// again on each keystroke.
    var normalizedSearchText: String = ""

    init(
        identifier: String,
        archiveIdentifier: String,
        valueDay: Int32,
        amountMinor: Int64,
        currencyCode: String,
        currencyExponent: Int,
        bookedAmountEURMinor: Int64?,
        economicAmountEURMinor: Int64?,
        personalAmountEURMinor: Int64?,
        accountIdentifier: String,
        accountName: String,
        railRaw: String,
        merchant: String?,
        counterparty: String?,
        displayDescription: String,
        originalDescription: String?,
        categoryIdentifier: String,
        categoryName: String,
        categoryTop: String,
        categorySub: String?,
        economicTypeRaw: String,
        economicSourceRaw: String?,
        statusRaw: String,
        sourceIdentifier: String,
        sourceName: String,
        provenanceRaw: String,
        confidenceRaw: String,
        economicViewRoleRaw: String,
        isInternalTransfer: Bool,
        passThroughRaw: String,
        isFinancingLeg: Bool,
        crossInstitutionPairIdentifier: String?,
        refundIdentifier: String?,
        purchaseIdentifier: String?,
        financingIdentifier: String?,
        confirmationIdentifier: String?,
        linkedTransactionIdentifier: String?,
        groupIdentifier: String?,
        evidenceRuleIdentifier: String,
        evidenceBasis: String,
        evidenceUnresolvedReason: String?
    ) {
        self.identifier = identifier
        self.archiveIdentifier = archiveIdentifier
        self.valueDay = valueDay
        self.amountMinor = amountMinor
        self.absoluteAmountMinor = amountMinor.magnitudeForHistory
        self.currencyCode = currencyCode
        self.currencyExponent = currencyExponent
        self.bookedAmountEURMinor = bookedAmountEURMinor
        self.economicAmountEURMinor = economicAmountEURMinor
        self.personalAmountEURMinor = personalAmountEURMinor
        self.accountIdentifier = accountIdentifier
        self.accountName = accountName
        self.railRaw = railRaw
        self.merchant = merchant
        self.counterparty = counterparty
        self.displayDescription = displayDescription
        self.originalDescription = originalDescription
        self.categoryIdentifier = categoryIdentifier
        self.categoryName = categoryName
        self.categoryTop = categoryTop
        self.categorySub = categorySub
        self.economicTypeRaw = economicTypeRaw
        self.economicSourceRaw = economicSourceRaw
        self.statusRaw = statusRaw
        self.sourceIdentifier = sourceIdentifier
        self.sourceName = sourceName
        self.provenanceRaw = provenanceRaw
        self.confidenceRaw = confidenceRaw
        self.economicViewRoleRaw = economicViewRoleRaw
        self.isInternalTransfer = isInternalTransfer
        self.passThroughRaw = passThroughRaw
        self.isFinancingLeg = isFinancingLeg
        self.crossInstitutionPairIdentifier = crossInstitutionPairIdentifier
        self.refundIdentifier = refundIdentifier
        self.purchaseIdentifier = purchaseIdentifier
        self.financingIdentifier = financingIdentifier
        self.confirmationIdentifier = confirmationIdentifier
        self.linkedTransactionIdentifier = linkedTransactionIdentifier
        self.groupIdentifier = groupIdentifier
        self.evidenceRuleIdentifier = evidenceRuleIdentifier
        self.evidenceBasis = evidenceBasis
        self.evidenceUnresolvedReason = evidenceUnresolvedReason
        normalizedSearchText = FinanceHistorySearchNormalization.joining([
            merchant, counterparty, displayDescription, originalDescription,
            categoryTop, categorySub, accountName, sourceName,
        ])
    }
}

@Model
final class StoredHistorySourceGap {
    #Unique<StoredHistorySourceGap>([\.archiveIdentifier, \.identifier])
    #Index<StoredHistorySourceGap>(
        [\.startDay, \.endDay],
        [\.accountIdentifier, \.startDay],
        [\.sourceIdentifier, \.startDay]
    )

    var identifier: String = ""
    var archiveIdentifier: String = ""
    var startDay: Int32 = 0
    var endDay: Int32 = 0
    var accountIdentifier: String?
    var sourceIdentifier: String?
    var affectedSourceIdentifiers: [String] = []
    var completenessRaw: String = ""
    var message: String = "Bank records for part of this period are incomplete."

    init(
        identifier: String,
        archiveIdentifier: String,
        startDay: Int32,
        endDay: Int32,
        accountIdentifier: String?,
        sourceIdentifier: String?,
        affectedSourceIdentifiers: [String],
        completenessRaw: String,
        message: String
    ) {
        self.identifier = identifier
        self.archiveIdentifier = archiveIdentifier
        self.startDay = startDay
        self.endDay = endDay
        self.accountIdentifier = accountIdentifier
        self.sourceIdentifier = sourceIdentifier
        self.affectedSourceIdentifiers = affectedSourceIdentifiers
        self.completenessRaw = completenessRaw
        self.message = message
    }
}

enum HistorySearchNormalizer {
    static func normalize(_ value: String) -> String {
        FinanceHistorySearchNormalization.normalize(value)
    }
}

private extension Int64 {
    /// `abs(.min)` traps. The history importer rejects that impossible money
    /// value semantically; this total implementation also keeps model init
    /// safe if a synthetic row is constructed directly by a test.
    var magnitudeForHistory: Int64 { self == .min ? .max : Swift.abs(self) }
}
