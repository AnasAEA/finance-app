import CryptoKit
import Foundation

/// A private, versioned archive of reconstructed historical transactions.
///
/// This is deliberately a separate interchange root from `FinanceDocument`:
/// archive rows are searchable evidence, not live ledger transactions, account
/// balances, or forecast inputs. Importers must persist them in the archive
/// store and must never compose them into current finance state.
public struct FinanceHistoryDocument: Codable, Hashable, Sendable {
    public var schemaVersion: String
    public var documentKind: String
    public var archiveID: String

    /// Immutable revision of the evidence repository used by the exporter.
    public var sourceRevision: String

    /// SHA-256 of the canonical, compact JSON encoding of `payload`.
    public var contentSHA256: String
    public var payload: FinanceHistoryPayload

    /// Compatibility name for callers that describe the payload digest as the
    /// records hash. The encoded schema uses the less ambiguous
    /// `contentSHA256`, because metadata and source gaps are covered too.
    public var recordsHash: String { contentSHA256 }

    public init(
        schemaVersion: String,
        documentKind: String,
        archiveID: String,
        sourceRevision: String,
        contentSHA256: String,
        payload: FinanceHistoryPayload
    ) {
        self.schemaVersion = schemaVersion
        self.documentKind = documentKind
        self.archiveID = archiveID
        self.sourceRevision = sourceRevision
        self.contentSHA256 = contentSHA256
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, documentKind, archiveID, sourceRevision, contentSHA256, payload
    }

    /// The document enforces its own version/body invariant, so no caller can
    /// produce an archive whose envelope and monetary body disagree.
    ///
    /// `schemaVersion` is public and mutable — historical writers legitimately
    /// set it — and `Encodable` cannot reach up and configure its own encoder.
    /// So the check runs here, at the root, before a single byte of payload is
    /// written: whatever grammar the encoder was configured for must be the one
    /// this document's declared version actually speaks. Absent context is a
    /// mismatch too; a monetary body is never guessed.
    public func encode(to encoder: Encoder) throws {
        guard let expected = FinanceHistoryInterchange.monetaryWire(for: schemaVersion) else {
            throw FinanceHistorySchemaError(
                path: "schemaVersion",
                message: "\(schemaVersion) is not a readable version, so no monetary grammar can be chosen"
            )
        }
        let actual = encoder.userInfo[.financeHistoryMonetaryWire] as? FinanceHistoryMonetaryWire
        guard actual == expected else {
            throw FinanceHistorySchemaError(
                path: "schemaVersion",
                message: actual == nil
                    ? "encoding \(schemaVersion) needs FinanceHistoryInterchange.encode(_:) or encoder(for:); a bare encoder states no monetary grammar"
                    : "schemaVersion \(schemaVersion) speaks \(expected.rawValue) but the encoder was configured for \(actual!.rawValue)"
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(documentKind, forKey: .documentKind)
        try container.encode(archiveID, forKey: .archiveID)
        try container.encode(sourceRevision, forKey: .sourceRevision)
        try container.encode(contentSHA256, forKey: .contentSHA256)
        try container.encode(payload, forKey: .payload)
    }
}

public struct FinanceHistoryPayload: Codable, Hashable, Sendable {
    /// Inclusive archive/live boundary. Archive records are allowed only on or
    /// before this day; the live ledger owns dates after it.
    public var archiveCutoff: Day
    public var recordCount: Int
    public var dateRange: FinanceHistoryDateRange
    public var accounts: [FinanceHistoryAccount]
    public var sourceGaps: [FinanceHistorySourceGap]
    public var records: [FinanceHistoricalRecord]

    public init(
        archiveCutoff: Day,
        recordCount: Int,
        dateRange: FinanceHistoryDateRange,
        accounts: [FinanceHistoryAccount],
        sourceGaps: [FinanceHistorySourceGap] = [],
        records: [FinanceHistoricalRecord]
    ) {
        self.archiveCutoff = archiveCutoff
        self.recordCount = recordCount
        self.dateRange = dateRange
        self.accounts = accounts
        self.sourceGaps = sourceGaps
        self.records = records
    }

    private enum CodingKeys: String, CodingKey {
        case archiveCutoff, recordCount, dateRange, accounts, sourceGaps, records
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        archiveCutoff = try container.decode(Day.self, forKey: .archiveCutoff)
        recordCount = try container.decode(Int.self, forKey: .recordCount)
        dateRange = try container.decode(FinanceHistoryDateRange.self, forKey: .dateRange)
        accounts = try container.decode([FinanceHistoryAccount].self, forKey: .accounts)
        sourceGaps = try container.decode([FinanceHistorySourceGap].self, forKey: .sourceGaps)
        records = try container.decode([FinanceHistoricalRecord].self, forKey: .records)
    }

    /// Canonical collection order makes independently generated exports byte
    /// identical even when an exporter built its arrays from hash maps.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(archiveCutoff, forKey: .archiveCutoff)
        try container.encode(recordCount, forKey: .recordCount)
        try container.encode(dateRange, forKey: .dateRange)
        try container.encode(accounts.sorted(by: FinanceHistoryOrdering.accounts), forKey: .accounts)
        try container.encode(sourceGaps.sorted(by: FinanceHistoryOrdering.gaps), forKey: .sourceGaps)
        try container.encode(records.sorted(by: FinanceHistoryOrdering.records), forKey: .records)
    }
}

public struct FinanceHistoryDateRange: Codable, Hashable, Sendable {
    public var start: Day
    public var end: Day

    public init(start: Day, end: Day) {
        self.start = start
        self.end = end
    }
}

/// Safe display identity only. Raw account numbers, IBANs, provider account
/// identifiers, and statement identifiers do not belong in this schema.
public struct FinanceHistoryAccount: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var provider: String

    public init(id: String, name: String, provider: String) {
        self.id = id
        self.name = name
        self.provider = provider
    }
}

