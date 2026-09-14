import Foundation
import SwiftData
import FinanceCore

// MARK: - What a stored read can say

/// Safe metadata about a stored revision this build cannot interpret.
///
/// Everything here is structural: identity, period, kind, sequence number and
/// the recorded quality. The canonical payload is deliberately absent. A
/// projection format this build does not implement cannot be parsed into this
/// build's types — that is what "unsupported" means — and guessing at it would
/// be the same mistake as decoding an unknown enum token into a plausible
/// neighbour.
///
/// This is exactly the shape a later baseline-comparison caller needs to build
/// `PeriodCheckpointBaseline(period:periodKind:previousQuality:unreadableFormatToken:)`.
struct PeriodCheckpointStoredHeader: Equatable, Sendable {
    let revisionID: UUID
    let period: SemanticInterval
    let periodKind: ReviewPeriodKind
    let revisionNumber: Int64
    let predecessorID: UUID?

    /// The quality this revision recorded. An audit fact carried forward, never
    /// recomputed.
    let previousQuality: PeriodCheckpointQuality

    /// The stored format token, verbatim and un-normalized.
    let formatToken: String
}

/// One revision as it reads back.
enum PeriodCheckpointStoredRevisionRead: Sendable {
    /// This build understands the stored format and the revision rehydrated.
    case supported(PeriodCheckpointRevision)

    /// The revision exists and its header is readable, but its projection
    /// format is not one this build compares in. **Not corruption**: a later
    /// build wrote it, and the period simply has to be verified again under the
    /// current format.
    case unsupportedFormat(PeriodCheckpointStoredHeader)
}

/// The latest revision for one exact period, or why there is not one.
///
/// Four distinct states, kept apart deliberately. Collapsing them into
/// `PeriodCheckpointRevision?` would lose the two that matter most: a store
/// that was read and holds nothing is not a store that could not be read, and
/// a payload in a future format is not a corrupt payload.
enum PeriodCheckpointStoredRead: Sendable {
    /// Read successfully; this period has no stored revision.
    case empty

    case supported(PeriodCheckpointRevision)

    case unsupportedFormat(PeriodCheckpointStoredHeader)

    /// The stored rows claim a format this build supports, and then fail to be
    /// what they claim — bad bytes, a digest that does not match, a history
    /// whose chain does not hold, or a snapshot the domain refuses. Never a
    /// future format.
    case corrupt(PeriodCheckpointStoreCorruption)
}

/// Every stored revision for one exact period, oldest first.
enum PeriodCheckpointStoredHistoryRead: Sendable {
    case empty

    /// Ordered by `revisionNumber`, ascending, over a chain that validated.
    case history([PeriodCheckpointStoredRevisionRead])

    case corrupt(PeriodCheckpointStoreCorruption)
}

/// Whether the checkpoint subgraph holds anything, for emptiness and import
/// safety. Never a financial statement.
enum PeriodCheckpointStoreOccupancy: Equatable, Sendable {
    case empty
    case holdsCheckpointHistory

    /// The subgraph could not be read as a coherent whole. Fails closed: this
    /// is never treated as emptiness.
    case unreadable(PeriodCheckpointStoreCorruption)
}

/// What a store call did.
enum PeriodCheckpointWriteOutcome: Equatable, Sendable {
    case stored

    /// The identical revision — same id, byte-identical content, identical
    /// acknowledgment snapshots — was already stored. Nothing was written.
    /// Append-only history has no room for a second copy, and an idempotent
    /// retry is the one duplicate that carries no information loss.
    case alreadyStored
}

// MARK: - Failures

/// A structural fact about the stored rows that makes them unreadable.
///
/// Every case is a refusal, never a repair. Payload-free on purpose: these
/// values are compared in tests and may be logged, and a checkpoint row is
/// derived from a person's finances.
enum PeriodCheckpointStoreCorruption: Error, Equatable, Sendable, CustomStringConvertible {

    // Dataset identity
    case datasetMetadataMissing
    case multipleDatasetRows
    case malformedDatasetIdentifier
    case datasetWithoutRevisions
    case revisionDatasetMismatch

    // Revision header
    case malformedRevisionIdentifier
    case duplicateRevisionIdentifier
    case invalidRevisionNumber
    case malformedPeriod
    case unknownPeriodKindToken
    case unknownQualityToken
    case malformedPredecessorIdentifier
    case predecessorIsSelf

    // Chain
    case missingPredecessor
    case unexpectedPredecessor
    case predecessorNotFound
    case predecessorPeriodMismatch
    case predecessorKindMismatch
    case predecessorRevisionNumberMismatch
    case duplicateRevisionNumber

    // Acknowledgments
    case orphanAcknowledgment
    case duplicateAcknowledgment
    case invalidAcknowledgmentCount
    case acknowledgmentCountMismatch
    case malformedAcknowledgmentSequence
    case malformedAcknowledgmentDigest
    case acknowledgmentDigestMismatch
    case unknownExceptionKindToken
    case unknownAggregateBasisToken
    case malformedAcknowledgmentAggregateBasis
    case malformedAcknowledgmentDay
    case malformedAcknowledgmentAmount

