import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

/// The boundary around the checkpoint close policy.
///
/// The policy decides what should be written. This suite holds the two claims
/// that make that safe to have in the product at all: it *cannot* write, and
/// the storage half it decides for still refuses everything it refused before.
///
/// Source-shape assertions are used only where the property is about the shape
/// — that the file generates no identity, reads no clock and can reach no
/// store. Everything the policy *does* is tested as behaviour in
/// `CheckpointClosePolicyTests`.
@Suite("Checkpoint close policy boundary")
struct CheckpointClosePolicyBoundaryTests {

    private static let policyPath = "Persistence/CheckpointClosePolicy.swift"

    // MARK: - Reading the product's own source

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FinanceApp")
    }

    /// Source with line comments removed: this suite asks what the code does,
    /// and the policy file explains at length what it deliberately does not do.
    private static func code(_ relativePath: String) throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    private static func swiftSources(under layers: [String]) throws -> [(path: String, text: String)] {
        let manager = FileManager.default
        var found: [(String, String)] = []
        for layer in layers {
            let directory = sourceRoot.appendingPathComponent(layer)
            guard let enumerator = manager.enumerator(atPath: directory.path) else { continue }
            for case let relative as String in enumerator where relative.hasSuffix(".swift") {
                found.append((
                    "\(layer)/\(relative)",
                    try String(
                        contentsOf: directory.appendingPathComponent(relative), encoding: .utf8
                    )
                ))
            }
        }
        return found
    }

    private static let productionLayers = [
        "App", "Components", "Features", "Surface", "Attention", "Persistence",
    ]

    /// Read a declaration through its balanced body, after comments are removed.
    private static func declaration(_ marker: String, in code: String) throws -> String {
        let start = try #require(code.range(of: marker)).lowerBound
        let opening = try #require(code[start...].firstIndex(of: "{"))
        var depth = 0
        for index in code[opening...].indices {
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" { depth -= 1 }
            if depth == 0 { return String(code[start...index]) }
        }
        Issue.record("unclosed declaration: \(marker)")
        return ""
    }

    @Test("ID7: classification has no append-metadata parameter, construction or generation")
    func classificationIsMetadataFree() throws {
        let code = try Self.code(Self.policyPath)
        let classifier = try Self.declaration("static func classify(", in: code)
        let signature = try #require(classifier.split(separator: "{").first)
        #expect(signature.contains("currentReadiness readiness: PeriodCheckpointReadiness"))
        #expect(signature.contains("currentChainTip tip: PeriodCheckpointStoredRead"))
        for forbidden in ["CheckpointAppendIdentity", "Date", "candidateID", "closedAt", "UUID()", "materialize(", "PeriodCheckpointRevision("] {
            #expect(!classifier.contains(forbidden), "classification reaches \(forbidden)")
        }
        #expect(!signature.contains("UUID"))
        #expect(!code.contains("func decide("))
    }

    @Test("ID8: materialization consumes a plan without classification or observation")
    func materializationDoesNotRepeatPolicy() throws {
        let code = try Self.code(Self.policyPath)
        let materializer = try Self.declaration("static func materialize(", in: code)
        #expect(materializer.contains("plan: AppendPlan"))
        #expect(materializer.contains("identity: CheckpointAppendIdentity"))
        #expect(materializer.contains("PeriodCheckpointRevision("))
        for forbidden in ["classify(", "outcome(", "isMonthlyProductScope(", "PeriodCheckpointBaselineReader", "PeriodCheckpointEvaluator", "ReviewEngine", "repository", "store(", "Date()", "UUID()", ".now"] {
            #expect(!materializer.contains(forbidden), "materialization repeats or observes \(forbidden)")
        }
    }

    @Test("ID9: only classification can create an immutable opaque append plan")
    func appendPlanHasNoGeneralInitializer() throws {
        let code = try Self.code(Self.policyPath)
        let plan = try Self.declaration("struct AppendPlan:", in: code)
        #expect(plan.contains("fileprivate init("))
        #expect(plan.components(separatedBy: "init(").count == 2)
        #expect(plan.components(separatedBy: "fileprivate let ").count == 5)
        for forbidden in ["public init", "internal init", " var ", "->", "PeriodCheckpointStoredRead", "CheckpointAppendIdentity", "Date"] {
            #expect(!plan.contains(forbidden), "plan exposes or retains \(forbidden)")
        }
        #expect(code.components(separatedBy: "AppendPlan(").count == 2)
        let classifier = try Self.declaration("static func classify(", in: code)
        #expect(classifier.contains("AppendPlan("))
    }

    @Test("ID10: no policy helper materializes or creates identity for non-append outcomes")
    func noEagerCombinedPolicyHelper() throws {
        let code = try Self.code(Self.policyPath)
        // One declaration and zero internal calls. A materializer accepts only
        // an AppendPlan, so alreadyCurrent/refused cannot be passed to it.
        #expect(code.components(separatedBy: "materialize(").count == 2)
        #expect(code.components(separatedBy: "CheckpointAppendIdentity(").count == 1)
        for forbidden in ["UUID()", "Date()", "UUID.init", "Date.init", ".now"] {
            #expect(!code.contains(forbidden))
        }
    }

    // MARK: - The policy creates nothing of its own

    @Test("I5/I6: the policy generates no identity and reads no clock")
    func thePolicyCreatesNeitherIdentityNorTime() throws {
        let policy = try Self.code(Self.policyPath)

        // Identity and time arrive as values. A policy that minted either would
        // decide a different thing on every run and could not be tested at all.
        for forbidden in ["UUID()", "Date()", "Date.init", "UUID.init", ".now", "Date(timeInterval"] {
            #expect(!policy.contains(forbidden), "the policy creates \(forbidden)")
        }

        // It does name both types — as parameters it is handed.
        #expect(policy.contains("candidateID: UUID"))
        #expect(policy.contains("closedAt: Date"))
    }

    @Test("The policy can reach no store, no repository and no screen")
    func thePolicyIsPure() throws {
        let policy = try Self.code(Self.policyPath)

        for forbidden in [
            "import SwiftData", "import SwiftUI", "ModelContext", "ModelContainer",
            "FinanceStore", "PeriodCheckpointRepository", "@MainActor", "@Observable",
            "PeriodCheckpointBaselineReader.source(from:", "checkpoints",
        ] {
            #expect(!policy.contains(forbidden), "the policy reaches \(forbidden)")
        }

        // The only framework imports it needs.
        #expect(policy.contains("import FinanceCore"))
        #expect(policy.contains("import Foundation"))
    }

    @Test("The policy writes nothing, closes nothing and runs no matcher")
    func thePolicyOpensNoWritePath() throws {
        let policy = try Self.code(Self.policyPath)

        for forbidden in [
            "store(", "compareAndAppend", "rehydratingStoredSnapshot",
            "PeriodCheckpointAcknowledgmentMatcher", "carryForwardCandidate",
            "func closePeriod", "func closeMonth", "func reverify", "func acknowledgeAndClose",
        ] {
            #expect(!policy.contains(forbidden), "the policy opens \(forbidden)")
        }
    }

    @Test("Authority is a typed subject set: no raw acknowledgment identifier enters the policy")
    func thePolicyTakesNoIdentifierAuthority() throws {
        let policy = try Self.code(Self.policyPath)
        for forbidden in [
            "acknowledgedExceptionIDs", "confirmedAcknowledgmentIDs", "acknowledgedIDs",
            "carryForwardCandidateIDs", "confirmedAcknowledgments:",
        ] {
            #expect(!policy.contains(forbidden), "the policy accepts \(forbidden)")
        }
    }

    // MARK: - Exactly one construction site, and still no writer

    @Test("FZ5: exactly one production file constructs a checkpoint revision")
    func oneConstructionSite() throws {
        var constructors: [String] = []
        for file in try Self.swiftSources(under: Self.productionLayers) {
            // The repository's own use is rehydration on the read path, which
            // is a different initializer and is forbidden everywhere else.
            guard file.path != "Persistence/PeriodCheckpointRepository.swift" else { continue }
            if try Self.code(file.path).contains("PeriodCheckpointRevision(") {
                constructors.append(file.path)
            }
        }
        #expect(constructors == [Self.policyPath], "revision construction sites: \(constructors)")
    }

    @Test("FZ6/FZ7/FZ8/FZ9: no production write, close, re-verify, compare-and-append or matcher")
    func noProductionWritePathExists() throws {
        let approvedStoreCaller = "Persistence/EndedMonthCheckpointWriter.swift"
        let storagePrimitive = "Persistence/PeriodCheckpointRepository.swift"
        let neverInProduction = [
            "compareAndAppend",
            "rehydratingStoredSnapshot", "PeriodCheckpointAcknowledgmentMatcher",
            "carryForwardCandidates", "func closePeriod", "func closeCheckpoint",
            "func closeMonth", "func reverify", "func reVerify", "func acknowledgeAndClose",
        ]
        var offenders: [String] = []
        for file in try Self.swiftSources(under: Self.productionLayers)
        where file.path != storagePrimitive {
            let code = try Self.code(file.path)
            for forbidden in neverInProduction where code.contains(forbidden) {
                offenders.append("\(file.path): \(forbidden)")
            }
        }
        #expect(offenders.isEmpty, "a production write or matcher path exists: \(offenders)")
        // The single-authorized-writer guard itself lives once, in
        // EndedMonthCheckpointWriteTests ("W22"); this case owns the scan above.
    }

    @Test("The repository still offers no close, re-verify or compare-and-append")
    func theRepositoryGrewNoWriteAPI() throws {
        let repository = try Self.code("Persistence/PeriodCheckpointRepository.swift")
        for forbidden in [
            "func closePeriod", "func reverify", "func reVerify", "func compareAndAppend",
            "func acknowledgeAndClose", "func append(", "func replace(",
        ] {
            #expect(!repository.contains(forbidden), "the repository grew \(forbidden)")
        }
        // The three primitives, unchanged.
        #expect(repository.contains("func store("))
        #expect(repository.contains("func revisions("))
        #expect(repository.contains("func latestRevision("))
        #expect(repository.contains("func occupancy("))
    }

    @Test("FZ10: the ended-month acknowledgment interaction is untouched by the policy")
    func theAcknowledgmentInteractionIsUnchanged() throws {
        let interaction = try Self.code("Persistence/EndedMonthAcknowledgment.swift")
        for forbidden in [
            "CheckpointClosePolicy", "PeriodCheckpointRevision", "PeriodCheckpointStoredRead",
            "baselineComparison", "CheckpointAppendIdentity",
        ] {
            #expect(!interaction.contains(forbidden), "the interaction learned about \(forbidden)")
        }
    }

    @Test("No screen learned about the policy")
    func noScreenReachesThePolicy() throws {
        var offenders: [String] = []
        for file in try Self.swiftSources(under: ["App", "Components", "Features", "Surface"]) {
            let code = try Self.code(file.path)
            for forbidden in [
                "CheckpointClosePolicy", "CheckpointAppendIdentity", "PeriodCheckpointRevision",
                "import FinanceCore",
            ] where code.contains(forbidden) {
                offenders.append("\(file.path): \(forbidden)")
            }
        }
        #expect(offenders.isEmpty, "a screen reached the policy: \(offenders)")
    }
}

