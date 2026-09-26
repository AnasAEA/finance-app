import Foundation
import SwiftData

// Versioned snapshots of persisted history. No SwiftData identity or device secret
// crosses this boundary. Fields stay explicit so a model change requires review.

struct HistoryArchiveRecovery: Codable, Hashable, Sendable {
    var identifier: String
    var schemaVersion: String
    var documentKind: String
    var sourceRevision: String
    var contentSHA256: String
    var cutoffDay: Int32
    var firstDay: Int32
    var lastDay: Int32
    var recordCount: Int
    var importedAt: Date
    var accountIdentifiers: [String]
    var accountNames: [String]
    var categoryIdentifiers: [String]
    var categoryNames: [String]
    var economicTypes: [String]
    var economicSources: [String]
    var currencies: [String]
    var sourceIdentifiers: [String]
    var sourceNames: [String]
    var statuses: [String]
    var provenanceValues: [String]

    @MainActor init(_ row: StoredHistoryArchive) {
        identifier = row.identifier
        schemaVersion = row.schemaVersion
        documentKind = row.documentKind
        sourceRevision = row.sourceRevision
        contentSHA256 = row.contentSHA256
        cutoffDay = row.cutoffDay
        firstDay = row.firstDay
        lastDay = row.lastDay
        recordCount = row.recordCount
        importedAt = row.importedAt
        accountIdentifiers = row.accountIdentifiers
        accountNames = row.accountNames
        categoryIdentifiers = row.categoryIdentifiers
        categoryNames = row.categoryNames
        economicTypes = row.economicTypes
        economicSources = row.economicSources
        currencies = row.currencies
        sourceIdentifiers = row.sourceIdentifiers
        sourceNames = row.sourceNames
        statuses = row.statuses
        provenanceValues = row.provenanceValues
    }

    @MainActor func model() -> StoredHistoryArchive {
        let row = StoredHistoryArchive(
            identifier: identifier,
            schemaVersion: schemaVersion,
            documentKind: documentKind,
            sourceRevision: sourceRevision,
            contentSHA256: contentSHA256,
            cutoffDay: cutoffDay,
            firstDay: firstDay,
            lastDay: lastDay,
            recordCount: recordCount,
            importedAt: importedAt,
            accountIdentifiers: accountIdentifiers,
            accountNames: accountNames,
            categoryIdentifiers: categoryIdentifiers,
            categoryNames: categoryNames,
            economicTypes: economicTypes,
            economicSources: economicSources,
            currencies: currencies,
            sourceIdentifiers: sourceIdentifiers,
            sourceNames: sourceNames,
            statuses: statuses,
            provenanceValues: provenanceValues
        )
        return row
    }
}

struct HistoricalTransactionRecovery: Codable, Hashable, Sendable {
    var identifier: String
    var archiveIdentifier: String
    var valueDay: Int32
    var amountMinor: Int64
    var absoluteAmountMinor: Int64
    var currencyCode: String
    var currencyExponent: Int
    var bookedAmountEURMinor: Int64?
    var economicAmountEURMinor: Int64?
    var personalAmountEURMinor: Int64?
    var accountIdentifier: String
    var accountName: String
    var railRaw: String
    var merchant: String?
    var counterparty: String?
    var displayDescription: String
    var originalDescription: String?
    var categoryIdentifier: String
    var categoryName: String
    var categoryTop: String
    var categorySub: String?
    var economicTypeRaw: String
    var economicSourceRaw: String?
    var statusRaw: String
    var sourceIdentifier: String
    var sourceName: String
    var provenanceRaw: String
    var confidenceRaw: String
    var economicViewRoleRaw: String
    var isInternalTransfer: Bool
    var passThroughRaw: String
    var isFinancingLeg: Bool
    var crossInstitutionPairIdentifier: String?
    var refundIdentifier: String?
    var purchaseIdentifier: String?
    var financingIdentifier: String?
    var confirmationIdentifier: String?
    var linkedTransactionIdentifier: String?
    var groupIdentifier: String?
    var evidenceRuleIdentifier: String
    var evidenceBasis: String
    var evidenceUnresolvedReason: String?
    var normalizedSearchText: String