    // Supported-format payload
    case malformedDigest
    case malformedCanonicalPayload
    case digestMismatch

    /// A later revision this build can read follows a predecessor whose
    /// projection format it cannot. The future payload is not treated as
    /// corrupt bytes; the chain simply cannot be used as a supported baseline.
    case incompatibleFormatChain

    /// The rows validated structurally, and the domain refused the snapshot
    /// they describe. Closed-revision invariants belong to
    /// `PeriodCheckpointRevision.init(rehydratingStoredSnapshot:)`, and this
    /// layer does not restate them: it reports that they did not hold.
    case domainRejectedStoredRevision

    /// The subgraph could not be queried at all.
    case storeUnreadable

    var description: String {
        switch self {
        case .datasetMetadataMissing: "checkpoint revisions exist without dataset metadata"
        case .multipleDatasetRows: "more than one checkpoint dataset identity"
        case .malformedDatasetIdentifier: "the checkpoint dataset identifier is not a valid identity"
        case .datasetWithoutRevisions: "checkpoint dataset metadata exists without any revision"
        case .revisionDatasetMismatch: "a checkpoint revision names a different dataset"
        case .malformedRevisionIdentifier: "a checkpoint revision identifier is not a valid identity"
        case .duplicateRevisionIdentifier: "two checkpoint revisions share one identifier"
        case .invalidRevisionNumber: "a checkpoint revision number is below 1"
        case .malformedPeriod: "a stored checkpoint period is not a calendar interval"
        case .unknownPeriodKindToken: "a stored checkpoint period kind is not a value this build understands"
        case .unknownQualityToken: "a stored checkpoint quality is not a value this build understands"
        case .malformedPredecessorIdentifier: "a stored predecessor identifier is not a valid identity"
        case .predecessorIsSelf: "a checkpoint revision names itself as its predecessor"
        case .missingPredecessor: "a later checkpoint revision names no predecessor"
        case .unexpectedPredecessor: "the first checkpoint revision names a predecessor"
        case .predecessorNotFound: "a checkpoint revision's predecessor row is not stored"
        case .predecessorPeriodMismatch: "a checkpoint predecessor belongs to another period"
        case .predecessorKindMismatch: "a checkpoint predecessor belongs to another period kind"
        case .predecessorRevisionNumberMismatch: "a checkpoint predecessor is not the preceding revision"
        case .duplicateRevisionNumber: "one period holds two checkpoint revisions with one number"
        case .orphanAcknowledgment: "an acknowledgment names a revision that is not stored"
        case .duplicateAcknowledgment: "one revision holds two acknowledgments of one exception"
        case .invalidAcknowledgmentCount: "a stored acknowledgment count is below 0"
        case .acknowledgmentCountMismatch: "acknowledgment rows do not match the stored count"
        case .malformedAcknowledgmentSequence: "acknowledgment sequences are not dense 0..<count"
        case .malformedAcknowledgmentDigest: "a stored acknowledgment digest is not 32 bytes"
        case .acknowledgmentDigestMismatch: "acknowledgment rows do not hash to their recorded digest"
        case .unknownExceptionKindToken: "a stored exception kind is not a value this build understands"
        case .unknownAggregateBasisToken: "a stored aggregate basis is not a value this build understands"
        case .malformedAcknowledgmentAggregateBasis: "an aggregate basis does not match its exception kind"
        case .malformedAcknowledgmentDay: "a stored acknowledgment day is not a calendar day"
        case .malformedAcknowledgmentAmount: "a stored acknowledgment amount is not a money value"
        case .malformedDigest: "a stored projection digest is not 32 bytes"
        case .malformedCanonicalPayload: "a stored canonical projection could not be read"
        case .digestMismatch: "a stored projection does not hash to its recorded digest"
        case .incompatibleFormatChain: "a supported checkpoint revision follows a predecessor this build cannot interpret"
        case .domainRejectedStoredRevision: "a stored revision is not a valid closed checkpoint"
        case .storeUnreadable: "the checkpoint subgraph could not be read"
        }
    }
}

/// Why an append was refused. History is append-only, so every one of these is
/// a refusal to write rather than a correction.
enum PeriodCheckpointWriteRejection: Error, Equatable, Sendable, CustomStringConvertible {
    /// A revision with this id is stored and its content differs. Storage never
    /// rewrites an accepted revision.
    case revisionAlreadyStoredWithDifferentContent

    /// This period already holds a revision with this number under a different
    /// id — a branch, not an append.
    case duplicateRevisionNumber

    case predecessorNotFound
    case predecessorPeriodMismatch
    case predecessorKindMismatch
    case predecessorRevisionNumberMismatch

    /// The named predecessor belongs to another checkpoint dataset.
    ///
    /// Unreachable while `validatedStore` holds, because it refuses the whole
    /// subgraph the moment any revision row names a dataset other than the
    /// single stored identity — so a foreign predecessor row cannot survive
    /// long enough to be chosen. Kept because "the predecessor belongs to this
    /// dataset" is an invariant of the append itself, and a guard that states
    /// it is worth more than a comment that assumes someone else still does.
    case predecessorDatasetMismatch

