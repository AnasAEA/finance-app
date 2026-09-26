import Foundation
import SwiftData
import FinanceCore

/// Durable local storage for accepted period checkpoint revisions.
///
/// ## Why this is a subgraph of its own
///
/// A checkpoint revision records what a person accepted about a period at a
/// moment in the past. `FinanceDocument` records what is true of the ledger
/// now, and every ordinary write replaces it wholesale — `StoredDocumentGraph`
/// purges and re-inserts the entire graph on each save. History that lived in
/// that graph would have to be carried forward, in memory, through every
/// document write in the app, and the first path that forgot would silently
/// destroy the record rather than fail. So these rows are deliberately **not**
/// in `StoredDocumentGraph.purge`, not in `FinanceDocument`, not in
/// `DomainMapper`'s payload and not in `AppPersistenceMetadata`. They share the
/// container and the schema; they share nothing else.
///
/// They are also **local metadata, not interchange**. No field here reaches
/// `FinanceDocument`, `FinanceHistoryInterchange`, the external archive
/// export schema or the bank-sync schema. The separately versioned app recovery
/// section now snapshots these rows losslessly into encrypted backups and restores
/// their validated lineage in the same atomic save as the ledger. Device secrets
/// remain excluded. A full app or container reset removes these local rows.
///
/// ## Why no `#Unique` here
///
/// Every other stored model in this app has replace-or-upsert semantics, and
/// `#Unique` expresses that well. Checkpoint history is append-only: a stored
/// revision is never rewritten. `#Unique` resolves a conflicting insert by
/// *upserting* — silently overwriting the row it collides with — which is
/// exactly the mutation this subgraph must refuse. Uniqueness is therefore an
/// explicit, testable check in `PeriodCheckpointRepository`, on the way in and
/// again on the way out, and a duplicate is corruption rather than a merge.
///
/// ## Why raw tokens
///
/// The projection format token, the period kind, the quality, the exception
/// kind and the aggregate basis are all stored as raw strings. A future build
/// may write a projection format this one cannot read, and that row must stay
/// *readable as a header* rather than failing to decode — see
/// `PeriodCheckpointStoredRead.unsupportedFormat`. Modelling the format as
/// `SemanticPeriodProjectionFormat` would make an unknown token undecodable and
/// erase the distinction between "written by a later build" and "corrupt". The
/// closed domain vocabularies are stored raw for the opposite reason: SwiftData
/// must never coerce an unrecognised token into a plausible default, so the
/// repository maps each one explicitly and refuses what it does not know.

/// One local checkpoint dataset identity.
///
/// `FinanceDocument` has no stable dataset identity, and
/// `StoredDocumentMeta.documentRevision` is minted fresh on every write, so it
/// identifies a *save*, not a dataset. This row exists so checkpoint history
/// cannot silently attach itself to a different set of imported financial data:
/// the first stored revision mints the identity, every later revision must
/// carry it, and importing a different document into this container is refused
/// while this row exists.
@Model
final class StoredPeriodCheckpointDataset {
    /// A UUID string. A value that does not parse is corruption, never a
    /// dataset this build simply does not recognise.
    var identifier: String = ""

    /// When this local identity was minted. Audit metadata; never an authority
    /// for ordering revisions.
    var establishedAt: Date = Date.distantPast

    init(identifier: String, establishedAt: Date) {
        self.identifier = identifier
        self.establishedAt = establishedAt
    }
}