public struct FinanceHistorySourceGap: Codable, Hashable, Sendable {
    public var startMonth: MonthKey
    public var endMonth: MonthKey

    /// Exporter-owned completeness vocabulary, carried without flattening
    /// (for example `PARTIAL` or `NO_TRANSACTION_EVIDENCE`).
    public var completeness: String
    public var affectedSources: [String]
    public var message: String

    public init(
        startMonth: MonthKey,
        endMonth: MonthKey,
        completeness: String,
        affectedSources: [String],
        message: String
    ) {
        self.startMonth = startMonth
        self.endMonth = endMonth
        self.completeness = completeness
        self.affectedSources = affectedSources
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case startMonth, endMonth, completeness, affectedSources, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startMonth = try container.decode(MonthKey.self, forKey: .startMonth)
        endMonth = try container.decode(MonthKey.self, forKey: .endMonth)
        completeness = try container.decode(String.self, forKey: .completeness)
        affectedSources = try container.decode([String].self, forKey: .affectedSources)
        message = try container.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startMonth, forKey: .startMonth)
        try container.encode(endMonth, forKey: .endMonth)
        try container.encode(completeness, forKey: .completeness)
        try container.encode(affectedSources.sorted(), forKey: .affectedSources)
        try container.encode(message, forKey: .message)
    }

    public func intersects(_ range: FinanceHistoryDateRange) -> Bool {
        startMonth <= range.end.monthKey && endMonth >= range.start.monthKey
    }
}

/// Which monetary grammar a FinanceHistory body speaks.
///
/// FinanceHistory owns its version axis. This is deliberately **not**
/// `InterchangeFormat`, and the history codec never consults
/// `CodingUserInfoKey.financeDocumentMoneyWire`: a FinanceDocument V1/V2
/// selection must never reach in and change how an archive is written or read.
public enum FinanceHistoryMonetaryWire: String, Hashable, Sendable {
    /// 1.0.0 and 1.1.0 — `{"cents": Int64, "currency": "EUR"}`. The exponent is
    /// not on the wire; it is the frozen `Currency.legacyDefaultDigits` value.
    case legacyV1
    /// 2.0.0 — `{"minorUnits": Int64, "currency": {"code": …, "exponent": …}}`.
    case v2
}

extension CodingUserInfoKey {
    /// History-local wire selector, independent of FinanceDocument's.
    static let financeHistoryMonetaryWire = CodingUserInfoKey(rawValue: "financeHistoryMonetaryWire")!
}

/// Exact original-currency amount.
///
/// Integer minor units avoid floating-point parsing and make Python/Swift
/// interchange unambiguous. `currencyExponent` completes the `Currency`
/// identity: 2.0.0 states it on the wire, and 1.0.0/1.1.0 reconstruct it from
/// the frozen historical table — never from the evolving registry, which would
/// let a later currency-support commit change what old archives already say.
public struct FinanceHistoryOriginalAmount: Codable, Hashable, Sendable {
    /// Signed minor units of `currency`. The historical key is named `cents`;
    /// the value has always been minor units at the currency's own scale.
    public var cents: Int64

    /// ISO-4217-style alphabetic code.
    public var currency: String

    /// Minor-unit digits completing the currency identity.
    public var currencyExponent: Int

    /// Historical construction: the exponent is the frozen 1.x reading of
    /// `currency`, which is exactly what a 1.0.0/1.1.0 archive means.
    public init(cents: Int64, currency: String) {
        self.init(
            cents: cents,
            currency: currency,
            currencyExponent: Currency.legacyDefaultDigits(currency)
        )
    }

    /// Full-identity construction. Validation rejects an out-of-range exponent;
    /// this initializer stays total so a malformed archive reports an issue
    /// rather than tripping a `Currency` precondition.
    public init(cents: Int64, currency: String, currencyExponent: Int) {
        self.cents = cents
        self.currency = currency
        self.currencyExponent = currencyExponent
    }

    public init(_ money: Money) {
        self.init(
            cents: money.minorUnits,
            currency: money.currency.code,
            currencyExponent: money.currency.minorUnitDigits
        )
    }

    /// The single authoritative archive-amount → domain-money mapping.
    ///
    /// Importers must consume this instead of rebuilding a `Currency` from the
    /// code, which would reintroduce the evolving registry at the app layer.
    public var money: Money? {
        guard Currency.isValidCode(currency), (0...6).contains(currencyExponent) else { return nil }
        return Money(
            minorUnits: cents,
            currency: Currency(code: currency, minorUnitDigits: currencyExponent)
        )
    }

    /// Whether the frozen 1.x grammar can state this identity at all.
    public var isRepresentableInLegacyV1: Bool {
        currencyExponent == Currency.legacyDefaultDigits(currency)
    }

    private enum LegacyCodingKeys: String, CodingKey { case cents, currency }
    private enum V2CodingKeys: String, CodingKey { case minorUnits, currency }
    private enum CurrencyCodingKeys: String, CodingKey { case code, exponent }

    private static func declaredWire(_ userInfo: [CodingUserInfoKey: Any]) -> FinanceHistoryMonetaryWire? {
        userInfo[.financeHistoryMonetaryWire] as? FinanceHistoryMonetaryWire
    }

