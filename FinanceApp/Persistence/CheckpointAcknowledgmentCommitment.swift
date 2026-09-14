import CryptoKit
import Foundation
import FinanceCore

/// Persistence-level commitment to one revision's accepted acknowledgment array.
///
/// This is **not** CanonicalProjection V1, not `projectionDigest`, and not a
/// cross-revision acknowledgment identity. It exists so a stored revision
/// cannot quietly lose, grow or reorder the exact array that was accepted:
/// quality and safe-claims bits are too coarse to notice, and the projection
/// digest never saw these records. Aggregate-pairing carry-forward remains
/// unresolved and must not be inferred from this hash.
///
/// ## Encoding (`finance-app/checkpoint-acknowledgments/v1`)
///
/// Explicit bytes, never `Codable` / `JSONEncoder`. Big-endian integers.
/// Strings are a `UInt32` length prefix followed by UTF-8. Optionals are a
/// `UInt8` flag (`0` absent, `1` present) and then the value.
///
/// ```
/// domain string
/// count  UInt64
/// for each record in accepted array order:
///   exception id            string
///   kind token              string
///   aggregate basis         optional string
///   day ordinal             optional Int32
///   amount minor units      optional Int64
///   amount currency code    optional string
///   amount currency exponent optional Int64
/// ```
///
/// Sequence numbers are storage indices, not payload. Order is the order of
/// records in this encoding. SHA-256 of the bytes is the 32-byte digest.
enum CheckpointAcknowledgmentCommitment {

    static let domain = "finance-app/checkpoint-acknowledgments/v1"

    /// One record's persisted semantic fields. Sequence is not included.
    struct Record: Equatable {
        var exceptionIdentifier: String
        var kindRaw: String
        var aggregateBasisRaw: String?
        var day: Int32?
        var amountMinor: Int64?
        var amountCurrencyCode: String?
        var amountCurrencyExponent: Int?
    }

    static func digest(of records: [AcknowledgedExceptionRecord]) throws -> Data {
        digest(of: try records.map(Record.init))
    }

    static func digest(of rows: [StoredPeriodCheckpointAcknowledgment]) -> Data {
        digest(of: rows.map(Record.init))
    }

    static func digest(of records: [Record]) -> Data {
        Data(SHA256.hash(data: Data(encode(records))))
    }

    static func encode(_ records: [Record]) -> [UInt8] {
        var bytes: [UInt8] = []
        appendString(domain, to: &bytes)
        appendUInt64(UInt64(records.count), to: &bytes)
        for record in records {
            appendString(record.exceptionIdentifier, to: &bytes)
            appendString(record.kindRaw, to: &bytes)
            appendOptionalString(record.aggregateBasisRaw, to: &bytes)
            appendOptionalInt32(record.day, to: &bytes)
            appendOptionalInt64(record.amountMinor, to: &bytes)
            appendOptionalString(record.amountCurrencyCode, to: &bytes)
            appendOptionalInt64(record.amountCurrencyExponent.map(Int64.init), to: &bytes)
        }
        return bytes
    }

    private static func appendOptionalString(_ value: String?, to bytes: inout [UInt8]) {
        guard let value else {
            bytes.append(0)
            return
        }
        bytes.append(1)
        appendString(value, to: &bytes)
    }

    private static func appendOptionalInt32(_ value: Int32?, to bytes: inout [UInt8]) {
        guard let value else {
            bytes.append(0)
            return
        }
        bytes.append(1)
        appendInt32(value, to: &bytes)
    }

    private static func appendOptionalInt64(_ value: Int64?, to bytes: inout [UInt8]) {
        guard let value else {
            bytes.append(0)
            return
        }
        bytes.append(1)
        appendInt64(value, to: &bytes)
    }

    private static func appendString(_ value: String, to bytes: inout [UInt8]) {
        let encoded = Array(value.utf8)
        appendUInt32(UInt32(encoded.count), to: &bytes)
        bytes.append(contentsOf: encoded)
    }

    private static func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendUInt64(_ value: UInt64, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 56))
        bytes.append(UInt8(truncatingIfNeeded: value >> 48))
        bytes.append(UInt8(truncatingIfNeeded: value >> 40))
        bytes.append(UInt8(truncatingIfNeeded: value >> 32))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendInt32(_ value: Int32, to bytes: inout [UInt8]) {
        appendUInt32(UInt32(bitPattern: value), to: &bytes)
    }

    private static func appendInt64(_ value: Int64, to bytes: inout [UInt8]) {
        appendUInt64(UInt64(bitPattern: value), to: &bytes)
    }
}

extension CheckpointAcknowledgmentCommitment.Record {
    init(_ record: AcknowledgedExceptionRecord) throws {
        let exception = record.exception
        exceptionIdentifier = exception.id
        kindRaw = exception.kind.rawValue
        aggregateBasisRaw = exception.aggregateBasis?.rawValue
        day = try PersistenceCoding.ordinal(exception.day)
        amountMinor = exception.amount?.minorUnits
        amountCurrencyCode = exception.amount?.currency.code
        amountCurrencyExponent = exception.amount?.currency.minorUnitDigits
    }

    init(_ row: StoredPeriodCheckpointAcknowledgment) {
        exceptionIdentifier = row.exceptionIdentifier
        kindRaw = row.kindRaw
        aggregateBasisRaw = row.aggregateBasisRaw
        day = row.day
        amountMinor = row.amountMinor
        amountCurrencyCode = row.amountCurrencyCode
        amountCurrencyExponent = row.amountCurrencyExponent
    }
}
