import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

/// Phase 2.9C-C — the V1 acknowledgment commitment is a frozen durable format.
///
/// `CheckpointAcknowledgmentCommitment` is not a transient hash: once this
/// phase ships, every stored checkpoint revision carries its
/// `acknowledgmentDigest` for the rest of that store's life, and future builds
/// must keep producing the **same digest for the same accepted array**. A
/// round-trip test cannot hold that line — the writer, the reader and the test
/// would all call one encoder and drift together, and every previously stored
/// row would then re-read as `acknowledgmentDigestMismatch`, with no export or
/// repair path to recover the arrays. So the expected bytes below are literal
/// test data, derived once outside Swift from the grammar documented on the
/// encoder (python `struct` + `hashlib.sha256`), in the spirit of
/// `CanonicalProjectionTests`' golden vector.
///
/// ## The freeze contract
///
/// CheckpointAcknowledgmentCommitment V1 is durable local persistence
/// semantics. Once shipped, its exact byte grammar and digest behavior are
/// **frozen**: domain string, integer endianness, string framing, presence
/// flags, record ordering, field ordering and every token encoding. Changing
/// the V1 encoder requires either preserving exact V1 behavior, or introducing
/// a deliberately versioned migration / new commitment version. A normal
/// refactor must not silently alter the digest — these tests exist to fail the
/// moment one tries.
///
/// Every store here is temporary and synthetic. No real store is opened.
@MainActor
@Suite("Checkpoint acknowledgment commitment V1 is frozen")
struct PeriodCheckpointCommitmentFreezeTests {

    // MARK: - Golden vectors, derived outside Swift

    /// `sha256` of the canonical V1 encoding of the **empty** acknowledgment
    /// array: domain string, `UInt64` count `0`, nothing else.
    private static let goldenEmptyDigest =
        "0c2da813065ae52298adaf9c91b5f10a38128ef3953819560a29bf6020eef591"

    /// The empty array's full V1 byte encoding. The trailing eight zero bytes
    /// are the pinned `count == 0`.
    private static let goldenEmptyPayload =
        "0000002966696e616e63652d6170702f636865636b706f696e742d61636b6e6f776c6564676d656e74732f76310000000000000000"

    /// `sha256` of the canonical V1 encoding of the shared three-exception
    /// fixture (`CheckpointFixtures.exceptions`): the aggregate limitation with
    /// a basis, a day and three-decimal KWD money; the uncategorized spending
    /// with a day and negative EUR money; and a bare overdue occurrence whose
    /// optionals are all absent.
    private static let goldenThreeExceptionDigest =
        "3185641658c322373990e1a5eac0cd25ef935c1cb070d3a116242376037258fc"

    /// The fixture's full V1 byte encoding — length-framed strings, big-endian
    /// integers, `01`/`00` presence flags, fields in frozen order
    /// (id, kind, basis?, day?, minor?, code?, exponent?) and records in the
    /// accepted array's order.
    private static let goldenThreeExceptionPayload =
        "0000002966696e616e63652d6170702f636865636b706f696e742d61636b6e6f776c6564676d656e74732f76310000000000000003000000056167672d310000002061676772656761746545766964656e63654d6f64656c4c696d69746174696f6e01000000177374727563747572616c43616e6469646174654f6e6c7901013527ce0100000000000010e101000000034b574401000000000000000300000007756e6361742d310000001d756e63617465676f72697a656445636f6e6f6d69635370656e64696e670001013527c301fffffffffffffc190100000003455552010000000000000002000000096f7665726475652d31000000196f76657264756545787065637465644f6363757272656e63650000000000"

    private static func bytes(fromHex hex: String) -> [UInt8] {
        let characters = Array(hex.utf8)
        precondition(characters.count % 2 == 0)
        func nibble(_ ascii: UInt8) -> UInt8 {
            switch ascii {
            case 0x30...0x39: ascii - 0x30
            case 0x61...0x66: ascii - 0x61 + 10
            case 0x41...0x46: ascii - 0x41 + 10
            default: fatalError("not a hex digit")
            }
        }
        return stride(from: 0, to: characters.count, by: 2).map {
            nibble(characters[$0]) << 4 | nibble(characters[$0 + 1])
        }
    }

    // MARK: - Harness

    @MainActor
    private struct Harness {
        let container: ModelContainer