    /// Structural only. Semantic checks stay in `FinanceHistoryInterchange`
    /// so every malformed archive reports issues in one vocabulary.
    public init(from decoder: Decoder) throws {
        switch Self.declaredWire(decoder.userInfo) ?? .v2 {
        case .legacyV1:
            let container = try decoder.container(keyedBy: LegacyCodingKeys.self)
            self.init(
                cents: try container.decode(Int64.self, forKey: .cents),
                currency: try container.decode(String.self, forKey: .currency)
            )
        case .v2:
            let container = try decoder.container(keyedBy: V2CodingKeys.self)
            let minorUnits = try container.decode(Int64.self, forKey: .minorUnits)
            let currencyContainer = try container.nestedContainer(
                keyedBy: CurrencyCodingKeys.self, forKey: .currency
            )
            self.init(
                cents: minorUnits,
                currency: try currencyContainer.decode(String.self, forKey: .code),
                currencyExponent: try currencyContainer.decode(Int.self, forKey: .exponent)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        // This type has no `schemaVersion` of its own, so it has no authority
        // to pick a grammar. Without stated context it refuses rather than
        // silently choosing one.
        guard let wire = Self.declaredWire(encoder.userInfo) else {
            throw FinanceHistorySchemaError(
                path: "originalAmount",
                message: "no FinanceHistory monetary grammar was stated; encode through FinanceHistoryInterchange"
            )
        }
        switch wire {
        case .legacyV1:
            // A 1.x archive cannot state an exponent, so it may only carry an
            // identity the frozen table already implies. Never rescale, never
            // normalize, never drop the exponent silently.
            guard isRepresentableInLegacyV1 else {
                throw FinanceHistorySchemaError(
                    path: "originalAmount.currency",
                    message: "\(currency)/\(currencyExponent) is not representable in a 1.x archive"
                )
            }
            var container = encoder.container(keyedBy: LegacyCodingKeys.self)
            try container.encode(cents, forKey: .cents)
            try container.encode(currency, forKey: .currency)
        case .v2:
            var container = encoder.container(keyedBy: V2CodingKeys.self)
            try container.encode(cents, forKey: .minorUnits)
            var currencyContainer = container.nestedContainer(
                keyedBy: CurrencyCodingKeys.self, forKey: .currency
            )
            try currencyContainer.encode(currency, forKey: .code)
            try currencyContainer.encode(currencyExponent, forKey: .exponent)
        }
    }
}

public struct FinanceHistoryCategory: Codable, Hashable, Sendable {
    public var top: String
    public var sub: String?

    public init(top: String, sub: String? = nil) {
        self.top = top
        self.sub = sub
    }
}

public struct FinanceHistoryFlags: Codable, Hashable, Sendable {
    public var internalTransfer: Bool
    public var passThrough: FinanceHistoryPassThrough
    public var financingLeg: Bool

    public init(
        internalTransfer: Bool = false,
        passThrough: FinanceHistoryPassThrough = .none,
        financingLeg: Bool = false
    ) {
        self.internalTransfer = internalTransfer
        self.passThrough = passThrough
        self.financingLeg = financingLeg
    }
}

/// Whether a movement belongs economically to somebody else. `partial`
/// preserves mixed-ownership rows without collapsing them to a Boolean.
public enum FinanceHistoryPassThrough: String, Codable, Hashable, Sendable, CaseIterable {
    case none
    case full
    case partial
}

public struct FinanceHistoryLinks: Codable, Hashable, Sendable {
    public var crossInstitutionPair: String?
    public var refundID: String?
    public var purchaseID: String?
    public var financingID: String?
    public var confirmationID: String?

    /// General-purpose stable transaction/group links retained for archive
    /// sources that already carry those relationships.
    public var linkedTransactionID: String?
    public var groupID: String?

    public init(
        crossInstitutionPair: String? = nil,
        refundID: String? = nil,
        purchaseID: String? = nil,
        financingID: String? = nil,
        confirmationID: String? = nil,
        linkedTransactionID: String? = nil,
        groupID: String? = nil
    ) {
        self.crossInstitutionPair = crossInstitutionPair
        self.refundID = refundID
        self.purchaseID = purchaseID
        self.financingID = financingID
        self.confirmationID = confirmationID
        self.linkedTransactionID = linkedTransactionID
        self.groupID = groupID
    }
}

public struct FinanceHistoryEvidence: Codable, Hashable, Sendable {
    public var ruleID: String
    public var basis: String
    public var unresolvedReason: String?

    public init(ruleID: String, basis: String, unresolvedReason: String? = nil) {
        self.ruleID = ruleID
        self.basis = basis
        self.unresolvedReason = unresolvedReason
    }
}

public struct FinanceHistoricalRecord: Codable, Hashable, Sendable {
    public var historicalID: String
    public var date: Day
    public var accountID: String
    public var provider: String
    public var rail: String
    public var merchant: String?
    public var description: String
    public var rawDescription: String?

    public var originalAmount: FinanceHistoryOriginalAmount
    public var bookedAmountEURCents: Int64?
    public var economicAmountEURCents: Int64?
    public var personalAmountEURCents: Int64?

    public var category: FinanceHistoryCategory

    /// Canonical evidence vocabularies are strings by design. They include
    /// more forensic distinctions than the live `TransactionKind` enum and
    /// must survive export without lossy remapping.
    public var economicType: String

    /// Where the money came from economically, independent of the rail
    /// counterparty and strictly finer than `category` and `economicType`.
    /// Support handed on by a family intermediary keeps the parental source
    /// even though the bank counterparty is the intermediary, and an arrival
    /// the reconstruction could not resolve stays unresolved. `nil` means the
    /// canonical layer states no source, never "unclassified support".
    public var economicSource: String?
    public var status: String
    public var provenance: String
    public var confidence: String
    public var flags: FinanceHistoryFlags
    public var economicViewRole: String
    public var links: FinanceHistoryLinks
    public var evidence: FinanceHistoryEvidence

    public init(
        historicalID: String,
        date: Day,
        accountID: String,
        provider: String,
        rail: String,
        merchant: String? = nil,
        description: String,
        rawDescription: String? = nil,
        originalAmount: FinanceHistoryOriginalAmount,
        bookedAmountEURCents: Int64? = nil,
        economicAmountEURCents: Int64? = nil,
        personalAmountEURCents: Int64? = nil,
        category: FinanceHistoryCategory,
        economicType: String,
        economicSource: String? = nil,
        status: String,
        provenance: String,
        confidence: String,
        flags: FinanceHistoryFlags = FinanceHistoryFlags(),
        economicViewRole: String,
        links: FinanceHistoryLinks = FinanceHistoryLinks(),
        evidence: FinanceHistoryEvidence
    ) {
        self.historicalID = historicalID
        self.date = date
        self.accountID = accountID
        self.provider = provider
        self.rail = rail
        self.merchant = merchant
        self.description = description
        self.rawDescription = rawDescription
        self.originalAmount = originalAmount
        self.bookedAmountEURCents = bookedAmountEURCents
        self.economicAmountEURCents = economicAmountEURCents
        self.personalAmountEURCents = personalAmountEURCents
        self.category = category
        self.economicType = economicType
        self.economicSource = economicSource
        self.status = status
        self.provenance = provenance
        self.confidence = confidence
        self.flags = flags
        self.economicViewRole = economicViewRole
        self.links = links
        self.evidence = evidence
    }

    /// Precomputed candidate text for an indexed/persisted normalized search
    /// column. Importers should compute this once, not on every keystroke.
    public func normalizedSearchText(accountName: String? = nil) -> String {
        FinanceHistorySearchNormalization.joining([
            merchant,
            description,
            rawDescription,
            category.top,
            category.sub,
            accountName,
            provider,
        ])
    }
}

private enum FinanceHistoryOrdering {
    static func accounts(_ lhs: FinanceHistoryAccount, _ rhs: FinanceHistoryAccount) -> Bool {
        (lhs.id, lhs.provider, lhs.name) < (rhs.id, rhs.provider, rhs.name)
    }

    static func records(_ lhs: FinanceHistoricalRecord, _ rhs: FinanceHistoricalRecord) -> Bool {
        (lhs.historicalID, lhs.date, lhs.accountID) < (rhs.historicalID, rhs.date, rhs.accountID)
    }

    static func gaps(_ lhs: FinanceHistorySourceGap, _ rhs: FinanceHistorySourceGap) -> Bool {
        if lhs.startMonth != rhs.startMonth { return lhs.startMonth < rhs.startMonth }
        if lhs.endMonth != rhs.endMonth { return lhs.endMonth < rhs.endMonth }
        if lhs.completeness != rhs.completeness { return lhs.completeness < rhs.completeness }
        return lhs.message < rhs.message
    }
}

/// Case-, width-, and diacritic-insensitive normalization suitable for a
/// persisted search index. Punctuation and repeated whitespace collapse to a
/// single ASCII space (`"Crédit—Uber"` -> `"credit uber"`).
public enum FinanceHistorySearchNormalization {
    private static let locale = Locale(identifier: "en_US_POSIX")

    public static func normalize(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: locale
        ).lowercased(with: locale)

        var result = ""
        var needsSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if needsSpace, !result.isEmpty { result.append(" ") }
                result.unicodeScalars.append(scalar)
                needsSpace = false
            } else {
                needsSpace = true
            }
        }
        return result
    }

    public static func joining(_ values: [String?]) -> String {
        var seen: Set<String> = []
        var parts: [String] = []
        for value in values.compactMap({ $0 }) {
            let normalized = normalize(value)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            parts.append(normalized)
        }
        return parts.joined(separator: " ")
    }
}