/// One accepted, closed checkpoint revision, stored losslessly.
///
/// The canonical projection is kept as opaque bytes on purpose: its V1 wire
/// format is frozen and self-describing, and re-deriving it from stored columns
/// would make historical readability depend on today's projection code. The
/// digest is stored beside it so a payload that no longer hashes to what was
/// accepted is detectable rather than merely different.
@Model
final class StoredPeriodCheckpointRevision {
    #Index<StoredPeriodCheckpointRevision>(
        [\.periodStartDay, \.periodEndDay, \.periodKindRaw],
        [\.datasetIdentifier]
    )

    /// The revision's own UUID, as a string.
    var identifier: String = ""

    /// The dataset identity this revision belongs to.
    var datasetIdentifier: String = ""

    /// Exact period identity. A history key is start + end + kind — never a
    /// month string, a start day alone, or a revision number.
    var periodStartDay: Int32 = 0
    var periodEndDay: Int32 = 0
    var periodKindRaw: String = ""

    var revisionNumber: Int64 = 0

    /// nil exactly for revision 1. For a later revision this must name the
    /// stored row for N-1 in the same period, kind and dataset — a fact only
    /// the repository can prove.
    var predecessorIdentifier: String?

    /// Audit/display metadata. Never the authority for which revision is
    /// latest; that is the highest valid revision number.
    var closedAt: Date = Date.distantPast

    /// `PeriodCheckpointQuality` raw value, verbatim.
    var qualityRaw: String = ""

    /// `SemanticPeriodProjectionFormat` token, verbatim and un-normalized.
    var projectionFormatToken: String = ""

    /// The 32-byte value digest recorded at close.
    var projectionDigest: Data = Data()

    /// The frozen canonical projection bytes, exactly as accepted.
    var canonicalProjection: Data = Data()

    /// The safe claims recorded at close, as four explicit audit fields rather
    /// than a synthesized blob. They are history, never a comparison authority:
    /// rehydration re-derives them from the accepted exception set and refuses
    /// a row whose stored claims do not follow from it.
    var safeClaimMayShowCalculatedTotals: Bool = false
    var safeClaimUnquestionablyCompleteTotals: Bool = false
    var safeClaimCompleteCategoryAttribution: Bool = false
    var safeClaimCompleteEvidenceAudit: Bool = false

    /// Independent commitment to the exact accepted acknowledgment array.
    /// Derived at write from `PeriodCheckpointRevision.acknowledgedExceptions`;
    /// never supplied by a caller, and never inferred from quality or claims.
    var acknowledgmentCount: Int64 = 0

    /// SHA-256 of `CheckpointAcknowledgmentCommitment` bytes for that array.
    /// An empty array still has a digest; nil is not a clean period.
    var acknowledgmentDigest: Data = Data()

    init(
        identifier: String,
        datasetIdentifier: String,
        periodStartDay: Int32,
        periodEndDay: Int32,
        periodKindRaw: String,
        revisionNumber: Int64,
        predecessorIdentifier: String?,
        closedAt: Date,
        qualityRaw: String,
        projectionFormatToken: String,
        projectionDigest: Data,
        canonicalProjection: Data,
        safeClaimMayShowCalculatedTotals: Bool,
        safeClaimUnquestionablyCompleteTotals: Bool,
        safeClaimCompleteCategoryAttribution: Bool,
        safeClaimCompleteEvidenceAudit: Bool,
        acknowledgmentCount: Int64,
        acknowledgmentDigest: Data
    ) {
        self.identifier = identifier
        self.datasetIdentifier = datasetIdentifier
        self.periodStartDay = periodStartDay
        self.periodEndDay = periodEndDay
        self.periodKindRaw = periodKindRaw
        self.revisionNumber = revisionNumber
        self.predecessorIdentifier = predecessorIdentifier
        self.closedAt = closedAt
        self.qualityRaw = qualityRaw
        self.projectionFormatToken = projectionFormatToken
        self.projectionDigest = projectionDigest
        self.canonicalProjection = canonicalProjection
        self.safeClaimMayShowCalculatedTotals = safeClaimMayShowCalculatedTotals
        self.safeClaimUnquestionablyCompleteTotals = safeClaimUnquestionablyCompleteTotals
        self.safeClaimCompleteCategoryAttribution = safeClaimCompleteCategoryAttribution
        self.safeClaimCompleteEvidenceAudit = safeClaimCompleteEvidenceAudit
        self.acknowledgmentCount = acknowledgmentCount
        self.acknowledgmentDigest = acknowledgmentDigest
    }
}

/// One acknowledged exception, as that revision recorded it.
///
/// A **snapshot**, not an identity. There is deliberately no semantic key, no
/// cross-revision equality and no carry-forward matching here: acknowledgment
/// identity across revisions has an unresolved aggregate-pairing problem that
/// owes a dedicated review, and freezing a key in storage would decide it by
/// accident. `sequence` preserves the order the revision held, so a stored
/// revision round-trips to the exact array it was written from.
@Model
final class StoredPeriodCheckpointAcknowledgment {
    #Index<StoredPeriodCheckpointAcknowledgment>([\.revisionIdentifier])

    var revisionIdentifier: String = ""

    /// The exception's caller-supplied stable id, verbatim.
    var exceptionIdentifier: String = ""

    /// `PeriodCheckpointExceptionKind` raw value.
    var kindRaw: String = ""

    /// `AggregateEvidenceBasis` raw value. Present exactly for
    /// `.aggregateEvidenceModelLimitation`; the domain type traps on any other
    /// pairing, so the repository checks this before it constructs one.
    var aggregateBasisRaw: String?

    var day: Int32?

    var amountMinor: Int64?
    var amountCurrencyCode: String?
    var amountCurrencyExponent: Int?

    /// Position within the revision's acknowledgment array.
    var sequence: Int = 0

    init(
        revisionIdentifier: String,
        exceptionIdentifier: String,
        kindRaw: String,
        aggregateBasisRaw: String?,
        day: Int32?,
        amountMinor: Int64?,
        amountCurrencyCode: String?,
        amountCurrencyExponent: Int?,
        sequence: Int
    ) {
        self.revisionIdentifier = revisionIdentifier
        self.exceptionIdentifier = exceptionIdentifier
        self.kindRaw = kindRaw
        self.aggregateBasisRaw = aggregateBasisRaw
        self.day = day
        self.amountMinor = amountMinor
        self.amountCurrencyCode = amountCurrencyCode
        self.amountCurrencyExponent = amountCurrencyExponent
        self.sequence = sequence
    }
}