        init() throws {
            container = try ModelContainer(
                for: Schema(FinanceSchema.models),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }

        var context: ModelContext { container.mainContext }

        func repository() -> PeriodCheckpointRepository {
            PeriodCheckpointRepository(
                context: container.mainContext,
                makeDatasetIdentity: { CheckpointFixtures.datasetIdentity },
                now: { CheckpointFixtures.closedAt }
            )
        }

        func revisionRow(_ id: UUID) throws -> StoredPeriodCheckpointRevision {
            let identifier = id.uuidString
            return try context.fetch(
                FetchDescriptor<StoredPeriodCheckpointRevision>(
                    predicate: #Predicate { $0.identifier == identifier }
                )
            )[0]
        }

        func ackRows() throws -> [StoredPeriodCheckpointAcknowledgment] {
            try context.fetch(FetchDescriptor<StoredPeriodCheckpointAcknowledgment>())
                .sorted { $0.sequence < $1.sequence }
        }

        func save() throws { try context.save() }
    }

    private static func corruption(
        _ read: PeriodCheckpointStoredRead
    ) throws -> PeriodCheckpointStoreCorruption {
        guard case let .corrupt(corruption) = read else {
            Issue.record("expected corruption, got \(read)")
            throw FreezeTestFailure.unexpectedReadState
        }
        return corruption
    }

    private enum FreezeTestFailure: Error { case unexpectedReadState }

    // MARK: - The frozen vectors

    @Test("The empty acknowledgment array's V1 commitment is pinned byte for byte")
    func goldenEmptyVector() throws {
        let payload = Self.bytes(fromHex: Self.goldenEmptyPayload)
        let digest = Self.bytes(fromHex: Self.goldenEmptyDigest)

        // The encoder's bytes are the frozen payload, count zero and all.
        #expect(CheckpointAcknowledgmentCommitment.encode([] as [CheckpointAcknowledgmentCommitment.Record]) == payload)
        // The digest is SHA-256 of exactly those bytes.
        #expect(Array(try CheckpointAcknowledgmentCommitment.digest(of: [] as [AcknowledgedExceptionRecord])) == digest)
        #expect(Array(CheckpointAcknowledgmentCommitment.digest(of: [] as [StoredPeriodCheckpointAcknowledgment])) == digest)

        // And the durable row carries the frozen commitment: a clean revision
        // persists count 0 and this exact 32-byte digest, not a default.
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(try CheckpointFixtures.revision(id: id))
        let row = try harness.revisionRow(id)
        #expect(row.acknowledgmentCount == 0)
        #expect(Array(row.acknowledgmentDigest) == digest)
        #expect(try harness.ackRows().isEmpty)
    }

    @Test("The shared fixture's V1 commitment is pinned byte for byte")
    func goldenThreeExceptionVector() throws {
        let records = CheckpointFixtures.exceptions.map(AcknowledgedExceptionRecord.init)

        #expect(try CheckpointAcknowledgmentCommitment.encode(try records.map(CheckpointAcknowledgmentCommitment.Record.init)) == Self.bytes(fromHex: Self.goldenThreeExceptionPayload))
        #expect(Array(try CheckpointAcknowledgmentCommitment.digest(of: records)) == Self.bytes(fromHex: Self.goldenThreeExceptionDigest))
    }

    // MARK: - A corrupted stored count fails closed, cheaply

    /// The stored count is untrusted bytes. Every value below must come back as
    /// a corruption — never supported, never a trap — and the reader bounds
    /// every allocation by the rows actually fetched, so an `Int64.max` count
    /// is answered with a comparison, not an allocation. A reader that built an
    /// array from the stored count would hang or die here and fail this test.
    @Test("Adversarial stored acknowledgment counts fail closed")
    func adversarialStoredCounts() throws {
        let oneException = [PeriodCheckpointException(id: "overdue-one", kind: .overdueExpectedOccurrence)]

        func corruptionAfterSetting(count: Int64) throws -> PeriodCheckpointStoreCorruption {
            let harness = try Harness()
            let id = UUID()
            try harness.repository().store(
                try CheckpointFixtures.revision(id: id, exceptions: oneException)
            )
            try harness.revisionRow(id).acknowledgmentCount = count
            try harness.save()
            return try Self.corruption(
                harness.repository().latestRevision(
                    inPeriod: CheckpointFixtures.august, kind: .monthly
                )
            )
        }

        #expect(try corruptionAfterSetting(count: -1) == .invalidAcknowledgmentCount)
        #expect(try corruptionAfterSetting(count: Int64.min) == .invalidAcknowledgmentCount)
        #expect(try corruptionAfterSetting(count: Int64.max) == .acknowledgmentCountMismatch)
        #expect(try corruptionAfterSetting(count: 0) == .acknowledgmentCountMismatch)   // 0 with one row
        #expect(try corruptionAfterSetting(count: 100) == .acknowledgmentCountMismatch) // 100 with one row

        // One claimed, none stored.
        let harness = try Harness()
        let id = UUID()
        try harness.repository().store(
            try CheckpointFixtures.revision(id: id, exceptions: oneException)
        )
        try harness.ackRows().forEach(harness.context.delete)
        try harness.revisionRow(id).acknowledgmentCount = 1
        try harness.save()
        #expect(
            try Self.corruption(
                harness.repository().latestRevision(
                    inPeriod: CheckpointFixtures.august, kind: .monthly
                )
            ) == .acknowledgmentCountMismatch
        )
    }