    /// The stored history for this period is readable as headers but is not
    /// in a format this build can extend — typically an unsupported latest.
    case existingHistoryNotSupported

    /// A period bound or acknowledgment day cannot be stored as an Int32 ordinal.
    case unrepresentableDate

    var description: String {
        switch self {
        case .revisionAlreadyStoredWithDifferentContent:
            "a different checkpoint revision is already stored under this identity"
        case .duplicateRevisionNumber:
            "this period already holds a checkpoint revision with this number"
        case .predecessorNotFound: "the named predecessor revision is not stored"
        case .predecessorPeriodMismatch: "the named predecessor belongs to another period"
        case .predecessorKindMismatch: "the named predecessor belongs to another period kind"
        case .predecessorRevisionNumberMismatch: "the named predecessor is not the preceding revision"
        case .predecessorDatasetMismatch: "the named predecessor belongs to another dataset"
        case .existingHistoryNotSupported:
            "the stored checkpoint history for this period is not in a format this build can extend"
        case .unrepresentableDate:
            "a checkpoint date cannot be stored"
        }
    }
}

/// Everything a checkpoint write can fail with.
enum PeriodCheckpointStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case corrupt(PeriodCheckpointStoreCorruption)
    case rejected(PeriodCheckpointWriteRejection)

    /// There is no store to write to — a preview or fixed store.
    case storeUnavailable

    /// The context refused to save. Reported by type, never by row content.
    case persistenceFailed(String)

    var description: String {
        switch self {
        case let .corrupt(corruption): corruption.description
        case let .rejected(rejection): rejection.description
        case .storeUnavailable: "There is no checkpoint store to write to."
        case let .persistenceFailed(reason): "The checkpoint revision could not be saved (\(reason))."
        }
    }
}

// MARK: - Repository

/// Durable local storage for accepted period checkpoint revisions.
///
/// ## Actor and context ownership
///
/// `@MainActor`, like `HistoryArchiveService`, and for the same reason: it owns
/// a **dedicated** `ModelContext` taken from the container the operational
/// store already opened. A failed append rolls that context back, and a
/// rollback discards every unsaved change in its context — so sharing the
/// operational context would let a refused checkpoint write throw away an
/// in-flight document edit. There is no background context and no second
/// container: one store on disk, two contexts with disjoint responsibilities.
///
/// ## What this type does and does not decide
///
/// It stores an **already-created** `PeriodCheckpointRevision` and it reads
/// stored rows back. It never constructs a new revision, never calls
/// `PeriodCheckpointEvaluator` or `ReviewEngine`, never computes a revision
/// number or chooses a predecessor, and never compares a baseline. Those are
/// the caller's, and most of them do not exist yet.
///
/// The read path is the *only* user of
/// `PeriodCheckpointRevision.init(rehydratingStoredSnapshot:)`. That
/// initializer re-opens history; it is not a create path, and the writer must
/// never reach it.
///
/// ## The validation split
///
/// The repository proves facts about **rows and their relationships**: dataset
/// identity, id uniqueness, that a predecessor row exists and is the preceding
/// revision of the same period, kind and dataset, that acknowledgment rows
/// belong to a revision that is stored. `PeriodCheckpointRevision`'s
/// rehydration initializer proves facts about **one closed revision's own
/// consistency**: period against payload, quality against exceptions, safe
/// claims against impacts, complete coverage. Neither restates the other.
///
/// ## Scope of a read
///
/// Store-level integrity — dataset rows, revision headers, acknowledgment
/// ownership — is checked across the whole subgraph, because those facts poison
/// its meaning wholesale. Chain, payload and acknowledgment-array integrity are
/// checked per exact period: a broken March chain says nothing about September
/// and must not make September unreadable. Occupancy, which answers a store-wide
/// import-safety question, walks every period. The subgraph holds at most a
/// handful of rows per closed period, so reading it whole is cheap.
///
/// ## What is stored elsewhere, and stays there
///
/// Nothing here enters `FinanceDocument`, the interchange schema or
/// `StoredDocumentGraph.purge`. `ReviewResult`, `ReviewTotals`, findings,
/// blockers, dispositions, sync timestamps, transport metadata, merchant text,
/// remittance strings and formatted money are all absent by construction.
@MainActor
final class PeriodCheckpointRepository {

    /// nil for a preview or fixed store: reads are empty and writes refuse.
    private let context: ModelContext?

    /// Mints the local dataset identity on the first append. Injectable so a
    /// test can pin it; production mints a fresh UUID.
    private let makeDatasetIdentity: () -> UUID

    /// Recorded on the dataset row. Audit metadata only.
    private let now: () -> Date

    init(
        context: ModelContext?,
        makeDatasetIdentity: @escaping () -> UUID = UUID.init,
        now: @escaping () -> Date = Date.init
    ) {
        // A dedicated context on the shared container. See the type comment:
        // rollback must not be able to discard the operational context's work.
        self.context = context.map { ModelContext($0.container) }
        self.makeDatasetIdentity = makeDatasetIdentity
        self.now = now
    }

    // MARK: - Storage primitives
    //
    // Three of them, and no more. There is no `closePeriod`, no `reverify`, no
    // `compareAndAppend` and no `acknowledgeAndClose`: this phase adds durable
    // storage, not a product action.

