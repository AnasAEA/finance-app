import Foundation
import Observation
import SwiftData
import FinanceCore

enum HistoryArchiveImportError: Error, Equatable, CustomStringConvertible {
    case fileUnreadable
    case invalidArchive
    case nothingPrepared
    case persistenceFailed

    var description: String {
        switch self {
        case .fileUnreadable: "The selected historical archive could not be read."
        case .invalidArchive: "The selected file is not a valid historical archive."
        case .nothingPrepared: "Choose and review a historical archive first."
        case .persistenceFailed: "The historical archive could not be saved. The previous archive is unchanged."
        }
    }
}

/// Import and query boundary for private reconstructed history.
///
/// The pending document is intentionally in memory only between preview and
/// confirmation. Confirmation runs in a dedicated ModelContext so rollback
/// can never discard unsaved edits in the operational context.
@Observable
@MainActor
final class HistoryArchiveService {
    private let queries: HistoryArchiveQueries
    @ObservationIgnored private let importContext: ModelContext?
    @ObservationIgnored private var pendingDocument: FinanceHistoryDocument?

    private(set) var pendingImportPreview: HistoryImportPreview?
    private var installedArchiveRevision = 0

    private let now: () -> Date

    init(context: ModelContext?, now: @escaping () -> Date = Date.init) {
        self.now = now
        queries = HistoryArchiveQueries(context: context)
        importContext = context.map { ModelContext($0.container) }
    }

    var hasImportedArchive: Bool {
        _ = installedArchiveRevision
        return (try? queries.hasImportedArchive) ?? false
    }

    func metadata() throws -> HistoryArchiveMetadata? {
        try queries.metadata()
    }

    func prepareImport(contentsOf url: URL) throws -> HistoryImportPreview {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw HistoryArchiveImportError.fileUnreadable
        }
        return try prepareImport(data: data)
    }

    func prepareImport(data: Data) throws -> HistoryImportPreview {
        let document: FinanceHistoryDocument
        do {
            document = try FinanceHistoryInterchange.decodeValidated(data)
        } catch {
            pendingDocument = nil
            pendingImportPreview = nil
            throw HistoryArchiveImportError.invalidArchive
        }
        let preview = preview(
            document,
            replacesExistingArchive: (try? queries.hasImportedArchive) ?? false
        )
        pendingDocument = document
        pendingImportPreview = preview
        return preview
    }

    func cancelImport() {
        pendingDocument = nil
        pendingImportPreview = nil
    }

    func confirmImport() throws -> HistoryImportOutcome {
        guard let document = pendingDocument, let importContext else {
            throw HistoryArchiveImportError.nothingPrepared
        }
        do {
            let outcome = try HistoryArchivePersistence.replace(
                with: document,
                in: importContext,
                importedAt: now()
            )
            pendingDocument = nil
            pendingImportPreview = nil
            installedArchiveRevision += 1
            return outcome
        } catch let error as HistoryArchiveImportError {
            throw error
        } catch {
            throw HistoryArchiveImportError.persistenceFailed
        }
    }

    func filterCatalog() throws -> HistoryFilterCatalog {
        try queries.filterCatalog()
    }

    func page(
        matching query: HistoryQuery = HistoryQuery(),
        offset: Int = 0,
        limit: Int = 100
    ) throws -> HistoryPage {
        try queries.page(matching: query, offset: offset, limit: limit)
    }

    func detail(id: String) throws -> HistoryTransactionDetail? {
        try queries.detail(id: id)
    }

    private func preview(
        _ document: FinanceHistoryDocument,
        replacesExistingArchive: Bool
    ) -> HistoryImportPreview {
        let payload = document.payload
        return HistoryImportPreview(
            archiveID: document.archiveID,
            schemaVersion: document.schemaVersion,
            transactionCount: payload.recordCount,
            dateRange: calendarDay(payload.dateRange.start)...calendarDay(payload.dateRange.end),
            archiveCutoff: calendarDay(payload.archiveCutoff),
            accounts: payload.accounts
                .map { HistoryFilterOption(id: $0.id, name: $0.name) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            currencies: Array(Set(payload.records.map(\.originalAmount.currency))).sorted(),
            sourceCoverageGapCount: payload.sourceGaps.count,
            replacesExistingArchive: replacesExistingArchive
        )
    }
}