// MARK: - Projection of a domain revision onto rows

extension StoredPeriodCheckpointRevision {
    /// Row form of an already-created, already-validated revision.
    ///
    /// This is the **only** direction this file converts in. Reading rows back
    /// goes through `PeriodCheckpointRepository`, which validates the stored
    /// history and then hands the domain fields to
    /// `PeriodCheckpointRevision.init(rehydratingStoredSnapshot:)`. Nothing
    /// here reconstructs a revision, and nothing here decides whether one may
    /// be accepted.
    convenience init(_ revision: PeriodCheckpointRevision, datasetIdentifier: String) throws {
        let start = try PersistenceCoding.ordinal(revision.period.start)
        let end = try PersistenceCoding.ordinal(revision.period.end)
        let digest = try CheckpointAcknowledgmentCommitment.digest(of: revision.acknowledgedExceptions)
        self.init(
            identifier: revision.id.uuidString,
            datasetIdentifier: datasetIdentifier,
            periodStartDay: start,
            periodEndDay: end,
            periodKindRaw: revision.periodKind.rawValue,
            revisionNumber: revision.revisionNumber,
            predecessorIdentifier: revision.predecessorID?.uuidString,
            closedAt: revision.closedAt,
            qualityRaw: revision.quality.rawValue,
            projectionFormatToken: revision.projectionFormatVersion.token,
            projectionDigest: Data(revision.projectionDigest.bytes),
            canonicalProjection: Data(revision.canonicalProjection.bytes),
            safeClaimMayShowCalculatedTotals: revision.safeClaims.mayShowCalculatedTotals,
            safeClaimUnquestionablyCompleteTotals: revision.safeClaims.unquestionablyCompleteTotals,
            safeClaimCompleteCategoryAttribution: revision.safeClaims.completeCategoryAttribution,
            safeClaimCompleteEvidenceAudit: revision.safeClaims.completeEvidenceAudit,
            acknowledgmentCount: Int64(revision.acknowledgedExceptions.count),
            acknowledgmentDigest: digest
        )
    }

    /// True when every persisted field of this row equals the other's.
    ///
    /// Storing the same revision twice is only a no-op when the two are the
    /// same bytes as well as the same id; see
    /// `PeriodCheckpointRepository.store(_:)`.
    func hasIdenticalContent(to other: StoredPeriodCheckpointRevision) -> Bool {
        identifier == other.identifier
            && datasetIdentifier == other.datasetIdentifier
            && periodStartDay == other.periodStartDay
            && periodEndDay == other.periodEndDay
            && periodKindRaw == other.periodKindRaw
            && revisionNumber == other.revisionNumber
            && predecessorIdentifier == other.predecessorIdentifier
            && closedAt == other.closedAt
            && qualityRaw == other.qualityRaw
            && projectionFormatToken == other.projectionFormatToken
            && projectionDigest == other.projectionDigest
            && canonicalProjection == other.canonicalProjection
            && safeClaimMayShowCalculatedTotals == other.safeClaimMayShowCalculatedTotals
            && safeClaimUnquestionablyCompleteTotals == other.safeClaimUnquestionablyCompleteTotals
            && safeClaimCompleteCategoryAttribution == other.safeClaimCompleteCategoryAttribution
            && safeClaimCompleteEvidenceAudit == other.safeClaimCompleteEvidenceAudit
            && acknowledgmentCount == other.acknowledgmentCount
            && acknowledgmentDigest == other.acknowledgmentDigest
    }
}

extension StoredPeriodCheckpointAcknowledgment {
    /// Row form of one acknowledgment snapshot at its position in the revision.
    convenience init(
        _ record: AcknowledgedExceptionRecord,
        revisionIdentifier: String,
        sequence: Int
    ) throws {
        let exception = record.exception
        self.init(
            revisionIdentifier: revisionIdentifier,
            exceptionIdentifier: exception.id,
            kindRaw: exception.kind.rawValue,
            aggregateBasisRaw: exception.aggregateBasis?.rawValue,
            day: try PersistenceCoding.ordinal(exception.day),
            amountMinor: exception.amount?.minorUnits,
            amountCurrencyCode: exception.amount?.currency.code,
            amountCurrencyExponent: exception.amount?.currency.minorUnitDigits,
            sequence: sequence
        )
    }

    func hasIdenticalContent(to other: StoredPeriodCheckpointAcknowledgment) -> Bool {
        revisionIdentifier == other.revisionIdentifier
            && exceptionIdentifier == other.exceptionIdentifier
            && kindRaw == other.kindRaw
            && aggregateBasisRaw == other.aggregateBasisRaw
            && day == other.day
            && amountMinor == other.amountMinor
            && amountCurrencyCode == other.amountCurrencyCode
            && amountCurrencyExponent == other.amountCurrencyExponent
            && sequence == other.sequence
    }
}