    /// Persists one already-created, already-validated revision.
    ///
    /// The revision arrives from the readiness/evaluator-backed initializer —
    /// the only authority for a *new* accepted checkpoint. This method stores
    /// it losslessly and decides nothing about it. It does not renumber it,
    /// does not pick its predecessor, and does not re-derive its exceptions.
    ///
    /// The first append also mints and writes the local dataset identity, in
    /// the same transaction as the revision and its acknowledgments: a saved
    /// dataset row with no revision, or a revision with only some of its
    /// acknowledgments, is a state this store never reaches.
    ///
    /// - Parameter beforeSave: runs inside the transaction, after the rows are
    ///   inserted and before `save()`. Production leaves it empty; a test uses
    ///   it to prove the rollback.
    @discardableResult
    func store(
        _ revision: PeriodCheckpointRevision,
        beforeSave: () throws -> Void = {}
    ) throws -> PeriodCheckpointWriteOutcome {
        guard let context else { throw PeriodCheckpointStoreError.storeUnavailable }

        let stored: ValidatedStore
        do {
            stored = try validatedStore(in: context)
        } catch let corruption as PeriodCheckpointStoreCorruption {
            throw PeriodCheckpointStoreError.corrupt(corruption)
        }

        let datasetIdentity = stored.datasetIdentifier
        let isFirstAppend = datasetIdentity == nil
        let datasetIdentifier = (datasetIdentity ?? makeDatasetIdentity()).uuidString

        let candidate: StoredPeriodCheckpointRevision
        let candidateAcknowledgments: [StoredPeriodCheckpointAcknowledgment]
        do {
            candidate = try StoredPeriodCheckpointRevision(revision, datasetIdentifier: datasetIdentifier)
            candidateAcknowledgments = try revision.acknowledgedExceptions.enumerated().map {
                try StoredPeriodCheckpointAcknowledgment(
                    $0.element, revisionIdentifier: candidate.identifier, sequence: $0.offset
                )
            }
        } catch {
            throw PeriodCheckpointStoreError.rejected(.unrepresentableDate)
        }

        if let existing = stored.revisions.first(where: { $0.id == revision.id }) {
            // Same identity. Byte-identical is an idempotent retry and writes
            // nothing; anything else would be a rewrite of accepted history.
            let existingAcknowledgments = stored.acknowledgments[existing.id] ?? []
            let identical = candidate.hasIdenticalContent(to: existing.row)
                && existingAcknowledgments.count == candidateAcknowledgments.count
                && zip(existingAcknowledgments, candidateAcknowledgments)
                    .allSatisfy { $0.hasIdenticalContent(to: $1) }
            guard identical else {
                throw PeriodCheckpointStoreError.rejected(.revisionAlreadyStoredWithDifferentContent)
            }
            return .alreadyStored
        }

        do {
            try validateAppend(of: revision, datasetIdentifier: datasetIdentifier, into: stored)
        } catch let corruption as PeriodCheckpointStoreCorruption {
            throw PeriodCheckpointStoreError.corrupt(corruption)
        }

        do {
            if isFirstAppend {
                context.insert(
                    StoredPeriodCheckpointDataset(identifier: datasetIdentifier, establishedAt: now())
                )
            }
            context.insert(candidate)
            candidateAcknowledgments.forEach(context.insert)
            try beforeSave()
            try context.save()
            return .stored
        } catch {
            // One transaction or none of it. Whatever was inserted above is an
            // unsaved change until `save()` returns, so discarding the context
            // restores exactly the subgraph that was on disk.
            context.rollback()
            throw PeriodCheckpointStoreError.persistenceFailed(String(describing: type(of: error)))
        }
    }

    /// Every stored revision for one exact period, oldest first.
    ///
    /// The history key is start day + end day + kind. Not a month string, not a
    /// start day alone, not a calendar label: two intervals that begin on the
    /// same day are different periods, and a weekly close does not speak for a
    /// monthly one.
    func revisions(
        inPeriod period: SemanticInterval,
        kind: ReviewPeriodKind
    ) -> PeriodCheckpointStoredHistoryRead {
        guard let context else { return .empty }
        do {
            let stored = try validatedStore(in: context)
            let history = try historyReads(for: period, kind: kind, in: stored)
            guard !history.isEmpty else { return .empty }
            return .history(history)
        } catch let corruption as PeriodCheckpointStoreCorruption {
            return .corrupt(corruption)
        } catch {
            return .corrupt(.storeUnreadable)
        }
    }