enum HistoryArchivePersistence {
    /// Test hook runs inside the atomic unit after new rows are inserted but
    /// before save. Production leaves it empty; tests use it to prove rollback
    /// retains the previously installed archive.
    static func replace(
        with document: FinanceHistoryDocument,
        in context: ModelContext,
        importedAt: Date,
        beforeSave: () throws -> Void = {}
    ) throws -> HistoryImportOutcome {
        do {
            try FinanceHistoryInterchange.validate(document)
        } catch {
            throw HistoryArchiveImportError.invalidArchive
        }

        if let existing = try context.fetch(FetchDescriptor<StoredHistoryArchive>()).first,
           existing.identifier == document.archiveID,
           existing.contentSHA256 == document.contentSHA256 {
            let archiveID = existing.identifier
            let count = try context.fetchCount(
                FetchDescriptor<StoredHistoricalTransaction>(
                    predicate: #Predicate { $0.archiveIdentifier == archiveID }
                )
            )
            if count == document.payload.recordCount {
                return .unchanged(try metadata(existing))
            }
        }

        // Construct and validate the full projection before deleting anything.
        let projection = try projection(of: document, importedAt: importedAt)
        do {
            try purge(in: context)
            context.insert(projection.archive)
            projection.transactions.forEach(context.insert)
            projection.gaps.forEach(context.insert)
            try beforeSave()
            try context.save()
            return .imported(try metadata(projection.archive))
        } catch {
            context.rollback()
            throw error
        }
    }

    private struct Projection {
        let archive: StoredHistoryArchive
        let transactions: [StoredHistoricalTransaction]
        let gaps: [StoredHistorySourceGap]
    }

