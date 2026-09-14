import CryptoKit

public enum SemanticPeriodProjectionFormat: String, Hashable, Sendable {
    case v1 = "v1"

    public var token: String { rawValue }

    public init(token: String) throws {
        guard let format = Self(rawValue: token) else { throw SemanticProjectionFormatError.unsupportedVersion }
        self = format
    }
}

/// Exactly 256 bits. Hashable is value equality support only; derivation uses
/// CryptoKit SHA-256. No payload or digest is exposed through description.
public struct SemanticProjectionDigest: Hashable, Sendable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 32 else { throw SemanticProjectionFormatError.invalidDigest }
        self.bytes = bytes
    }

    public var diagnosticHex: String {
        let alphabet = Array("0123456789abcdef".utf8)
        return String(decoding: bytes.flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]] }, as: UTF8.self)
    }
}

/// Validated canonical payload, with no storage mapping or automatic logging.
/// Quality, safe claims and acknowledgment decisions never enter this digest.
public struct CanonicalSemanticPeriodProjection: Hashable, Sendable {
    public let format: SemanticPeriodProjectionFormat
    public let bytes: [UInt8]
    public let projection: SemanticPeriodProjection
    public let digest: SemanticProjectionDigest

    /// Exact ASCII domain, framed by the same typed grammar as the payload.
    public static let digestDomain = "finance-core/checkpoint-projection"

    public init(_ projection: SemanticPeriodProjection, format: SemanticPeriodProjectionFormat = .v1) throws {
        switch format {
        case .v1: try self.init(bytes: CanonicalProjectionV1.node(projection).bytes)
        }
    }

    public init(bytes: [UInt8]) throws {
        var reader = CheckpointWireReader(bytes: bytes)
        let node = try reader.value()
        guard reader.offset == bytes.count else { throw SemanticProjectionFormatError.trailingBytes }
        let projection = try CanonicalProjectionV1.projection(node)
        guard try CanonicalProjectionV1.node(projection).bytes == bytes else {
            throw SemanticProjectionFormatError.nonCanonical
        }
        self.format = .v1
        self.bytes = bytes
        self.projection = projection
        // Payload is length-framed as a UTF-8 string. V1 grammar is wholly
        // UTF-8; parser validation above guarantees the conversion is lossless.
        let envelope = CheckpointWire.record("digest", [
            .string(Self.digestDomain), .string(format.token),
            .string(String(decoding: bytes, as: UTF8.self))
        ]).bytes
        self.digest = try SemanticProjectionDigest(bytes: Array(SHA256.hash(data: envelope)))
    }
}