    /// The latest revision for one exact period.
    ///
    /// Latest means the highest revision number in a chain that validated —
    /// never the most recent `closedAt`. A clock is audit metadata: two rows
    /// closed a second apart in the wrong order would otherwise silently
    /// reorder history, and a duplicate highest number is corruption rather
    /// than a tie to break. Every predecessor in the same period is read to
    /// the same depth: a supported V1 latest cannot hide a corrupt supported
    /// predecessor, and `revisions` / `latestRevision` cannot disagree about
    /// that period's integrity.
    func latestRevision(
        inPeriod period: SemanticInterval,
        kind: ReviewPeriodKind
    ) -> PeriodCheckpointStoredRead {
        guard let context else { return .empty }
        do {
            let stored = try validatedStore(in: context)
            let history = try historyReads(for: period, kind: kind, in: stored)
            guard let latest = history.last else { return .empty }
            switch latest {
            case let .supported(revision): return .supported(revision)
            case let .unsupportedFormat(header): return .unsupportedFormat(header)
            }
        } catch let corruption as PeriodCheckpointStoreCorruption {
            return .corrupt(corruption)
        } catch {
            return .corrupt(.storeUnreadable)
        }
    }

    /// Whether the subgraph holds checkpoint history, for emptiness and import
    /// safety. Fails closed: anything it cannot read as a coherent whole is
    /// `.unreadable`, never `.empty`. Occupancy walks every period's chain;
    /// a corrupt March makes the *store* unreadable for import without making
    /// `latestRevision(September)` fail.
    func occupancy() -> PeriodCheckpointStoreOccupancy {
        guard let context else { return .empty }
        do {
            let stored = try validatedStore(in: context)
            guard stored.datasetIdentifier != nil else { return .empty }
            try validateEveryHistory(in: stored)
            return .holdsCheckpointHistory
        } catch let corruption as PeriodCheckpointStoreCorruption {
            return .unreadable(corruption)
        } catch {
            return .unreadable(.storeUnreadable)
        }
    }

    // MARK: - Append validation

    /// The repository-level invariant the rehydration initializer cannot prove.
    ///
    /// A revision knows it names a predecessor; only the store knows whether
    /// that row exists, whether it is the preceding revision, and whether it
    /// belongs to the same period, kind and dataset. Nothing here is inferred:
    /// a missing or mismatched predecessor is refused, never repaired by
    /// picking the nearest candidate.
    private func validateAppend(
        of revision: PeriodCheckpointRevision,
        datasetIdentifier: String,
        into stored: ValidatedStore
    ) throws {
        let siblings = stored.revisions.filter {
            $0.period == revision.period && $0.periodKind == revision.periodKind
        }

        guard !siblings.contains(where: { $0.row.revisionNumber == revision.revisionNumber }) else {
            throw PeriodCheckpointStoreError.rejected(.duplicateRevisionNumber)
        }

        // The existing target-period history must itself be extendable. A
        // broken chain or a corrupt supported predecessor is store corruption,
        // not a new predecessor-not-found on the incoming row. An unsupported
        // latest is a refusal: this build only writes current-format revisions.
        let existing = try historyReads(
            for: revision.period, kind: revision.periodKind, in: stored
        )
        if !existing.isEmpty {
            guard existing.allSatisfy({
                if case .supported = $0 { return true }
                return false
            }) else {
                throw PeriodCheckpointStoreError.rejected(.existingHistoryNotSupported)
            }
        }

        guard let predecessorID = revision.predecessorID else { return }

        guard let predecessor = stored.revisions.first(where: { $0.id == predecessorID }) else {
            throw PeriodCheckpointStoreError.rejected(.predecessorNotFound)
        }
        guard predecessor.row.datasetIdentifier == datasetIdentifier else {
            throw PeriodCheckpointStoreError.rejected(.predecessorDatasetMismatch)
        }
        guard predecessor.period == revision.period else {
            throw PeriodCheckpointStoreError.rejected(.predecessorPeriodMismatch)
        }
        guard predecessor.periodKind == revision.periodKind else {
            throw PeriodCheckpointStoreError.rejected(.predecessorKindMismatch)
        }
        guard predecessor.row.revisionNumber == revision.revisionNumber - 1 else {
            throw PeriodCheckpointStoreError.rejected(.predecessorRevisionNumberMismatch)
        }
    }

    // MARK: - Reading one row