public struct FinanceHistoryValidationIssue: Codable, Hashable, Sendable {
    public var code: String
    public var path: String
    public var message: String

    public init(code: String, path: String, message: String) {
        self.code = code
        self.path = path
        self.message = message
    }
}

public struct FinanceHistoryValidationError: Error, Hashable, Sendable, CustomStringConvertible {
    public var issues: [FinanceHistoryValidationIssue]

    public init(issues: [FinanceHistoryValidationIssue]) {
        self.issues = issues
    }

    public var description: String {
        issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
    }
}

public struct FinanceHistorySchemaError: Error, Hashable, Sendable, CustomStringConvertible {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var description: String { "\(path): \(message)" }
}

public enum FinanceHistoryInterchange {
    public static let currentSchemaVersion = "2.0.0"
    public static let documentKind = "finance-history-archive"

    /// 1.1.0 only adds the optional `economicSource` record field, so an
    /// archive exported before the economic-source dimension existed still
    /// imports and simply has no source to filter on. 2.0.0 changes the
    /// representation of an existing value — the original amount carries its
    /// currency exponent explicitly — which is a major version by this
    /// project's semver rule.
    public static let readableSchemaVersions: Set<String> = ["1.0.0", "1.1.0", "2.0.0"]

    /// Which monetary grammar a declared version speaks, or `nil` when the
    /// version is not readable by this build.
    ///
    /// 1.0.0 and 1.1.0 deliberately share one historical body grammar. That
    /// grammar has always tolerated a 1.0.0 document carrying `economicSource`,
    /// and this monetary repair does not tighten it: retroactively rejecting
    /// archives that already decode would be a different, breaking change.
    public static func monetaryWire(for schemaVersion: String) -> FinanceHistoryMonetaryWire? {
        switch schemaVersion {
        case "1.0.0", "1.1.0": return .legacyV1
        case "2.0.0": return .v2
        default: return nil
        }
    }

    public static func encoder() -> JSONEncoder { encoder(for: currentSchemaVersion) }