    @MainActor init(_ row: StoredHistoricalTransaction) {
        identifier = row.identifier
        archiveIdentifier = row.archiveIdentifier
        valueDay = row.valueDay
        amountMinor = row.amountMinor
        absoluteAmountMinor = row.absoluteAmountMinor
        currencyCode = row.currencyCode
        currencyExponent = row.currencyExponent
        bookedAmountEURMinor = row.bookedAmountEURMinor
        economicAmountEURMinor = row.economicAmountEURMinor
        personalAmountEURMinor = row.personalAmountEURMinor
        accountIdentifier = row.accountIdentifier
        accountName = row.accountName
        railRaw = row.railRaw
        merchant = row.merchant
        counterparty = row.counterparty
        displayDescription = row.displayDescription
        originalDescription = row.originalDescription
        categoryIdentifier = row.categoryIdentifier
        categoryName = row.categoryName
        categoryTop = row.categoryTop
        categorySub = row.categorySub
        economicTypeRaw = row.economicTypeRaw
        economicSourceRaw = row.economicSourceRaw
        statusRaw = row.statusRaw
        sourceIdentifier = row.sourceIdentifier
        sourceName = row.sourceName
        provenanceRaw = row.provenanceRaw
        confidenceRaw = row.confidenceRaw
        economicViewRoleRaw = row.economicViewRoleRaw
        isInternalTransfer = row.isInternalTransfer
        passThroughRaw = row.passThroughRaw
        isFinancingLeg = row.isFinancingLeg
        crossInstitutionPairIdentifier = row.crossInstitutionPairIdentifier
        refundIdentifier = row.refundIdentifier
        purchaseIdentifier = row.purchaseIdentifier
        financingIdentifier = row.financingIdentifier
        confirmationIdentifier = row.confirmationIdentifier
        linkedTransactionIdentifier = row.linkedTransactionIdentifier
        groupIdentifier = row.groupIdentifier
        evidenceRuleIdentifier = row.evidenceRuleIdentifier
        evidenceBasis = row.evidenceBasis
        evidenceUnresolvedReason = row.evidenceUnresolvedReason
        normalizedSearchText = row.normalizedSearchText
    }

    @MainActor func model() -> StoredHistoricalTransaction {
        let row = StoredHistoricalTransaction(
            identifier: identifier,
            archiveIdentifier: archiveIdentifier,
            valueDay: valueDay,
            amountMinor: amountMinor,
            currencyCode: currencyCode,
            currencyExponent: currencyExponent,
            bookedAmountEURMinor: bookedAmountEURMinor,
            economicAmountEURMinor: economicAmountEURMinor,
            personalAmountEURMinor: personalAmountEURMinor,
            accountIdentifier: accountIdentifier,
            accountName: accountName,
            railRaw: railRaw,
            merchant: merchant,
            counterparty: counterparty,
            displayDescription: displayDescription,
            originalDescription: originalDescription,
            categoryIdentifier: categoryIdentifier,
            categoryName: categoryName,
            categoryTop: categoryTop,
            categorySub: categorySub,
            economicTypeRaw: economicTypeRaw,
            economicSourceRaw: economicSourceRaw,
            statusRaw: statusRaw,
            sourceIdentifier: sourceIdentifier,
            sourceName: sourceName,
            provenanceRaw: provenanceRaw,
            confidenceRaw: confidenceRaw,
            economicViewRoleRaw: economicViewRoleRaw,
            isInternalTransfer: isInternalTransfer,
            passThroughRaw: passThroughRaw,
            isFinancingLeg: isFinancingLeg,
            crossInstitutionPairIdentifier: crossInstitutionPairIdentifier,
            refundIdentifier: refundIdentifier,
            purchaseIdentifier: purchaseIdentifier,
            financingIdentifier: financingIdentifier,
            confirmationIdentifier: confirmationIdentifier,
            linkedTransactionIdentifier: linkedTransactionIdentifier,
            groupIdentifier: groupIdentifier,
            evidenceRuleIdentifier: evidenceRuleIdentifier,
            evidenceBasis: evidenceBasis,
            evidenceUnresolvedReason: evidenceUnresolvedReason
        )
        row.absoluteAmountMinor = absoluteAmountMinor
        row.normalizedSearchText = normalizedSearchText
        return row
    }
}

struct HistorySourceGapRecovery: Codable, Hashable, Sendable {
    var identifier: String
    var archiveIdentifier: String
    var startDay: Int32
    var endDay: Int32
    var accountIdentifier: String?
    var sourceIdentifier: String?
    var affectedSourceIdentifiers: [String]
    var completenessRaw: String
    var message: String

    @MainActor init(_ row: StoredHistorySourceGap) {
        identifier = row.identifier
        archiveIdentifier = row.archiveIdentifier
        startDay = row.startDay
        endDay = row.endDay
        accountIdentifier = row.accountIdentifier
        sourceIdentifier = row.sourceIdentifier
        affectedSourceIdentifiers = row.affectedSourceIdentifiers
        completenessRaw = row.completenessRaw
        message = row.message
    }

    @MainActor func model() -> StoredHistorySourceGap {
        let row = StoredHistorySourceGap(
            identifier: identifier,
            archiveIdentifier: archiveIdentifier,
            startDay: startDay,
            endDay: endDay,
            accountIdentifier: accountIdentifier,
            sourceIdentifier: sourceIdentifier,
            affectedSourceIdentifiers: affectedSourceIdentifiers,
            completenessRaw: completenessRaw,
            message: message
        )
        return row
    }
}

struct PeriodCheckpointDatasetRecovery: Codable, Hashable, Sendable {
    var identifier: String
    var establishedAt: Date

