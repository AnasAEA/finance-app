import Foundation

/// Snapshot within one revision, not a carry-forward identity. Deliberately
/// does not conform to Equatable/Hashable: matching acknowledgments across
/// revisions requires a separately reviewed key that includes relationships.
public struct AcknowledgedExceptionRecord: Sendable {
    public let exception: PeriodCheckpointException

    public init(exception: PeriodCheckpointException) {
        self.exception = exception
    }
}

/// Pure audit value. New revision construction validates a supplied ready
/// decision; stored rehydration checks closed-snapshot invariants only. Neither
/// path performs a close action, reads a clock or writes state. Disposition is
/// checked for new revisions but is intentionally not retained.
public struct PeriodCheckpointRevision: Sendable {
    public let id: UUID
    public let period: SemanticInterval
    public let periodKind: ReviewPeriodKind
    public let revisionNumber: Int64
    public let predecessorID: UUID?
    public let closedAt: Date
    public let quality: PeriodCheckpointQuality
    public let projectionFormatVersion: SemanticPeriodProjectionFormat
    public let projectionDigest: SemanticProjectionDigest
    public let canonicalProjection: CanonicalSemanticPeriodProjection
    public let acknowledgedExceptions: [AcknowledgedExceptionRecord]
    public let safeClaims: PeriodCheckpointSafeClaims

    public init(
        id: UUID, revisionNumber: Int64, predecessorID: UUID?, closedAt: Date,
        readiness: PeriodCheckpointReadiness,
        canonicalProjection: CanonicalSemanticPeriodProjection
    ) throws {
        guard revisionNumber >= 1,
              (revisionNumber == 1) == (predecessorID == nil), predecessorID != id,
              closedAt.timeIntervalSinceReferenceDate.isFinite,
              readiness.disposition.isReady, readiness.blockers.isEmpty,
              readiness.undecidedExceptions.isEmpty,
              readiness.period == canonicalProjection.projection.period,
              readiness.kind == canonicalProjection.projection.kind,
              let suppliedProjection = readiness.projection,
              try CanonicalSemanticPeriodProjection(suppliedProjection).bytes == canonicalProjection.bytes,
              readiness.quality == (readiness.exceptions.isEmpty ? .clean : .withExceptions),
              readiness.disposition == (readiness.exceptions.isEmpty ? .readyClean : .readyWithAcknowledgedExceptions),
              Set(readiness.exceptions.map(\.id)).count == readiness.exceptions.count,
              readiness.exceptions.count == readiness.acknowledgedExceptions.count,
              Set(readiness.exceptions) == Set(readiness.acknowledgedExceptions),
              readiness.safeClaims == .surviving(readiness.exceptions),
              canonicalProjection.projection.coverage == .complete
        else { throw SemanticProjectionFormatError.invalidRevision }
        self.id = id
        self.period = readiness.period
        self.periodKind = readiness.kind
        self.revisionNumber = revisionNumber
        self.predecessorID = predecessorID
        self.closedAt = closedAt
        self.quality = readiness.quality
        self.projectionFormatVersion = canonicalProjection.format
        self.projectionDigest = canonicalProjection.digest
        self.canonicalProjection = canonicalProjection
        self.acknowledgedExceptions = readiness.acknowledgedExceptions.map(AcknowledgedExceptionRecord.init)
        self.safeClaims = readiness.safeClaims
    }

    /// Re-opens an already accepted persisted revision. Establishes only that
    /// this stored snapshot is internally a valid closed PeriodCheckpointRevision.
    /// It does not prove evaluator provenance, authorize creating or accepting a
    /// new checkpoint, or establish that these exceptions reflect today's
    /// evaluator output. New revisions must still use authoritative evaluator /
    /// PeriodCheckpointReadiness output through the readiness-based initializer.
    /// A future persistence writer should accept an already-created revision.
    ///
    /// At close, every carried exception must be explicitly acknowledged, so
    /// these historical snapshots are the complete accepted exception set. Their
    /// identity uniqueness is within this revision only, never carry-forward
    /// matching. The canonical payload must have passed the frozen reader;
    /// format and digest are derived from that validated value.
    public init(
        rehydratingStoredSnapshot id: UUID,
        period: SemanticInterval, periodKind: ReviewPeriodKind,
        revisionNumber: Int64, predecessorID: UUID?, closedAt: Date,
        canonicalProjection: CanonicalSemanticPeriodProjection,
        acknowledgedExceptions: [AcknowledgedExceptionRecord],
        quality: PeriodCheckpointQuality, safeClaims: PeriodCheckpointSafeClaims
    ) throws {
        let exceptions = acknowledgedExceptions.map(\.exception)
        guard revisionNumber >= 1,
              (revisionNumber == 1) == (predecessorID == nil), predecessorID != id,
              closedAt.timeIntervalSinceReferenceDate.isFinite,
              period == canonicalProjection.projection.period,
              periodKind == canonicalProjection.projection.kind,
              exceptions.allSatisfy({
                  ($0.kind == .aggregateEvidenceModelLimitation) == ($0.aggregateBasis != nil)
              }),
              Set(exceptions.map(\.id)).count == exceptions.count,
              quality == (exceptions.isEmpty ? .clean : .withExceptions),
              safeClaims == .surviving(exceptions),
              canonicalProjection.projection.coverage == .complete
        else { throw SemanticProjectionFormatError.invalidRevision }
        self.id = id
        self.period = period
        self.periodKind = periodKind
        self.revisionNumber = revisionNumber
        self.predecessorID = predecessorID
        self.closedAt = closedAt
        self.quality = quality
        self.projectionFormatVersion = canonicalProjection.format
        self.projectionDigest = canonicalProjection.digest
        self.canonicalProjection = canonicalProjection
        self.acknowledgedExceptions = acknowledgedExceptions
        self.safeClaims = safeClaims
    }
}