    /// An encoder bound to one version's monetary grammar.
    ///
    /// Misuse is refused rather than prevented by convention: encoding a
    /// document whose `schemaVersion` speaks a different grammar throws, because
    /// `FinanceHistoryDocument.encode(to:)` checks this encoder's grammar
    /// against its own declared version first.
    public static func encoder(for schemaVersion: String) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // No grammar is stated for a version this build cannot read, so the
        // document's own guard refuses rather than falling back to a default.
        encoder.userInfo[.financeHistoryMonetaryWire] = monetaryWire(for: schemaVersion)
        return encoder
    }

    public static func decoder() -> JSONDecoder { decoder(for: currentSchemaVersion) }

    public static func decoder(for schemaVersion: String) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[.financeHistoryMonetaryWire] = monetaryWire(for: schemaVersion)
        return decoder
    }

    /// Creates a correctly versioned document and binds the exact payload to
    /// its SHA-256 digest.
    public static func make(
        archiveID: String,
        sourceRevision: String,
        payload: FinanceHistoryPayload
    ) throws -> FinanceHistoryDocument {
        let payload = canonicalized(payload)
        let document = FinanceHistoryDocument(
            schemaVersion: currentSchemaVersion,
            documentKind: documentKind,
            archiveID: archiveID,
            sourceRevision: sourceRevision,
            contentSHA256: try contentSHA256(for: payload, schemaVersion: currentSchemaVersion),
            payload: payload
        )
        try validate(document)
        return document
    }

    /// Encoding is validation-gated so malformed private archives cannot be
    /// produced accidentally by another Swift caller.
    public static func encode(_ document: FinanceHistoryDocument) throws -> Data {
        try validate(document)
        // The body grammar comes from the document's own declared version, so
        // an envelope and a body can never disagree on the way out.
        return try encoder(for: document.schemaVersion).encode(document)
    }

    /// Decoding resolves the version first, then rejects unknown fields for
    /// that version's grammar, then applies cross-field semantic validation
    /// (including the payload hash).
    ///
    /// Version comes first on purpose: an unreadable future archive reports an
    /// unsupported *version* rather than a confusing monetary-shape error.
    public static func decode(_ data: Data) throws -> FinanceHistoryDocument {
        let declaredVersion = try declaredSchemaVersion(in: data)
        guard let wire = monetaryWire(for: declaredVersion) else {
            throw FinanceHistoryValidationError(issues: [
                FinanceHistoryValidationIssue(
                    code: "unsupported_schema_version",
                    path: "schemaVersion",
                    message: "expected one of \(readableSchemaVersions.sorted().joined(separator: ", "))"
                )
            ])
        }
        try FinanceHistoryStrictJSONSchema.validate(data, wire: wire)
        let document = try decoder(for: declaredVersion).decode(FinanceHistoryDocument.self, from: data)
        try validate(document)
        return document
    }

    /// Reads only the version out of the envelope, without interpreting the
    /// body, so an unsupported version is never diagnosed as a malformed body.
    private static func declaredSchemaVersion(in data: Data) throws -> String {
        let rootValue: Any
        do {
            rootValue = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw FinanceHistorySchemaError(path: "$", message: "invalid JSON: \(error.localizedDescription)")
        }
        guard let root = rootValue as? [String: Any] else {
            throw FinanceHistorySchemaError(path: "$", message: "expected object")
        }
        guard let version = root["schemaVersion"] as? String else {
            throw FinanceHistorySchemaError(path: "$.schemaVersion", message: "missing required field")
        }
        return version
    }

    public static func decodeValidated(_ data: Data) throws -> FinanceHistoryDocument {
        try decode(data)
    }

    public static func contentSHA256(for payload: FinanceHistoryPayload) throws -> String {
        try contentSHA256(for: payload, schemaVersion: currentSchemaVersion)
    }

    /// The digest covers the canonical compact payload bytes *as that version
    /// writes them*, so a 1.x payload hashes its 1.x form and a 2.0.0 payload
    /// hashes its explicit-exponent form. The scope is unchanged: still the
    /// payload only, never the envelope.
    public static func contentSHA256(
        for payload: FinanceHistoryPayload,
        schemaVersion: String
    ) throws -> String {
        let data = try canonicalPayloadEncoder(for: schemaVersion).encode(payload)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func validate(_ document: FinanceHistoryDocument) throws {
        var issues: [FinanceHistoryValidationIssue] = []
        func issue(_ code: String, _ path: String, _ message: String) {
            issues.append(FinanceHistoryValidationIssue(code: code, path: path, message: message))
        }

        let wire = monetaryWire(for: document.schemaVersion)
        if wire == nil {
            issue(
                "unsupported_schema_version",
                "schemaVersion",
                "expected one of \(readableSchemaVersions.sorted().joined(separator: ", "))"
            )
        }
        if document.documentKind != documentKind {
            issue("wrong_document_kind", "documentKind", "expected \(documentKind)")
        }
        if !isSafeIdentifier(document.archiveID, maximumLength: 160) {
            issue("unsafe_archive_id", "archiveID", "must be a non-secret stable identifier")
        }
        if !isSafeText(document.sourceRevision, maximumLength: 256) {
            issue("invalid_source_revision", "sourceRevision", "must be non-empty printable text")
        }
        if !isLowercaseSHA256(document.contentSHA256) {
            issue("invalid_content_hash", "contentSHA256", "must be 64 lowercase hexadecimal characters")
        } else if let expected = try? contentSHA256(for: document.payload, schemaVersion: document.schemaVersion),
                  expected != document.contentSHA256 {
            issue("content_hash_mismatch", "contentSHA256", "does not match the canonical payload")
        }

        let payload = document.payload
        if payload.recordCount != payload.records.count {
            issue("record_count_mismatch", "payload.recordCount", "declares \(payload.recordCount), contains \(payload.records.count)")
        }
        if payload.records.isEmpty {
            issue("empty_archive", "payload.records", "a history archive must contain at least one record")
        } else {
            let dates = payload.records.map(\.date)
            if payload.dateRange.start != dates.min() {
                issue("date_range_mismatch", "payload.dateRange.start", "must equal the earliest record date")
            }
            if payload.dateRange.end != dates.max() {
                issue("date_range_mismatch", "payload.dateRange.end", "must equal the latest record date")
            }
        }
        if payload.dateRange.start > payload.dateRange.end {
            issue("invalid_date_range", "payload.dateRange", "start must not follow end")
        }
        if payload.dateRange.end > payload.archiveCutoff {
            issue("range_after_cutoff", "payload.dateRange.end", "must be on or before archiveCutoff")
        }

        var accountIDs: Set<String> = []
        var accountsByID: [String: FinanceHistoryAccount] = [:]
        for (index, account) in payload.accounts.enumerated() {
            let path = "payload.accounts[\(index)]"
            if !accountIDs.insert(account.id).inserted {
                issue("duplicate_account_id", "\(path).id", "duplicate account id \(account.id)")
            }
            accountsByID[account.id] = account
            if !isSafeIdentifier(account.id, maximumLength: 128) || looksLikeSensitiveAccountIdentifier(account.id) {
                issue("unsafe_account_id", "\(path).id", "must be an opaque app id, never an account number or IBAN")
            }
            if !isSafeText(account.name, maximumLength: 128) || looksLikeSensitiveAccountIdentifier(account.name) {
                issue("unsafe_account_name", "\(path).name", "must be a safe display name without an account number or IBAN")
            }
            if !isSafeControlledValue(account.provider, maximumLength: 80) {
                issue("invalid_provider", "\(path).provider", "must be a safe provider token")
            }
        }

        var recordIDs: Set<String> = []
        for (index, record) in payload.records.enumerated() {
            let path = "payload.records[\(index)]"
            if !recordIDs.insert(record.historicalID).inserted {
                issue("duplicate_historical_id", "\(path).historicalID", "duplicate stable id \(record.historicalID)")
            }
            if !isSafeIdentifier(record.historicalID, maximumLength: 256) {
                issue("invalid_historical_id", "\(path).historicalID", "must be a non-empty stable identifier")
            }
            if record.date > payload.archiveCutoff {
                issue("record_after_cutoff", "\(path).date", "archive rows must be on or before \(payload.archiveCutoff)")
            }
            guard let account = accountsByID[record.accountID] else {
                issue("unknown_account", "\(path).accountID", "does not reference payload.accounts")
                validateRecord(record, path: path, wire: wire ?? .v2, issue: issue)
                continue
            }
            if record.provider != account.provider {
                issue("provider_mismatch", "\(path).provider", "must match the referenced account provider")
            }
            validateRecord(record, path: path, wire: wire ?? .v2, issue: issue)
        }

        for (index, gap) in payload.sourceGaps.enumerated() {
            let path = "payload.sourceGaps[\(index)]"
            if gap.startMonth > gap.endMonth {
                issue("invalid_gap_range", path, "startMonth must not follow endMonth")
            }
            if gap.endMonth > payload.archiveCutoff.monthKey {
                issue("gap_after_cutoff", "\(path).endMonth", "must not extend beyond the archive cutoff month")
            }
            if !isSafeControlledValue(gap.completeness, maximumLength: 120) {
                issue("invalid_gap_completeness", "\(path).completeness", "must be a non-empty controlled value")
            }
            if gap.affectedSources.isEmpty {
                issue("empty_gap_sources", "\(path).affectedSources", "must name at least one affected source")
            }
            var sources: Set<String> = []
            for (sourceIndex, source) in gap.affectedSources.enumerated() {
                if !sources.insert(source).inserted {
                    issue("duplicate_gap_source", "\(path).affectedSources[\(sourceIndex)]", "duplicate source \(source)")
                }
                if !isSafeControlledValue(source, maximumLength: 120) {
                    issue("invalid_gap_source", "\(path).affectedSources[\(sourceIndex)]", "must be a safe source token")
                }
            }
            if !isSafeText(gap.message, maximumLength: 1_000) {
                issue("invalid_gap_message", "\(path).message", "must be non-empty printable text")
            }
        }

        if !issues.isEmpty { throw FinanceHistoryValidationError(issues: issues) }
    }

    private static func canonicalPayloadEncoder(for schemaVersion: String) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.userInfo[.financeHistoryMonetaryWire] = monetaryWire(for: schemaVersion)
        return encoder
    }

    private static func validateRecord(
        _ record: FinanceHistoricalRecord,
        path: String,
        wire: FinanceHistoryMonetaryWire,
        issue: (_ code: String, _ path: String, _ message: String) -> Void
    ) {
        if !isSafeIdentifier(record.accountID, maximumLength: 128) {
            issue("invalid_account_id", "\(path).accountID", "must be a safe account id")
        }
        if !isSafeControlledValue(record.provider, maximumLength: 80) {
            issue("invalid_provider", "\(path).provider", "must be a safe provider token")
        }
        if !isSafeControlledValue(record.rail, maximumLength: 80) {
            issue("invalid_rail", "\(path).rail", "must be a non-empty controlled value")
        }
        validateOptionalText(record.merchant, path: "\(path).merchant", maximumLength: 512, issue: issue)
        if !isSafeText(record.description, maximumLength: 1_000) {
            issue("invalid_description", "\(path).description", "must be non-empty printable text")
        }
        validateOptionalText(record.rawDescription, path: "\(path).rawDescription", maximumLength: 4_096, issue: issue)

        let amount = record.originalAmount
        let amountKey = wire == .v2 ? "minorUnits" : "cents"
        if !Currency.isValidCode(amount.currency) {
            issue("invalid_currency", "\(path).originalAmount.currency", "must be three uppercase ASCII letters")
        }
        if !(0...6).contains(amount.currencyExponent) {
            issue(
                "invalid_currency_exponent",
                "\(path).originalAmount.currency.exponent",
                "must be an integer in 0...6"
            )
        }
        if wire == .legacyV1, !amount.isRepresentableInLegacyV1 {
            // A 1.x archive has no place to put an exponent, so it may only
            // state an identity the frozen table already implies.
            issue(
                "not_representable_in_legacy_version",
                "\(path).originalAmount.currency",
                "\(amount.currency)/\(amount.currencyExponent) needs schema 2.0.0"
            )
        }
        if amount.cents == .min {
            issue(
                "invalid_amount",
                "\(path).originalAmount.\(amountKey)",
                "Int64.min cannot be safely converted to a magnitude"
            )
        }
        for (name, value) in [
            ("bookedAmountEURCents", record.bookedAmountEURCents),
            ("economicAmountEURCents", record.economicAmountEURCents),
            ("personalAmountEURCents", record.personalAmountEURCents),
        ] where value == .min {
            issue("invalid_amount", "\(path).\(name)", "Int64.min cannot be safely converted to a magnitude")
        }
        validateEURConsistency(record, path: path, wire: wire, issue: issue)
        if !isSafeText(record.category.top, maximumLength: 160) {
            issue("invalid_category", "\(path).category.top", "must be non-empty printable text")
        }
        validateOptionalText(record.category.sub, path: "\(path).category.sub", maximumLength: 160, issue: issue)
        if let economicSource = record.economicSource,
           !isSafeControlledValue(economicSource, maximumLength: 120) {
            issue("invalid_controlled_value", "\(path).economicSource", "must be a non-empty safe token")
        }
        for (name, value) in [
            ("economicType", record.economicType),
            ("status", record.status),
            ("provenance", record.provenance),
            ("confidence", record.confidence),
            ("economicViewRole", record.economicViewRole),
        ] where !isSafeControlledValue(value, maximumLength: 120) {
            issue("invalid_controlled_value", "\(path).\(name)", "must be a non-empty safe token")
        }

        let links: [(String, String?)] = [
            ("crossInstitutionPair", record.links.crossInstitutionPair),
            ("refundID", record.links.refundID),
            ("purchaseID", record.links.purchaseID),
            ("financingID", record.links.financingID),
            ("confirmationID", record.links.confirmationID),
            ("linkedTransactionID", record.links.linkedTransactionID),
            ("groupID", record.links.groupID),
        ]
        for (name, value) in links where value != nil && !isSafeIdentifier(value!, maximumLength: 256) {
            issue("invalid_link_id", "\(path).links.\(name)", "must be a safe stable identifier")
        }
        if !isSafeIdentifier(record.evidence.ruleID, maximumLength: 160) {
            issue("invalid_rule_id", "\(path).evidence.ruleID", "must be a non-empty stable rule id")
        }
        if !isSafeText(record.evidence.basis, maximumLength: 4_096) {
            issue("invalid_evidence_basis", "\(path).evidence.basis", "must be non-empty printable text")
        }
        validateOptionalText(
            record.evidence.unresolvedReason,
            path: "\(path).evidence.unresolvedReason",
            maximumLength: 2_048,
            issue: issue
        )
    }

    /// The booked EUR amount must agree with an original EUR amount.
    ///
    /// 1.x froze this as raw integer equality, because a 1.x original EUR
    /// amount is always EUR/2 — the frozen table says so and nothing on the
    /// wire can disagree. 2.0.0 lets an original EUR amount state any valid
    /// exponent, so the rule becomes what it always meant: the two must be the
    /// same *value*, compared exactly at EUR/2. Never rounded, never rescaled
    /// into agreement.
    private static func validateEURConsistency(
        _ record: FinanceHistoricalRecord,
        path: String,
        wire: FinanceHistoryMonetaryWire,
        issue: (_ code: String, _ path: String, _ message: String) -> Void
    ) {
        let amount = record.originalAmount
        guard amount.currency == "EUR", let booked = record.bookedAmountEURCents else { return }
        let bookedPath = "\(path).bookedAmountEURCents"

        guard wire == .v2 else {
            if booked != amount.cents {
                issue("inconsistent_eur_amount", bookedPath, "must equal original cents for an original EUR amount")
            }
            return
        }
        guard (0...6).contains(amount.currencyExponent) else { return }

        switch amount.currencyExponent {
        case 2:
            if booked != amount.cents {
                issue("inconsistent_eur_amount", bookedPath, "must equal the original EUR amount at EUR/2")
            }
        case let exponent where exponent < 2:
            var scaled = amount.cents
            for _ in 0..<(2 - exponent) {
                let (next, overflow) = scaled.multipliedReportingOverflow(by: 10)
                guard !overflow else {
                    issue(
                        "inconsistent_eur_amount",
                        bookedPath,
                        "original EUR/\(exponent) amount overflows Int64 at EUR/2"
                    )
                    return
                }
                scaled = next
            }
            if booked != scaled {
                issue("inconsistent_eur_amount", bookedPath, "must equal the original EUR amount at EUR/2")
            }
        default:
            let exponent = amount.currencyExponent
            var factor: Int64 = 1
            for _ in 0..<(exponent - 2) { factor *= 10 }
            guard amount.cents % factor == 0 else {
                // Exact or nothing: a sub-cent EUR original has no integer
                // EUR/2 booked value, and inventing one would be rounding.
                issue(
                    "inconsistent_eur_amount",
                    bookedPath,
                    "original EUR/\(exponent) amount is not exactly representable at EUR/2"
                )
                return
            }
            if booked != amount.cents / factor {
                issue("inconsistent_eur_amount", bookedPath, "must equal the original EUR amount at EUR/2")
            }
        }
    }

    private static func validateOptionalText(
        _ value: String?,
        path: String,
        maximumLength: Int,
        issue: (_ code: String, _ path: String, _ message: String) -> Void
    ) {
        guard let value else { return }
        if !isSafeText(value, maximumLength: maximumLength) {
            issue("invalid_text", path, "when present, must be non-empty printable text")
        }
    }

    private static func isSafeIdentifier(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maximumLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (
                CharacterSet.alphanumerics.contains(scalar)
                || "-_.:/#".unicodeScalars.contains(scalar)
            )
        }
    }

    private static func isSafeControlledValue(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maximumLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (
                CharacterSet.alphanumerics.contains(scalar)
                || "-_./".unicodeScalars.contains(scalar)
            )
        }
    }

    private static func isSafeText(_ value: String, maximumLength: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, value.count <= maximumLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) || scalar == "\t"
        }
    }

    private static func looksLikeSensitiveAccountIdentifier(_ value: String) -> Bool {
        let compact = value.uppercased().filter { $0.isASCII && $0.isLetter || $0.isNumber }
        if compact.count >= 15,
           compact.prefix(2).allSatisfy({ $0.isLetter }),
           compact.dropFirst(2).prefix(2).allSatisfy({ $0.isNumber }),
           compact.dropFirst(4).allSatisfy({ $0.isLetter || $0.isNumber }) {
            return true
        }
        var consecutiveDigits = 0
        for character in value {
            consecutiveDigits = character.isNumber ? consecutiveDigits + 1 : 0
            if consecutiveDigits >= 10 { return true }
        }
        return false
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
    }

    private static func canonicalized(_ payload: FinanceHistoryPayload) -> FinanceHistoryPayload {
        var payload = payload
        payload.accounts.sort(by: FinanceHistoryOrdering.accounts)
        payload.records.sort(by: FinanceHistoryOrdering.records)
        for index in payload.sourceGaps.indices {
            payload.sourceGaps[index].affectedSources.sort()
        }
        payload.sourceGaps.sort(by: FinanceHistoryOrdering.gaps)
        return payload
    }
}