// MARK: - The policy's candidates against the real storage guards

/// What happens when two candidates the policy produced from one tip meet the
/// repository.
///
/// This is the concurrency contract, stated end to end rather than assumed: the
/// policy derives the next revision number from the tip it was shown, so two
/// decisions taken against the same tip produce the same number under different
/// identities. The repository's existing append guards — not a new
/// `compareAndAppend`, which is still absent — decide which one survives.
///
/// Every store here is temporary and in memory. No production caller is added:
/// the calls below are this test's, exactly as every other repository test's
/// calls are its own.
@MainActor
@Suite("Checkpoint close policy candidates meet the repository")
struct CheckpointClosePolicyRepositoryPinTests {

    private static let august = ReviewInterval.month(MonthKey(year: 2026, month: 8))
    private let asOf = Day(year: 2026, month: 9, day: 3)
    private let closedAt = Date(timeIntervalSinceReferenceDate: 820_000_000)

    private func euro(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .eur)! }

    private func document() -> FinanceDocument {
        let account = Account(
            id: "account-test", name: "Test current account", currency: .eur,
            kind: .bank, supportedRails: PaymentRail.euroBankRails
        )
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account],
            balances: [
                AccountBalance(
                    accountID: account.id, balance: euro("500.00"), asOf: Self.august.start
                )
            ],
            planning: FinanceDocument.Planning(defaultScenario: .base)
        )
    }

    private func projection(spendingMinor: Int64) -> SemanticPeriodProjection {
        SemanticPeriodProjection(
            period: SemanticInterval(Self.august),
            kind: .monthly,
            coverage: .complete,
            budget: SemanticBudgetFact(
                periodEconomicSpending: Money(minorUnits: spendingMinor, currency: .eur),
                uncategorized: Money(minorUnits: 0, currency: .eur),
                attributions: []
            ),
            transactions: [],
            observations: [],
            expectations: []
        )
    }

    private func readiness(
        spendingMinor: Int64, tip: PeriodCheckpointStoredRead
    ) throws -> PeriodCheckpointReadiness {
        var request = PeriodCheckpointRequest(
            period: Self.august,
            kind: .monthly,
            asOf: asOf,
            review: try ReviewEngine.review(
                ReviewRequest(
                    document: document(), kind: .monthly, interval: Self.august,
                    asOf: Self.august.end, coverage: .liveCovered([Self.august])
                )
            ),
            projection: projection(spendingMinor: spendingMinor)
        )
        request.baselineComparison = PeriodCheckpointBaselineReader.comparison(
            baseline: PeriodCheckpointBaselineReader.source(for: tip),
            current: PeriodCheckpointEvaluator.evaluate(request)
        )
        return PeriodCheckpointEvaluator.evaluate(request)
    }

    private func candidate(
        _ decision: CheckpointClosePolicyDecision,
        identity: CheckpointAppendIdentity
    ) throws -> PeriodCheckpointRevision {
        switch decision {
        case let .firstClose(plan), let .reverify(plan):
            switch CheckpointClosePolicy.materialize(plan: plan, identity: identity) {
            case let .candidate(revision): return revision
            case .refused:
                Issue.record("valid classified fixture should materialize")
                throw PeriodCheckpointPersistenceTests.CheckpointTestFailure.unexpectedReadState
            }
        case .alreadyCurrent, .refused:
            Issue.record("expected an append candidate, got \(decision)")
            throw PeriodCheckpointPersistenceTests.CheckpointTestFailure.unexpectedReadState
        }
    }

    @Test("R1/R2: two candidates from one tip cannot both become revision n+1")
    func twoCandidatesFromOneTipCannotBothAppend() throws {
        let harness = try PeriodCheckpointPersistenceTests.Harness()

        // A first close, decided and then actually stored.
        let first = try candidate(
            CheckpointClosePolicy.classify(
                currentReadiness: try readiness(spendingMinor: 10_000, tip: .empty),
                currentChainTip: .empty
            ),
            identity: CheckpointAppendIdentity(
                candidateID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-00000000AAAA")!,
                closedAt: closedAt
            )
        )
        #expect(first.revisionNumber == 1)
        #expect(try harness.repository().store(first) == .stored)

        // The tip everyone now sees.
        let tip = PeriodCheckpointStoredRead.supported(first)
        let moved = try readiness(spendingMinor: 20_000, tip: tip)

        // Two decisions taken against that same tip, by two would-be writers
        // holding two fresh identities.
        let left = try candidate(
            CheckpointClosePolicy.classify(
                currentReadiness: moved, currentChainTip: tip
            ),
            identity: CheckpointAppendIdentity(
                candidateID: UUID(uuidString: "BBBBBBBB-0000-0000-0000-00000000BBBB")!,
                closedAt: closedAt
            )
        )
        let right = try candidate(
            CheckpointClosePolicy.classify(
                currentReadiness: moved, currentChainTip: tip
            ),
            identity: CheckpointAppendIdentity(
                candidateID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-00000000CCCC")!,
                closedAt: closedAt
            )
        )

        // Same chain position, same predecessor, different identity: a branch,
        // and the repository has always refused one.
        #expect(left.revisionNumber == 2)
        #expect(right.revisionNumber == 2)
        #expect(left.predecessorID == first.id)
        #expect(right.predecessorID == first.id)
        #expect(left.id != right.id)

        #expect(try harness.repository().store(left) == .stored)
        #expect(throws: PeriodCheckpointStoreError.rejected(.duplicateRevisionNumber)) {
            try harness.repository().store(right)
        }

        // One revision 2 on disk, and it is the one that won.
        let stored = try harness.rows(StoredPeriodCheckpointRevision.self)
            .filter { $0.revisionNumber == 2 }
        #expect(stored.count == 1)
        #expect(stored.first?.identifier == left.id.uuidString)
    }

    @Test("R3: re-deciding after a stored close is already current, so nothing is appended twice")
    func aStoredCloseMakesTheNextDecisionAlreadyCurrent() throws {
        let harness = try PeriodCheckpointPersistenceTests.Harness()

        let first = try candidate(
            CheckpointClosePolicy.classify(
                currentReadiness: try readiness(spendingMinor: 10_000, tip: .empty),
                currentChainTip: .empty
            ),
            identity: CheckpointAppendIdentity(
                candidateID: UUID(uuidString: "DDDDDDDD-0000-0000-0000-00000000DDDD")!,
                closedAt: closedAt
            )
        )
        #expect(try harness.repository().store(first) == .stored)

        // Read the tip back the way a caller would, then decide again over the
        // unchanged month. This is the product's idempotency: not a matching
        // UUID, but a recomputation that finds nothing left to say.
        let tip = harness.repository().latestRevision(
            inPeriod: SemanticInterval(Self.august), kind: .monthly
        )
        let decision = CheckpointClosePolicy.classify(
            currentReadiness: try readiness(spendingMinor: 10_000, tip: tip),
            currentChainTip: tip
        )

        guard case .alreadyCurrent = decision else {
            Issue.record("expected alreadyCurrent, got \(decision)")
            return
        }
        #expect(try harness.rows(StoredPeriodCheckpointRevision.self).count == 1)
    }

    @Test("R4: a candidate the policy produced is accepted by the repository as written")
    func aCandidateStoresLosslessly() throws {
        let harness = try PeriodCheckpointPersistenceTests.Harness()

        let revision = try candidate(
            CheckpointClosePolicy.classify(
                currentReadiness: try readiness(spendingMinor: 10_000, tip: .empty),
                currentChainTip: .empty
            ),
            identity: CheckpointAppendIdentity(
                candidateID: UUID(uuidString: "FFFFFFFF-0000-0000-0000-00000000FFFF")!,
                closedAt: closedAt
            )
        )
        #expect(try harness.repository().store(revision) == .stored)

        let read = try PeriodCheckpointPersistenceTests.supported(
            harness.repository().latestRevision(
                inPeriod: SemanticInterval(Self.august), kind: .monthly
            )
        )
        #expect(read.id == revision.id)
        #expect(read.revisionNumber == revision.revisionNumber)
        #expect(read.predecessorID == revision.predecessorID)
        #expect(read.closedAt == revision.closedAt)
        #expect(read.canonicalProjection.bytes == revision.canonicalProjection.bytes)
        #expect(read.projectionDigest == revision.projectionDigest)

        // Storing the very same candidate again is the storage layer's own
        // idempotent no-op, and it remains so.
        #expect(try harness.repository().store(revision) == .alreadyStored)
        #expect(try harness.rows(StoredPeriodCheckpointRevision.self).count == 1)
    }
}
