import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

/// The app boundary for the explicit-monetary schema.
///
/// FinanceCore proves the codec; these prove the three places the app can
/// still lose what the codec preserved: the import normalizer that used to
/// stamp every document back to 1.6.0, the SwiftData round trip, and the
/// stored-currency reconstruction that used to trap instead of refusing.
@MainActor
@Suite("Explicit monetary schema at the app boundary")
struct MoneyCurrencyV2BoundaryTests {

    private static let today = Day(year: 2026, month: 9, day: 16)
    private static let zeroExponentEUR = Currency(code: "EUR", minorUnitDigits: 0)

    private static func document(
        schemaVersion: String = Interchange.currentSchemaVersion,
        currency: Currency = .eur
    ) -> FinanceDocument {
        FinanceDocument(
            schemaVersion: schemaVersion,
            documentKind: "TEST",
            accounts: [
                Account(
                    id: "bank", name: "Bank", currency: currency, kind: .bank,
                    supportedRails: PaymentRail.euroBankRails
                )
            ],
            balances: [
                AccountBalance(
                    accountID: "bank",
                    balance: Money(minorUnits: 1_234, currency: currency),
                    asOf: today
                )
            ],
            planning: FinanceDocument.Planning(defaultScenario: .base)
        )
    }

    private let container: ModelContainer

    init() throws {
        container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private var context: ModelContext { container.mainContext }

    private func store() throws -> FinanceStore {
        try FinanceStore(context: context, now: fixtureInstant(Self.today))
    }

    // MARK: - Import version handling

    /// Import used to stamp every document to `currentSchemaVersion`. Doing
    /// that to a 2.0.0 document would silently demote it to a format that
    /// cannot express what it just said, and the next export would rescale.
    @Test("A recognized 2.0.0 import is not normalized back to 1.6.0")
    func recognizedV2ImportIsNotNormalizedBackTo160() throws {
        let store = try store()
        try store.importDocument(Self.document(schemaVersion: "2.0.0"))

        let exported = try store.exportDocument()
        #expect(exported.schemaVersion == "2.0.0")

        // Sticky: the default re-encode of a V2 source stays V2 even though
        // every amount in it would fit the legacy wire.
        #expect(Interchange.documentRequiresV2(exported) == false)
        let bytes = try Interchange.encode(exported)
        #expect(try Interchange.decode(bytes).schemaVersion == "2.0.0")
    }

    /// The V1 normalization contract is unchanged: an older additive minor is
    /// still read and stored as the version this build writes.
    @Test("A V1 import is still normalized to the current V1 schema")
    func v1ImportNormalizationIsUnchanged() throws {
        let store = try store()
        try store.importDocument(Self.document(schemaVersion: "1.4.0"))
        #expect(try store.exportDocument().schemaVersion == Interchange.currentSchemaVersion)
    }

    // MARK: - Persistence round trip

    /// SwiftData already stored code and exponent separately; the point of the
    /// new wire is that an export no longer throws that away.
    @Test("A non-canonical exponent survives store, export and re-import")
    func nonCanonicalExponentSurvivesPersistenceAndInterchange() throws {
        let original = Self.document(schemaVersion: "1.6.0", currency: Self.zeroExponentEUR)

        let first = try store()
        try first.importDocument(original)

        let exported = try first.exportDocument()
        #expect(exported.accounts[0].currency == Self.zeroExponentEUR)
        #expect(exported.balances[0].balance.minorUnits == 1_234)

        // The document says something V1 cannot, so the default export is V2.
        #expect(Interchange.documentRequiresV2(exported))
        let bytes = try Interchange.encode(exported)
        #expect(try Interchange.decode(bytes).schemaVersion == "2.0.0")

        let reopened = try Interchange.decode(bytes)
        #expect(reopened.accounts[0].currency == Self.zeroExponentEUR)
        #expect(reopened.balances[0].balance == Money(minorUnits: 1_234, currency: Self.zeroExponentEUR))

        // And an explicit legacy export refuses rather than rescaling it.
        #expect(throws: InterchangeError.notRepresentableInV1(field: "accounts[0].currency")) {
            try Interchange.encode(exported, as: .format(.v1))
        }
    }

    // MARK: - Stored currency metadata

    /// A corrupt currency row used to reach `Currency`'s precondition and take
    /// the process down. Refusing to open is the contract for every other
    /// unreadable token in the store; currency metadata is no different.
    @Test("Invalid stored currency metadata is refused, not trapped")
    func invalidStoredCurrencyMetadataIsRefused() throws {
        func failure(after corrupt: (StoredAccount) -> Void) throws -> PersistenceMappingError? {
            let container = try ModelContainer(
                for: Schema(FinanceSchema.models),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            let context = container.mainContext
            try StoredDocumentGraph.replace(
                with: Self.document(), in: context, writtenOn: Self.today
            )
            let row = try #require(try context.fetch(FetchDescriptor<StoredAccount>()).first)
            corrupt(row)
            try context.save()
            do { _ = try StoredDocumentGraph.load(from: context); return nil }
            catch let error as PersistenceMappingError { return error }
        }

        #expect(try failure { $0.currencyCode = "eur" } == .invalidCurrencyMetadata)
        #expect(try failure { $0.currencyCode = "EURO" } == .invalidCurrencyMetadata)
        #expect(try failure { $0.currencyExponent = -1 } == .invalidCurrencyMetadata)
        #expect(try failure { $0.currencyExponent = 7 } == .invalidCurrencyMetadata)

        // The currency itself is legal, but changing only the account leaves
        // its persisted balance with another exponent and must refuse.
        #expect(try failure { $0.currencyExponent = 0 } == .invalidDocument)
    }
}