private enum FinanceHistoryStrictJSONSchema {
    /// The record key set is deliberately identical for both grammars, so the
    /// historical tolerance of a 1.0.0 document carrying `economicSource`
    /// survives this change. Only the original-amount body differs by version.
    static func validate(_ data: Data, wire: FinanceHistoryMonetaryWire) throws {
        let rootValue: Any
        do {
            rootValue = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw FinanceHistorySchemaError(path: "$", message: "invalid JSON: \(error.localizedDescription)")
        }
        let root = try object(rootValue, at: "$")
        try keys(
            root,
            required: ["schemaVersion", "documentKind", "archiveID", "sourceRevision", "contentSHA256", "payload"],
            optional: [],
            at: "$"
        )
        let payload = try childObject(root, key: "payload", at: "$")
        try keys(
            payload,
            required: ["archiveCutoff", "recordCount", "dateRange", "accounts", "sourceGaps", "records"],
            optional: [],
            at: "$.payload"
        )

        let dateRange = try childObject(payload, key: "dateRange", at: "$.payload")
        try keys(dateRange, required: ["start", "end"], optional: [], at: "$.payload.dateRange")

        for (index, value) in try childArray(payload, key: "accounts", at: "$.payload").enumerated() {
            let path = "$.payload.accounts[\(index)]"
            try keys(try object(value, at: path), required: ["id", "name", "provider"], optional: [], at: path)
        }
        for (index, value) in try childArray(payload, key: "sourceGaps", at: "$.payload").enumerated() {
            let path = "$.payload.sourceGaps[\(index)]"
            try keys(
                try object(value, at: path),
                required: ["startMonth", "endMonth", "completeness", "affectedSources", "message"],
                optional: [],
                at: path
            )
        }
        for (index, value) in try childArray(payload, key: "records", at: "$.payload").enumerated() {
            let path = "$.payload.records[\(index)]"
            let record = try object(value, at: path)
            try keys(
                record,
                required: [
                    "historicalID", "date", "accountID", "provider", "rail", "description", "originalAmount",
                    "category", "economicType", "status", "provenance", "confidence", "flags", "economicViewRole",
                    "links", "evidence",
                ],
                optional: [
                    "merchant", "rawDescription", "bookedAmountEURCents", "economicAmountEURCents",
                    "personalAmountEURCents", "economicSource",
                ],
                at: path
            )
            let originalAmount = try childObject(record, key: "originalAmount", at: path)
            let originalAmountPath = "\(path).originalAmount"
            switch wire {
            case .legacyV1:
                try keys(
                    originalAmount,
                    required: ["cents", "currency"], optional: [], at: originalAmountPath
                )
            case .v2:
                try keys(
                    originalAmount,
                    required: ["minorUnits", "currency"], optional: [], at: originalAmountPath
                )
                // `exponent` is required: 2.0.0 never defaults it.
                try keys(
                    try childObject(originalAmount, key: "currency", at: originalAmountPath),
                    required: ["code", "exponent"], optional: [], at: "\(originalAmountPath).currency"
                )
            }
            try keys(
                try childObject(record, key: "category", at: path),
                required: ["top"], optional: ["sub"], at: "\(path).category"
            )
            try keys(
                try childObject(record, key: "flags", at: path),
                required: ["internalTransfer", "passThrough", "financingLeg"], optional: [], at: "\(path).flags"
            )
            try keys(
                try childObject(record, key: "links", at: path),
                required: [],
                optional: [
                    "crossInstitutionPair", "refundID", "purchaseID", "financingID", "confirmationID",
                    "linkedTransactionID", "groupID",
                ],
                at: "\(path).links"
            )
            try keys(
                try childObject(record, key: "evidence", at: path),
                required: ["ruleID", "basis"], optional: ["unresolvedReason"], at: "\(path).evidence"
            )
        }
    }

    private static func object(_ value: Any, at path: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw FinanceHistorySchemaError(path: path, message: "expected object")
        }
        return object
    }

    private static func childObject(_ parent: [String: Any], key: String, at path: String) throws -> [String: Any] {
        guard let value = parent[key] else {
            throw FinanceHistorySchemaError(path: "\(path).\(key)", message: "missing required field")
        }
        return try object(value, at: "\(path).\(key)")
    }

    private static func childArray(_ parent: [String: Any], key: String, at path: String) throws -> [Any] {
        guard let value = parent[key] else {
            throw FinanceHistorySchemaError(path: "\(path).\(key)", message: "missing required field")
        }
        guard let array = value as? [Any] else {
            throw FinanceHistorySchemaError(path: "\(path).\(key)", message: "expected array")
        }
        return array
    }

    private static func keys(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String>,
        at path: String
    ) throws {
        let actual = Set(object.keys)
        if let missing = required.subtracting(actual).sorted().first {
            throw FinanceHistorySchemaError(path: "\(path).\(missing)", message: "missing required field")
        }
        if let unknown = actual.subtracting(required.union(optional)).sorted().first {
            throw FinanceHistorySchemaError(path: "\(path).\(unknown)", message: "unknown field for a readable schema version")
        }
    }
}
