import CryptoKit
import Foundation
import SwiftData
import FinanceCore

/// App recovery v1 preserves stored archive projections and accepted checkpoint
/// bytes. It does not turn archive rows into ledger entries or re-close periods.
struct FullRecoveryState: Codable, Hashable, Sendable {
    var version = 1
    var contentSHA256 = ""
    var archives: [HistoryArchiveRecovery] = []
    var historicalTransactions: [HistoricalTransactionRecovery] = []
    var historyGaps: [HistorySourceGapRecovery] = []
    var checkpointDatasets: [PeriodCheckpointDatasetRecovery] = []
    var checkpointRevisions: [PeriodCheckpointRevisionRecovery] = []
    var checkpointAcknowledgments: [PeriodCheckpointAcknowledgmentRecovery] = []
    var pendingSnapshots: [String: AuthoritativePendingSnapshot] = [:]
    var liveCoverage: [String: AuthoritativeLiveCoverage] = [:]
    var lastExpenseAccountID: String?
    var lastIncomeAccountID: String?

    @MainActor static func capture(from context: ModelContext) throws -> Self {
        let metadata = try StoredDocumentGraph.loadAppMetadata(from: context)
        var state = Self(
            archives: try context.fetch(FetchDescriptor<StoredHistoryArchive>()).map(HistoryArchiveRecovery.init).sorted { $0.identifier < $1.identifier },
            historicalTransactions: try context.fetch(FetchDescriptor<StoredHistoricalTransaction>()).map(HistoricalTransactionRecovery.init).sorted { $0.identifier < $1.identifier },
            historyGaps: try context.fetch(FetchDescriptor<StoredHistorySourceGap>()).map(HistorySourceGapRecovery.init).sorted { $0.identifier < $1.identifier },
            checkpointDatasets: try context.fetch(FetchDescriptor<StoredPeriodCheckpointDataset>()).map(PeriodCheckpointDatasetRecovery.init).sorted { $0.identifier < $1.identifier },
            checkpointRevisions: try context.fetch(FetchDescriptor<StoredPeriodCheckpointRevision>()).map(PeriodCheckpointRevisionRecovery.init).sorted { $0.identifier < $1.identifier },
            checkpointAcknowledgments: try context.fetch(FetchDescriptor<StoredPeriodCheckpointAcknowledgment>()).map(PeriodCheckpointAcknowledgmentRecovery.init).sorted {
                $0.revisionIdentifier == $1.revisionIdentifier ? $0.sequence < $1.sequence : $0.revisionIdentifier < $1.revisionIdentifier
            },
            pendingSnapshots: Dictionary(uniqueKeysWithValues: metadata.authoritativePendingSnapshots.map { ($0.key.rawValue, $0.value) }),
            liveCoverage: metadata.authoritativeLiveCoverage,
            lastExpenseAccountID: metadata.lastExpenseAccountID,
            lastIncomeAccountID: metadata.lastIncomeAccountID
        )
        state.contentSHA256 = try state.integrityDigest()
        return state
    }