    private static func projection(
        of document: FinanceHistoryDocument,
        importedAt: Date
    ) throws -> Projection {
        let payload = document.payload
        let accounts = Dictionary(
            payload.accounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let rows = try payload.records.map { record -> StoredHistoricalTransaction in
            let account = accounts[record.accountID]!
            let categoryID = [record.category.top, record.category.sub]
                .compactMap { $0 }
                .joined(separator: "::")
            let categoryName = record.category.sub ?? record.category.top
            // FinanceCore resolves the archive amount authoritatively — 2.0.0
            // states the exponent, 1.x reads it from the frozen historical
            // table. The importer must not rebuild a `Currency` from the code,
            // which would put the evolving registry back in the path and let a
            // later currency-support commit change what old archives mean.
            guard let money = record.originalAmount.money else {
                throw HistoryArchiveImportError.invalidArchive
            }
            return StoredHistoricalTransaction(
                identifier: record.historicalID,
                archiveIdentifier: document.archiveID,
                valueDay: try PersistenceCoding.ordinal(record.date),
                amountMinor: money.minorUnits,
                currencyCode: money.currency.code,
                currencyExponent: money.currency.minorUnitDigits,
                bookedAmountEURMinor: record.bookedAmountEURCents,
                economicAmountEURMinor: record.economicAmountEURCents,
                personalAmountEURMinor: record.personalAmountEURCents,
                accountIdentifier: record.accountID,
                accountName: account.name,
                railRaw: record.rail,
                merchant: record.merchant,
                counterparty: nil,
                displayDescription: record.description,
                originalDescription: record.rawDescription,
                categoryIdentifier: categoryID,
                categoryName: categoryName,
                categoryTop: record.category.top,
                categorySub: record.category.sub,
                economicTypeRaw: record.economicType,
                economicSourceRaw: record.economicSource,
                statusRaw: record.status,
                sourceIdentifier: record.provider,
                sourceName: record.provider,
                provenanceRaw: record.provenance,
                confidenceRaw: record.confidence,
                economicViewRoleRaw: record.economicViewRole,
                isInternalTransfer: record.flags.internalTransfer,
                passThroughRaw: record.flags.passThrough.rawValue,
                isFinancingLeg: record.flags.financingLeg,
                crossInstitutionPairIdentifier: record.links.crossInstitutionPair,
                refundIdentifier: record.links.refundID,
                purchaseIdentifier: record.links.purchaseID,
                financingIdentifier: record.links.financingID,
                confirmationIdentifier: record.links.confirmationID,
                linkedTransactionIdentifier: record.links.linkedTransactionID,
                groupIdentifier: record.links.groupID,
                evidenceRuleIdentifier: record.evidence.ruleID,
                evidenceBasis: record.evidence.basis,
                evidenceUnresolvedReason: record.evidence.unresolvedReason
            )
        }

        let gaps = try payload.sourceGaps.enumerated().map { index, gap in
            let startDay = try PersistenceCoding.ordinal(gap.startMonth.firstDay)
            let endDay = try PersistenceCoding.ordinal(gap.endMonth.firstDay.lastDayOfMonth)
            return StoredHistorySourceGap(
                identifier: "gap-\(gap.startMonth.isoString)-\(gap.endMonth.isoString)-\(index)",
                archiveIdentifier: document.archiveID,
                startDay: startDay,
                // The gap ends on the last day of its end month. Reading that
                // day directly is exact and needs no boundary movement, where
                // "first day of the next month, minus one" needed two.
                endDay: endDay,
                accountIdentifier: nil,
                sourceIdentifier: gap.affectedSources.count == 1 ? gap.affectedSources[0] : nil,
                affectedSourceIdentifiers: gap.affectedSources.sorted(),
                completenessRaw: gap.completeness,
                message: gap.message
            )
        }

        let accountOptions = payload.accounts.sorted { $0.name < $1.name }
        let categoryOptions = Dictionary(
            rows.map { ($0.categoryIdentifier, $0.categoryName) },
            uniquingKeysWith: { first, _ in first }
        ).sorted { ($0.value, $0.key) < ($1.value, $1.key) }
        let sourceOptions = Dictionary(
            payload.accounts.map { ($0.provider, $0.provider) },
            uniquingKeysWith: { first, _ in first }
        ).sorted { $0.key < $1.key }

        let archive = StoredHistoryArchive(
            identifier: document.archiveID,
            schemaVersion: document.schemaVersion,
            documentKind: document.documentKind,
            sourceRevision: document.sourceRevision,
            contentSHA256: document.contentSHA256,
            cutoffDay: try PersistenceCoding.ordinal(payload.archiveCutoff),
            firstDay: try PersistenceCoding.ordinal(payload.dateRange.start),
            lastDay: try PersistenceCoding.ordinal(payload.dateRange.end),
            recordCount: payload.recordCount,
            importedAt: importedAt,
            accountIdentifiers: accountOptions.map(\.id),
            accountNames: accountOptions.map(\.name),
            categoryIdentifiers: categoryOptions.map(\.key),
            categoryNames: categoryOptions.map(\.value),
            economicTypes: Array(Set(rows.map(\.economicTypeRaw))).sorted(),
            economicSources: Array(Set(rows.compactMap(\.economicSourceRaw))).sorted(),
            currencies: Array(Set(rows.map(\.currencyCode))).sorted(),
            sourceIdentifiers: sourceOptions.map(\.key),
            sourceNames: sourceOptions.map(\.value),
            statuses: Array(Set(rows.map(\.statusRaw))).sorted(),
            provenanceValues: Array(Set(rows.map(\.provenanceRaw))).sorted()
        )
        return Projection(archive: archive, transactions: rows, gaps: gaps)
    }

    private static func purge(in context: ModelContext) throws {
        try context.fetch(FetchDescriptor<StoredHistoricalTransaction>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<StoredHistorySourceGap>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<StoredHistoryArchive>()).forEach(context.delete)
    }

    static func metadata(_ row: StoredHistoryArchive) throws -> HistoryArchiveMetadata {
        HistoryArchiveMetadata(
            archiveID: row.identifier,
            schemaVersion: row.schemaVersion,
            sourceRevision: row.sourceRevision,
            contentSHA256: row.contentSHA256,
            transactionCount: row.recordCount,
            dateRange: try historyCalendarDay(row.firstDay)...historyCalendarDay(row.lastDay),
            archiveCutoff: try historyCalendarDay(row.cutoffDay),
            importedAt: row.importedAt
        )
    }
}

private func calendarDay(_ day: Day) -> CalendarDay {
    CalendarDay(year: day.year, month: day.month, day: day.day)
}

private func historyCalendarDay(_ ordinal: Int32) throws -> CalendarDay {
    guard let day = Day(persistenceOrdinal: ordinal) else {
        throw HistoryArchiveQueryError.invalidDate(ordinal)
    }
    return calendarDay(day)
}