    /// Turns one validated row into a revision, or names why it cannot be one.
    ///
    /// The format token decides the path, and it decides it by exact match: the
    /// token this build compares in enters V1 validation, and every other token
    /// — including one a later build will write — becomes a header. An unknown
    /// token is never normalized, never guessed at, and never treated as
    /// corruption.
    private func read(
        _ row: ValidatedRevisionRow,
        in stored: ValidatedStore
    ) throws -> PeriodCheckpointStoredRevisionRead {
        let header = PeriodCheckpointStoredHeader(
            revisionID: row.id,
            period: row.period,
            periodKind: row.periodKind,
            revisionNumber: row.row.revisionNumber,
            predecessorID: row.predecessorID,
            previousQuality: row.quality,
            formatToken: row.row.projectionFormatToken
        )

        // Count and dense sequence first. Digest comparison uses raw fields on
        // an unsupported format (this build must not force future kind tokens
        // through today's vocabulary) and decoded records on a supported one.
        let acknowledgmentRows = try committedAcknowledgmentRows(for: row, in: stored)

        guard (try? SemanticPeriodProjectionFormat(token: row.row.projectionFormatToken)) != nil else {
            guard CheckpointAcknowledgmentCommitment.digest(of: acknowledgmentRows)
                    == row.row.acknowledgmentDigest else {
                throw PeriodCheckpointStoreCorruption.acknowledgmentDigestMismatch
            }
            return .unsupportedFormat(header)
        }

        guard row.row.projectionDigest.count == 32 else {
            throw PeriodCheckpointStoreCorruption.malformedDigest
        }
        let canonical: CanonicalSemanticPeriodProjection
        do {
            canonical = try CanonicalSemanticPeriodProjection(
                bytes: Array(row.row.canonicalProjection)
            )
        } catch {
            throw PeriodCheckpointStoreCorruption.malformedCanonicalPayload
        }
        // The digest is re-derived from the bytes that were actually stored, so
        // a payload edited after acceptance cannot pass as the one that was
        // accepted.
        guard Array(row.row.projectionDigest) == canonical.digest.bytes else {
            throw PeriodCheckpointStoreCorruption.digestMismatch
        }

        let acknowledgments = try acknowledgmentRows.map(exception)
        guard try CheckpointAcknowledgmentCommitment.digest(of: acknowledgments)
                == row.row.acknowledgmentDigest else {
            throw PeriodCheckpointStoreCorruption.acknowledgmentDigestMismatch
        }

        do {
            return .supported(
                try PeriodCheckpointRevision(
                    rehydratingStoredSnapshot: row.id,
                    period: row.period,
                    periodKind: row.periodKind,
                    revisionNumber: row.row.revisionNumber,
                    predecessorID: row.predecessorID,
                    closedAt: row.row.closedAt,
                    canonicalProjection: canonical,
                    acknowledgedExceptions: acknowledgments,
                    quality: row.quality,
                    safeClaims: PeriodCheckpointSafeClaims(
                        mayShowCalculatedTotals: row.row.safeClaimMayShowCalculatedTotals,
                        unquestionablyCompleteTotals: row.row.safeClaimUnquestionablyCompleteTotals,
                        completeCategoryAttribution: row.row.safeClaimCompleteCategoryAttribution,
                        completeEvidenceAudit: row.row.safeClaimCompleteEvidenceAudit
                    )
                )
            )
        } catch {
            throw PeriodCheckpointStoreCorruption.domainRejectedStoredRevision
        }
    }

    /// One acknowledgment row as the snapshot it recorded.
    ///
    /// Every token is mapped explicitly and every malformed pairing is refused
    /// *before* a domain value is constructed. `PeriodCheckpointException`
    /// asserts that an aggregate basis accompanies exactly the aggregate kind,
    /// and `Currency` asserts its code and digit count: reaching either
    /// assertion from a corrupt row would end the process instead of failing
    /// the read.
    private func exception(
        _ row: StoredPeriodCheckpointAcknowledgment
    ) throws -> AcknowledgedExceptionRecord {
        guard let kind = PeriodCheckpointExceptionKind(rawValue: row.kindRaw) else {
            throw PeriodCheckpointStoreCorruption.unknownExceptionKindToken
        }

        var basis: AggregateEvidenceBasis?
        if let raw = row.aggregateBasisRaw {
            guard let decoded = AggregateEvidenceBasis(rawValue: raw) else {
                throw PeriodCheckpointStoreCorruption.unknownAggregateBasisToken
            }
            basis = decoded
        }
        guard (kind == .aggregateEvidenceModelLimitation) == (basis != nil) else {
            throw PeriodCheckpointStoreCorruption.malformedAcknowledgmentAggregateBasis
        }

        var day: Day?
        if let ordinal = row.day {
            guard let decoded = Self.day(ordinal) else {
                throw PeriodCheckpointStoreCorruption.malformedAcknowledgmentDay
            }
            day = decoded
        }

        var amount: Money?
        switch (row.amountMinor, row.amountCurrencyCode, row.amountCurrencyExponent) {
        case (nil, nil, nil):
            amount = nil
        case let (minor?, code?, exponent?):
            guard Self.isValidCurrencyCode(code), (0...6).contains(exponent) else {
                throw PeriodCheckpointStoreCorruption.malformedAcknowledgmentAmount
            }
            amount = Money(minorUnits: minor, currency: Currency(code: code, minorUnitDigits: exponent))
        default:
            // A half-stored amount is not a zero and not an absent amount.
            throw PeriodCheckpointStoreCorruption.malformedAcknowledgmentAmount
        }

        return AcknowledgedExceptionRecord(
            exception: PeriodCheckpointException(
                id: row.exceptionIdentifier,
                kind: kind,
                aggregateBasis: basis,
                day: day,
                amount: amount
            )
        )
    }

    /// `Currency.init(code:minorUnitDigits:)` traps on anything else.
    private static func isValidCurrencyCode(_ code: String) -> Bool {
        code.count == 3 && code.allSatisfy { $0.isASCII && $0.isUppercase && $0.isLetter }
    }