    /// Detects corruption of the stored projection independently of the original
    /// archive provenance hash. Encryption additionally authenticates the package.
    func integrityDigest() throws -> String {
        var content = self
        content.contentSHA256 = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = Data("finance-app/full-recovery/v1\0".utf8) + (try encoder.encode(content))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor func validate(document: FinanceDocument) throws {
        do {
            guard version == 1, contentSHA256 == (try integrityDigest()) else { throw AppImportError.invalidBackupMetadata }
            let accountIDs = Set(document.accounts.map(\.id))
            guard [lastExpenseAccountID, lastIncomeAccountID].compactMap({ $0 }).allSatisfy(accountIDs.contains) else {
                throw AppImportError.invalidBackupMetadata
            }
            let observations = Dictionary(document.externalObservations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard observations.count == document.externalObservations.count else { throw AppImportError.invalidBackupMetadata }
            for (provider, snapshot) in pendingSnapshots {
                guard !provider.isEmpty, provider == ExternalProvider(rawValue: provider).rawValue,
                      snapshot.authoritativeAt.timeIntervalSinceReferenceDate.isFinite,
                      snapshot.observationIDs.allSatisfy({ observations[$0]?.provider.rawValue == provider && observations[$0]?.status == .pending }) else {
                    throw AppImportError.invalidBackupMetadata
                }
            }
            for (key, coverage) in liveCoverage {
                guard key == coverage.remoteOpaqueAccountID, coverage.interval != nil,
                      coverage.authoritativeAt.timeIntervalSinceReferenceDate.isFinite,
                      document.externalAccountBindings.contains(where: {
                          $0.remoteOpaqueAccountID == key && $0.localAccountID == coverage.localAccountID && $0.provider == coverage.provider
                      }) else { throw AppImportError.invalidBackupMetadata }
            }
            try validateHistory()
            guard checkpointDatasets.allSatisfy({ $0.establishedAt.timeIntervalSinceReferenceDate.isFinite }),
                  checkpointRevisions.allSatisfy({
                      $0.closedAt.timeIntervalSinceReferenceDate.isFinite
                  }) else { throw AppImportError.invalidBackupMetadata }
            // Reuse the repository's chain, canonical digest, acknowledgment and
            // safe-claims checks in an isolated context. No destination is touched.
            let schema = Schema([StoredPeriodCheckpointDataset.self, StoredPeriodCheckpointRevision.self, StoredPeriodCheckpointAcknowledgment.self])
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = container.mainContext
            context.autosaveEnabled = false
            insertCheckpoints(in: context)
            try context.save()
            if case .unreadable = PeriodCheckpointRepository(context: context).occupancy() {
                throw AppImportError.invalidBackupMetadata
            }
        } catch { throw AppImportError.invalidBackupMetadata }
    }

    @MainActor private func validateHistory() throws {
        guard archives.count <= 1 else { throw AppImportError.invalidBackupMetadata }
        guard let archive = archives.first else {
            guard historicalTransactions.isEmpty, historyGaps.isEmpty else { throw AppImportError.invalidBackupMetadata }
            return
        }
        guard FinanceHistoryInterchange.readableSchemaVersions.contains(archive.schemaVersion),
              archive.documentKind == FinanceHistoryInterchange.documentKind,
              archive.contentSHA256.count == 64,
              archive.contentSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
              archive.importedAt.timeIntervalSinceReferenceDate.isFinite,
              archive.accountIdentifiers.count == archive.accountNames.count,
              archive.categoryIdentifiers.count == archive.categoryNames.count,
              archive.sourceIdentifiers.count == archive.sourceNames.count,
              Set(archive.accountIdentifiers).count == archive.accountIdentifiers.count,
              Set(archive.categoryIdentifiers).count == archive.categoryIdentifiers.count,
              Set(archive.sourceIdentifiers).count == archive.sourceIdentifiers.count,
              Set(historicalTransactions.map(\.identifier)).count == historicalTransactions.count,
              Set(historyGaps.map(\.identifier)).count == historyGaps.count else {
            throw AppImportError.invalidBackupMetadata
        }
        func day(_ ordinal: Int32) throws -> Day {
            guard let day = Day(persistenceOrdinal: ordinal) else { throw AppImportError.invalidBackupMetadata }
            return day
        }
        guard Set(archive.economicTypes) == Set(historicalTransactions.map(\.economicTypeRaw)),
              Set(archive.economicSources) == Set(historicalTransactions.compactMap(\.economicSourceRaw)),
              Set(archive.currencies) == Set(historicalTransactions.map(\.currencyCode)),
              Set(archive.statuses) == Set(historicalTransactions.map(\.statusRaw)),
              Set(archive.provenanceValues) == Set(historicalTransactions.map(\.provenanceRaw)) else {
            throw AppImportError.invalidBackupMetadata
        }
        let accountNames = Dictionary(uniqueKeysWithValues: zip(archive.accountIdentifiers, archive.accountNames))
        let categoryNames = Dictionary(uniqueKeysWithValues: zip(archive.categoryIdentifiers, archive.categoryNames))
        let sourceNames = Dictionary(uniqueKeysWithValues: zip(archive.sourceIdentifiers, archive.sourceNames))
        let records = try historicalTransactions.map { row -> FinanceHistoricalRecord in
            guard row.archiveIdentifier == archive.identifier,
                  row.amountMinor != .min, row.absoluteAmountMinor == Swift.abs(row.amountMinor),
                  accountNames[row.accountIdentifier] == row.accountName,
                  categoryNames[row.categoryIdentifier] == row.categoryName,
                  sourceNames[row.sourceIdentifier] == row.sourceName,
                  row.categoryIdentifier == [row.categoryTop, row.categorySub].compactMap({ $0 }).joined(separator: "::"),
                  let passThrough = FinanceHistoryPassThrough(rawValue: row.passThroughRaw),
                  row.normalizedSearchText == FinanceHistorySearchNormalization.joining([row.merchant, row.counterparty, row.displayDescription, row.originalDescription, row.categoryTop, row.categorySub, row.accountName, row.sourceName]) else {
                throw AppImportError.invalidBackupMetadata
            }
            return FinanceHistoricalRecord(
                historicalID: row.identifier, date: try day(row.valueDay), accountID: row.accountIdentifier,
                provider: row.sourceIdentifier, rail: row.railRaw, merchant: row.merchant,
                description: row.displayDescription, rawDescription: row.originalDescription,
                originalAmount: FinanceHistoryOriginalAmount(cents: row.amountMinor, currency: row.currencyCode, currencyExponent: row.currencyExponent),
                bookedAmountEURCents: row.bookedAmountEURMinor, economicAmountEURCents: row.economicAmountEURMinor,
                personalAmountEURCents: row.personalAmountEURMinor,
                category: FinanceHistoryCategory(top: row.categoryTop, sub: row.categorySub),
                economicType: row.economicTypeRaw, economicSource: row.economicSourceRaw, status: row.statusRaw,
                provenance: row.provenanceRaw, confidence: row.confidenceRaw,
                flags: FinanceHistoryFlags(internalTransfer: row.isInternalTransfer, passThrough: passThrough, financingLeg: row.isFinancingLeg),
                economicViewRole: row.economicViewRoleRaw,
                links: FinanceHistoryLinks(crossInstitutionPair: row.crossInstitutionPairIdentifier, refundID: row.refundIdentifier,
                    purchaseID: row.purchaseIdentifier, financingID: row.financingIdentifier, confirmationID: row.confirmationIdentifier,
                    linkedTransactionID: row.linkedTransactionIdentifier, groupID: row.groupIdentifier),
                evidence: FinanceHistoryEvidence(ruleID: row.evidenceRuleIdentifier, basis: row.evidenceBasis, unresolvedReason: row.evidenceUnresolvedReason)
            )
        }
        let gaps = try historyGaps.map { gap -> FinanceHistorySourceGap in
            let start = try day(gap.startDay), end = try day(gap.endDay)
            guard gap.archiveIdentifier == archive.identifier, start <= end,
                  start == start.monthKey.firstDay, end == end.monthKey.firstDay.lastDayOfMonth,
                  gap.accountIdentifier == nil,
                  gap.sourceIdentifier == (gap.affectedSourceIdentifiers.count == 1 ? gap.affectedSourceIdentifiers[0] : nil) else {
                throw AppImportError.invalidBackupMetadata
            }
            return FinanceHistorySourceGap(startMonth: start.monthKey, endMonth: end.monthKey,
                completeness: gap.completenessRaw, affectedSources: gap.affectedSourceIdentifiers, message: gap.message)
        }
        // Validate canonical semantics without pretending the query projection is
        // the original archive file. The original provenance hash is preserved.
        _ = try FinanceHistoryInterchange.make(archiveID: archive.identifier, sourceRevision: archive.sourceRevision,
            payload: FinanceHistoryPayload(archiveCutoff: try day(archive.cutoffDay), recordCount: archive.recordCount,
                dateRange: FinanceHistoryDateRange(start: try day(archive.firstDay), end: try day(archive.lastDay)),
                accounts: zip(archive.accountIdentifiers, archive.accountNames).map { id, name in
                    FinanceHistoryAccount(id: id, name: name, provider: records.first(where: { $0.accountID == id })?.provider ?? "archive")
                }, sourceGaps: gaps, records: records))
    }

    @MainActor func insert(in context: ModelContext) {
        archives.map { $0.model() }.forEach(context.insert)
        historicalTransactions.map { $0.model() }.forEach(context.insert)
        historyGaps.map { $0.model() }.forEach(context.insert)
        insertCheckpoints(in: context)
    }

    @MainActor private func insertCheckpoints(in context: ModelContext) {
        checkpointDatasets.map { $0.model() }.forEach(context.insert)
        checkpointRevisions.map { $0.model() }.forEach(context.insert)
        checkpointAcknowledgments.map { $0.model() }.forEach(context.insert)
    }

    @MainActor static func destinationIsEmpty(_ context: ModelContext) throws -> Bool {
        try context.fetchCount(FetchDescriptor<StoredHistoryArchive>()) == 0 &&
        context.fetchCount(FetchDescriptor<StoredHistoricalTransaction>()) == 0 &&
        context.fetchCount(FetchDescriptor<StoredHistorySourceGap>()) == 0 &&
        context.fetchCount(FetchDescriptor<StoredPeriodCheckpointDataset>()) == 0 &&
        context.fetchCount(FetchDescriptor<StoredPeriodCheckpointRevision>()) == 0 &&
        context.fetchCount(FetchDescriptor<StoredPeriodCheckpointAcknowledgment>()) == 0 &&
        context.fetchCount(FetchDescriptor<StoredPendingEvidenceArchive>()) == 0
    }
}