    // MARK: - Only an exact 32-byte SHA-256 commitment is accepted

    @Test("Adversarial stored acknowledgment digest lengths and wrong bytes")
    func adversarialStoredDigests() throws {
        func corruptionAfterSetting(digest: Data) throws -> PeriodCheckpointStoreCorruption {
            let harness = try Harness()
            let id = UUID()
            try harness.repository().store(try CheckpointFixtures.revision(id: id))
            try harness.revisionRow(id).acknowledgmentDigest = digest
            try harness.save()
            return try Self.corruption(
                harness.repository().latestRevision(
                    inPeriod: CheckpointFixtures.august, kind: .monthly
                )
            )
        }

        #expect(try corruptionAfterSetting(digest: Data()) == .malformedAcknowledgmentDigest)
        #expect(try corruptionAfterSetting(digest: Data(repeating: 7, count: 31)) == .malformedAcknowledgmentDigest)
        #expect(try corruptionAfterSetting(digest: Data(repeating: 7, count: 33)) == .malformedAcknowledgmentDigest)
        #expect(try corruptionAfterSetting(digest: Data(repeating: 7, count: 32)) == .acknowledgmentDigestMismatch)
    }

    // MARK: - The commitment fields are part of stored identity

    @Test("An identical retry notices a stored count-only edit")
    func retryNoticesCountOnlyEdit() throws {
        let harness = try Harness()
        let id = UUID()
        let revision = try CheckpointFixtures.revision(id: id, exceptions: CheckpointFixtures.exceptions)
        try harness.repository().store(revision)

        try harness.revisionRow(id).acknowledgmentCount += 1
        try harness.save()

        #expect(throws: PeriodCheckpointStoreError.rejected(.revisionAlreadyStoredWithDifferentContent)) {
            try harness.repository().store(revision)
        }
    }

    @Test("An identical retry notices a stored digest-only edit")
    func retryNoticesDigestOnlyEdit() throws {
        let harness = try Harness()
        let id = UUID()
        let revision = try CheckpointFixtures.revision(id: id, exceptions: CheckpointFixtures.exceptions)
        try harness.repository().store(revision)

        var digest = Array(try harness.revisionRow(id).acknowledgmentDigest)
        digest[5] ^= 0x55
        try harness.revisionRow(id).acknowledgmentDigest = Data(digest)
        try harness.save()

        #expect(throws: PeriodCheckpointStoreError.rejected(.revisionAlreadyStoredWithDifferentContent)) {
            try harness.repository().store(revision)
        }
    }

    // MARK: - Semantic-field mutations the token decoders accept

    /// Both mutations below decode into perfectly valid domain values — a
    /// different caller-supplied id, and a valid two-digit currency. Only the
    /// commitment can see that neither is the array that was accepted.
    @Test("An identifier-only acknowledgment mutation is a digest mismatch")
    func identifierOnlyMutationIsDigestMismatch() throws {
        let harness = try Harness()
        try harness.repository().store(
            try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions)
        )
        try harness.ackRows()[1].exceptionIdentifier = "uncat-9"
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(
                    inPeriod: CheckpointFixtures.august, kind: .monthly
                )
            ) == .acknowledgmentDigestMismatch
        )
    }

    @Test("A valid-but-different currency exponent is a digest mismatch")
    func validExponentMutationIsDigestMismatch() throws {
        let harness = try Harness()
        try harness.repository().store(
            try CheckpointFixtures.revision(exceptions: CheckpointFixtures.exceptions)
        )
        // KWD's real exponent is 3; 2 decodes to a perfectly valid Currency.
        try harness.ackRows()[0].amountCurrencyExponent = 2
        try harness.save()

        #expect(
            try Self.corruption(
                harness.repository().latestRevision(
                    inPeriod: CheckpointFixtures.august, kind: .monthly
                )
            ) == .acknowledgmentDigestMismatch
        )
    }
}