    /// A stored day ordinal, or nil — without trapping on the way.
    ///
    /// Every part is range-checked before a `Day` exists, and the ordinal must
    /// round-trip. This checkpoint-specific guard predates Day-F1, which also
    /// fixed validation order in the document-side decoder. Keep this local
    /// checkpoint validation independent; malformed data must never reach a
    /// trusted component initializer before validation.
    private static func day(_ ordinal: Int32) -> Day? {
        let value = Int(ordinal)
        guard value > 0 else { return nil }
        let year = value / 10_000
        let month = (value / 100) % 100
        let dayOfMonth = value % 100
        guard (1...12).contains(month),
              (1...Day.daysInMonth(year: year, month: month)).contains(dayOfMonth) else {
            return nil
        }
        let day = Day(year: year, month: month, day: dayOfMonth)
        guard day.checkedPersistenceOrdinal == ordinal else { return nil }
        return day
    }

    // MARK: - Store-wide validation

    private struct ValidatedRevisionRow {
        let row: StoredPeriodCheckpointRevision
        let id: UUID
        let period: SemanticInterval
        let periodKind: ReviewPeriodKind
        let quality: PeriodCheckpointQuality
        let predecessorID: UUID?
    }

    private struct ValidatedStore {
        /// nil exactly when the subgraph holds nothing at all.
        let datasetIdentifier: UUID?
        let revisions: [ValidatedRevisionRow]
        /// Acknowledgment rows by revision id, in stored sequence order.
        let acknowledgments: [UUID: [StoredPeriodCheckpointAcknowledgment]]
    }

    /// Reads the whole subgraph and proves it is structurally coherent.
    ///
    /// Fails closed at the first structural fact that does not hold. None of
    /// these checks interprets a payload or a financial value; they establish
    /// only that the rows are the shape a history has to be before any of them
    /// can be believed.
    private func validatedStore(in context: ModelContext) throws -> ValidatedStore {
        let datasetRows = try context.fetch(FetchDescriptor<StoredPeriodCheckpointDataset>())
        let revisionRows = try context.fetch(FetchDescriptor<StoredPeriodCheckpointRevision>())
        let acknowledgmentRows = try context.fetch(
            FetchDescriptor<StoredPeriodCheckpointAcknowledgment>()
        )

        if datasetRows.isEmpty, revisionRows.isEmpty, acknowledgmentRows.isEmpty {
            return ValidatedStore(datasetIdentifier: nil, revisions: [], acknowledgments: [:])
        }

        guard !datasetRows.isEmpty else { throw PeriodCheckpointStoreCorruption.datasetMetadataMissing }
        guard datasetRows.count == 1 else { throw PeriodCheckpointStoreCorruption.multipleDatasetRows }
        guard let datasetIdentifier = UUID(uuidString: datasetRows[0].identifier) else {
            throw PeriodCheckpointStoreCorruption.malformedDatasetIdentifier
        }
        // The first append writes the dataset row and its revision together, so
        // a dataset standing on its own is a torn write, not a fresh store.
        guard !revisionRows.isEmpty else { throw PeriodCheckpointStoreCorruption.datasetWithoutRevisions }

        var revisions: [ValidatedRevisionRow] = []
        var seenIdentifiers: Set<UUID> = []
        for row in revisionRows {
            guard let id = UUID(uuidString: row.identifier) else {
                throw PeriodCheckpointStoreCorruption.malformedRevisionIdentifier
            }
            guard seenIdentifiers.insert(id).inserted else {
                throw PeriodCheckpointStoreCorruption.duplicateRevisionIdentifier
            }
            guard row.datasetIdentifier == datasetIdentifier.uuidString else {
                throw PeriodCheckpointStoreCorruption.revisionDatasetMismatch
            }
            guard row.revisionNumber >= 1 else {
                throw PeriodCheckpointStoreCorruption.invalidRevisionNumber
            }
            guard let start = Self.day(row.periodStartDay),
                  let end = Self.day(row.periodEndDay) else {
                throw PeriodCheckpointStoreCorruption.malformedPeriod
            }
            guard let periodKind = ReviewPeriodKind(rawValue: row.periodKindRaw) else {
                throw PeriodCheckpointStoreCorruption.unknownPeriodKindToken
            }
            guard let quality = PeriodCheckpointQuality(rawValue: row.qualityRaw) else {
                throw PeriodCheckpointStoreCorruption.unknownQualityToken
            }
            var predecessorID: UUID?
            if let raw = row.predecessorIdentifier {
                guard let decoded = UUID(uuidString: raw) else {
                    throw PeriodCheckpointStoreCorruption.malformedPredecessorIdentifier
                }
                guard decoded != id else { throw PeriodCheckpointStoreCorruption.predecessorIsSelf }
                predecessorID = decoded
            }
            guard (row.revisionNumber == 1) == (predecessorID == nil) else {
                throw row.revisionNumber == 1
                    ? PeriodCheckpointStoreCorruption.unexpectedPredecessor
                    : PeriodCheckpointStoreCorruption.missingPredecessor
            }

            revisions.append(
                ValidatedRevisionRow(
                    row: row,
                    id: id,
                    period: SemanticInterval(start: start, end: end),
                    periodKind: periodKind,
                    quality: quality,
                    predecessorID: predecessorID
                )
            )
        }

        var acknowledgments: [UUID: [StoredPeriodCheckpointAcknowledgment]] = [:]
        for row in acknowledgmentRows {
            guard let owner = UUID(uuidString: row.revisionIdentifier),
                  seenIdentifiers.contains(owner) else {
                throw PeriodCheckpointStoreCorruption.orphanAcknowledgment
            }
            acknowledgments[owner, default: []].append(row)
        }
        for (owner, rows) in acknowledgments {
            let ordered = rows.sorted { $0.sequence < $1.sequence }
            guard Set(ordered.map(\.exceptionIdentifier)).count == ordered.count else {
                throw PeriodCheckpointStoreCorruption.duplicateAcknowledgment
            }
            acknowledgments[owner] = ordered
        }

        return ValidatedStore(
            datasetIdentifier: datasetIdentifier,
            revisions: revisions,
            acknowledgments: acknowledgments
        )
    }

