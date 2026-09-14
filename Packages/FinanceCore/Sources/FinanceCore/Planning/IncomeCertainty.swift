import Foundation

/// How certain a prospective resource is. Ordered: `possible < target <
/// expected < guaranteed < received`.
///
/// The ladder exists so that planning can never quietly promote:
///
/// - a student job I intend to obtain (`target`) is not guaranteed income;
/// - possible CROUS emergency assistance (`possible`) is not cash;
/// - planned CAF eligibility (`expected`/`target`) is not received CAF;
/// - only `received` money is a fact — and facts are scenario-independent.
public enum IncomeCertainty: Int, Sendable, CaseIterable, Comparable {

    /// Contingent, has not even been requested/decided. Never enters any
    /// forecast unless a policy explicitly opts in.
    case possible = 1

    /// Intended but not obtained (e.g. an unsigned student job).
    case target = 2

    /// Realistically planned, dated, but not contracturally secured.
    case expected = 3

    /// Contractually/structurally secured, dated.
    case guaranteed = 4

    /// Actually received — an observed fact. Scenario-independent.
    case received = 5

    public static func < (lhs: IncomeCertainty, rhs: IncomeCertainty) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .possible: return "possible"
        case .target: return "target"
        case .expected: return "expected"
        case .guaranteed: return "guaranteed"
        case .received: return "received"
        }
    }
}

/// The interchange encodes the ladder as its self-describing labels, not as
/// the ordering integers — which are an internal detail and may never appear
/// in a persisted document.
extension IncomeCertainty: Codable {

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let match = IncomeCertainty.allCases.first(where: { $0.label == string }) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Unknown income certainty: '\(string)'")
            )
        }
        self = match
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(label)
    }
}

/// A planning scenario. Scenarios decide which **prospective** resources
/// qualify; they never modify observed facts.
public enum Scenario: String, Sendable, Codable, CaseIterable {
    /// Secured cash only. The floor a runway should be read from.
    case guaranteed
    /// The conservative realistic plan (includes `expected` resources).
    case base
    /// What-if analysis including `target` resources. Never the operating plan.
    case upside

    public var defaultPolicy: ScenarioPolicy {
        switch self {
        case .guaranteed: return ScenarioPolicy(minimumCertainty: .guaranteed, includesPossible: false)
        case .base:       return ScenarioPolicy(minimumCertainty: .expected, includesPossible: false)
        case .upside:     return ScenarioPolicy(minimumCertainty: .target, includesPossible: false)
        }
    }
}

/// The rule a scenario uses to admit prospective income.
///
/// `received` facts are always included — history is not scenario-dependent.
/// `possible` income is excluded from every scenario by default and enters
/// only when the user explicitly sets `includesPossible`.
public struct ScenarioPolicy: Hashable, Sendable, Codable {
    public var minimumCertainty: IncomeCertainty
    public var includesPossible: Bool

    public init(minimumCertainty: IncomeCertainty, includesPossible: Bool = false) {
        self.minimumCertainty = minimumCertainty
        self.includesPossible = includesPossible
    }

    public func includes(_ certainty: IncomeCertainty) -> Bool {
        if certainty == .received { return true }
        if certainty == .possible { return includesPossible }
        return certainty >= minimumCertainty
    }
}