    @MainActor init(_ row: StoredPeriodCheckpointDataset) {
        identifier = row.identifier
        establishedAt = row.establishedAt
    }

    @MainActor func model() -> StoredPeriodCheckpointDataset {
        let row = StoredPeriodCheckpointDataset(
            identifier: identifier,
            establishedAt: establishedAt
        )
        return row
    }
}

struct PeriodCheckpointRevisionRecovery: Codable, Hashable, Sendable {
    var identifier: String
    var datasetIdentifier: String
    var periodStartDay: Int32
    var periodEndDay: Int32
    var periodKindRaw: String
    var revisionNumber: Int64
    var predecessorIdentifier: String?
    var closedAt: Date
    var qualityRaw: String
    var projectionFormatToken: String
    var projectionDigest: Data
    var canonicalProjection: Data
    var safeClaimMayShowCalculatedTotals: Bool
    var safeClaimUnquestionablyCompleteTotals: Bool
    var safeClaimCompleteCategoryAttribution: Bool
    var safeClaimCompleteEvidenceAudit: Bool
    var acknowledgmentCount: Int64
    var acknowledgmentDigest: Data

    @MainActor init(_ row: StoredPeriodCheckpointRevision) {
        identifier = row.identifier
        datasetIdentifier = row.datasetIdentifier
        periodStartDay = row.periodStartDay
        periodEndDay = row.periodEndDay
        periodKindRaw = row.periodKindRaw
        revisionNumber = row.revisionNumber
        predecessorIdentifier = row.predecessorIdentifier
        closedAt = row.closedAt
        qualityRaw = row.qualityRaw
        projectionFormatToken = row.projectionFormatToken
        projectionDigest = row.projectionDigest
        canonicalProjection = row.canonicalProjection
        safeClaimMayShowCalculatedTotals = row.safeClaimMayShowCalculatedTotals
        safeClaimUnquestionablyCompleteTotals = row.safeClaimUnquestionablyCompleteTotals
        safeClaimCompleteCategoryAttribution = row.safeClaimCompleteCategoryAttribution
        safeClaimCompleteEvidenceAudit = row.safeClaimCompleteEvidenceAudit
        acknowledgmentCount = row.acknowledgmentCount
        acknowledgmentDigest = row.acknowledgmentDigest
    }

    @MainActor func model() -> StoredPeriodCheckpointRevision {
        let row = StoredPeriodCheckpointRevision(
            identifier: identifier,
            datasetIdentifier: datasetIdentifier,
            periodStartDay: periodStartDay,
            periodEndDay: periodEndDay,
            periodKindRaw: periodKindRaw,
            revisionNumber: revisionNumber,
            predecessorIdentifier: predecessorIdentifier,
            closedAt: closedAt,
            qualityRaw: qualityRaw,
            projectionFormatToken: projectionFormatToken,
            projectionDigest: projectionDigest,
            canonicalProjection: canonicalProjection,
            safeClaimMayShowCalculatedTotals: safeClaimMayShowCalculatedTotals,
            safeClaimUnquestionablyCompleteTotals: safeClaimUnquestionablyCompleteTotals,
            safeClaimCompleteCategoryAttribution: safeClaimCompleteCategoryAttribution,
            safeClaimCompleteEvidenceAudit: safeClaimCompleteEvidenceAudit,
            acknowledgmentCount: acknowledgmentCount,
            acknowledgmentDigest: acknowledgmentDigest
        )
        return row
    }
}

struct PeriodCheckpointAcknowledgmentRecovery: Codable, Hashable, Sendable {
    var revisionIdentifier: String
    var exceptionIdentifier: String
    var kindRaw: String
    var aggregateBasisRaw: String?
    var day: Int32?
    var amountMinor: Int64?
    var amountCurrencyCode: String?
    var amountCurrencyExponent: Int?
    var sequence: Int

    @MainActor init(_ row: StoredPeriodCheckpointAcknowledgment) {
        revisionIdentifier = row.revisionIdentifier
        exceptionIdentifier = row.exceptionIdentifier
        kindRaw = row.kindRaw
        aggregateBasisRaw = row.aggregateBasisRaw
        day = row.day
        amountMinor = row.amountMinor
        amountCurrencyCode = row.amountCurrencyCode
        amountCurrencyExponent = row.amountCurrencyExponent
        sequence = row.sequence
    }

    @MainActor func model() -> StoredPeriodCheckpointAcknowledgment {
        let row = StoredPeriodCheckpointAcknowledgment(
            revisionIdentifier: revisionIdentifier,
            exceptionIdentifier: exceptionIdentifier,
            kindRaw: kindRaw,
            aggregateBasisRaw: aggregateBasisRaw,
            day: day,
            amountMinor: amountMinor,
            amountCurrencyCode: amountCurrencyCode,
            amountCurrencyExponent: amountCurrencyExponent,
            sequence: sequence
        )
        return row
    }
}