    /// The validated revision chain for one exact period, oldest first.
    ///
    /// A chain is a line, not a tree. Two revisions numbered N under one period
    /// are a branch however different their ids are, and choosing between them
    /// by `closedAt` would pick a winner nobody recorded.
    private func chain(
        for period: SemanticInterval,
        kind: ReviewPeriodKind,
        in stored: ValidatedStore
    ) throws -> [ValidatedRevisionRow] {
        let members = stored.revisions
            .filter { $0.period == period && $0.periodKind == kind }
            .sorted { $0.row.revisionNumber < $1.row.revisionNumber }
        guard !members.isEmpty else { return [] }

        guard Set(members.map(\.row.revisionNumber)).count == members.count else {
            throw PeriodCheckpointStoreCorruption.duplicateRevisionNumber
        }

        let byID = Dictionary(uniqueKeysWithValues: stored.revisions.map { ($0.id, $0) })
        for member in members {
            guard let predecessorID = member.predecessorID else { continue }
            guard let predecessor = byID[predecessorID] else {
                throw PeriodCheckpointStoreCorruption.predecessorNotFound
            }
            guard predecessor.period == member.period else {
                throw PeriodCheckpointStoreCorruption.predecessorPeriodMismatch
            }
            guard predecessor.periodKind == member.periodKind else {
                throw PeriodCheckpointStoreCorruption.predecessorKindMismatch
            }
            guard predecessor.row.revisionNumber == member.row.revisionNumber - 1 else {
                throw PeriodCheckpointStoreCorruption.predecessorRevisionNumberMismatch
            }
        }
        return members
    }

    private struct PeriodKey: Hashable {
        let period: SemanticInterval
        let kind: ReviewPeriodKind
    }

    /// Every revision of one exact period, oldest first, each read to the same
    /// depth. A supported revision after an unsupported predecessor is not a
    /// supported latest: this build cannot validate the predecessor semantics.
    private func historyReads(
        for period: SemanticInterval,
        kind: ReviewPeriodKind,
        in stored: ValidatedStore
    ) throws -> [PeriodCheckpointStoredRevisionRead] {
        let members = try chain(for: period, kind: kind, in: stored)
        var reads: [PeriodCheckpointStoredRevisionRead] = []
        var seenUnsupported = false
        for member in members {
            let read = try self.read(member, in: stored)
            switch read {
            case .unsupportedFormat:
                seenUnsupported = true
                reads.append(read)
            case .supported:
                if seenUnsupported {
                    throw PeriodCheckpointStoreCorruption.incompatibleFormatChain
                }
                reads.append(read)
            }
        }
        return reads
    }

    private func validateEveryHistory(in stored: ValidatedStore) throws {
        var keys: [PeriodKey] = []
        var seen: Set<PeriodKey> = []
        for revision in stored.revisions {
            let key = PeriodKey(period: revision.period, kind: revision.periodKind)
            if seen.insert(key).inserted {
                keys.append(key)
            }
        }
        keys.sort {
            if $0.period.start != $1.period.start { return $0.period.start < $1.period.start }
            if $0.period.end != $1.period.end { return $0.period.end < $1.period.end }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        for key in keys {
            _ = try historyReads(for: key.period, kind: key.kind, in: stored)
        }
    }

    /// Proves the stored rows are exactly the array the revision committed to.
    ///
    /// Count, dense `0..<count` sequence and digest run on raw persisted fields
    /// so a later projection format is not forced through this build's exception
    /// vocabulary just to know whether rows were lost. Domain mapping follows
    /// on the supported path only.
    private func committedAcknowledgmentRows(
        for row: ValidatedRevisionRow,
        in stored: ValidatedStore
    ) throws -> [StoredPeriodCheckpointAcknowledgment] {
        guard row.row.acknowledgmentCount >= 0 else {
            throw PeriodCheckpointStoreCorruption.invalidAcknowledgmentCount
        }
        guard row.row.acknowledgmentDigest.count == 32 else {
            throw PeriodCheckpointStoreCorruption.malformedAcknowledgmentDigest
        }
        let ordered = stored.acknowledgments[row.id] ?? []
        guard Int64(ordered.count) == row.row.acknowledgmentCount else {
            throw PeriodCheckpointStoreCorruption.acknowledgmentCountMismatch
        }
        guard ordered.map(\.sequence) == Array(0..<ordered.count) else {
            throw PeriodCheckpointStoreCorruption.malformedAcknowledgmentSequence
        }
        return ordered
    }
}
