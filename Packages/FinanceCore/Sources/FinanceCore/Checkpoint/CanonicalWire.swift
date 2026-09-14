import Foundation

/// Privacy-safe failures: never include source payload, identifiers or money.
public enum SemanticProjectionFormatError: Error, Equatable, Sendable {
    case malformed
    case truncated
    case invalidInteger
    case invalidLength
    case invalidUTF8
    case unknownToken
    case unsupportedVersion
    case invalidCurrency
    case invalidDay
    case invalidInterval
    case nonCanonical
    case trailingBytes
    case resourceLimit
    case invalidDigest
    case invalidRevision
}

/// Internal wire syntax, independent of Swift property names and Codable.
/// V1 tokens and positional record layouts are frozen in CanonicalProjectionV1.
indirect enum CheckpointWire: Equatable {
    case string(String)
    case integer(Int64)
    case bool(Bool)
    case absent
    case present(CheckpointWire)
    case array([CheckpointWire])
    case record(String, [CheckpointWire])

    var bytes: [UInt8] {
        switch self {
        case let .string(value):
            let bytes = Array(value.precomposedStringWithCanonicalMapping.utf8)
            return Array("s\(bytes.count):".utf8) + bytes
        case let .integer(value):
            let text = String(value)
            return Array("i\(text.utf8.count):\(text)".utf8)
        case let .bool(value): return Array((value ? "b1" : "b0").utf8)
        case .absent: return [110]
        case let .present(value): return [112] + value.bytes
        case let .array(values):
            return Array("a\(values.count):".utf8) + values.flatMap(\.bytes)
        case let .record(tag, values):
            return [114] + CheckpointWire.string(tag).bytes + CheckpointWire.array(values).bytes
        }
    }

    static func optional<T>(_ value: T?, _ encode: (T) throws -> Self) rethrows -> Self {
        try value.map { .present(try encode($0)) } ?? .absent
    }

    /// Full semantic-field total order; never relies on the projection's
    /// identity-only Comparable implementations. Equal keys mean equal bytes.
    static func sorted(_ values: [Self]) -> Self {
        .array(values.map { ($0, $0.bytes) }.sorted { $0.1.lexicographicallyPrecedes($1.1) }.map(\.0))
    }

    func fields(_ tag: String, _ count: Int) throws -> [Self] {
        guard case let .record(actual, values) = self, actual == tag, values.count == count else {
            throw SemanticProjectionFormatError.unknownToken
        }
        return values
    }
    func text() throws -> String {
        guard case let .string(value) = self else { throw SemanticProjectionFormatError.malformed }
        return value
    }
    func int() throws -> Int64 {
        guard case let .integer(value) = self else { throw SemanticProjectionFormatError.invalidInteger }
        return value
    }
    func boolean() throws -> Bool {
        guard case let .bool(value) = self else { throw SemanticProjectionFormatError.malformed }
        return value
    }
    func list<T>(_ decode: (Self) throws -> T) throws -> [T] {
        guard case let .array(values) = self else { throw SemanticProjectionFormatError.malformed }
        return try values.map(decode)
    }
    func optional<T>(_ decode: (Self) throws -> T) throws -> T? {
        switch self {
        case .absent: return nil
        case let .present(value): return try decode(value)
        default: throw SemanticProjectionFormatError.malformed
        }
    }
}

struct CheckpointWireReader {
    let bytes: [UInt8]
    var offset = 0

    mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw SemanticProjectionFormatError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func length() throws -> Int {
        var result = 0
        var digits = 0
        var first: UInt8 = 0
        while true {
            let b = try byte()
            if b == 58 {
                guard digits > 0, digits == 1 || first != 48 else {
                    throw SemanticProjectionFormatError.invalidLength
                }
                return result
            }
            guard (48...57).contains(b) else { throw SemanticProjectionFormatError.invalidLength }
            if digits == 0 { first = b }
            digits += 1
            let (scaled, overflow1) = result.multipliedReportingOverflow(by: 10)
            let (added, overflow2) = scaled.addingReportingOverflow(Int(b - 48))
            guard !overflow1, !overflow2 else { throw SemanticProjectionFormatError.invalidLength }
            result = added
        }
    }

    mutating func value(depth: Int = 0) throws -> CheckpointWire {
        guard depth < 32 else { throw SemanticProjectionFormatError.resourceLimit }
        switch try byte() {
        case 115, 105:
            let tag = bytes[offset - 1]
            let count = try length()
            guard count <= bytes.count - offset else { throw SemanticProjectionFormatError.truncated }
            guard let text = String(bytes: bytes[offset..<(offset + count)], encoding: .utf8) else {
                throw SemanticProjectionFormatError.invalidUTF8
            }
            offset += count
            if tag == 115 { return .string(text) }
            guard let integer = Int64(text), String(integer) == text else {
                throw SemanticProjectionFormatError.invalidInteger
            }
            return .integer(integer)
        case 98:
            switch try byte() {
            case 48: return .bool(false)
            case 49: return .bool(true)
            default: throw SemanticProjectionFormatError.malformed
            }
        case 110: return .absent
        case 112: return .present(try value(depth: depth + 1))
        case 97:
            let count = try length()
            // Every child consumes at least one byte. No allocation from an
            // attacker-controlled count before checking against remaining input.
            guard count <= bytes.count - offset else { throw SemanticProjectionFormatError.invalidLength }
            var values: [CheckpointWire] = []
            for _ in 0..<count { values.append(try value(depth: depth + 1)) }
            return .array(values)
        case 114:
            let tag = try value(depth: depth + 1).text()
            let fields = try value(depth: depth + 1).list { $0 }
            return .record(tag, fields)
        default: throw SemanticProjectionFormatError.unknownToken
        }
    }
}
