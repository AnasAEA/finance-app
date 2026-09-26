import Compression
import FinanceCore
import Foundation
import SwiftData

/// Retired pending rows have no durable bank identity, but remain exportable
/// evidence. Keeping them out of the live document makes each later bank read
/// independent of the number of previous provisional snapshots.
enum PendingEvidenceArchive {
    struct Retired: Codable {
        let observations: [ExternalObservation]
        let resolutions: [ExternalObservationResolution]
    }

    struct Partition {
        let live: FinanceDocument
        let retired: Retired
    }

    static func partition(
        _ document: FinanceDocument,
        authority: [ExternalProvider: AuthoritativePendingSnapshot],
        retryObservationIDs: Set<String> = []
    ) -> Partition {
        let resolutions = Dictionary(
            uniqueKeysWithValues: document.observationResolutions.map { ($0.observationID, $0) }
        )
        var referenced = Set(document.externalEvidenceLinks.map(\.observationID))
        referenced.formUnion(document.crossProviderCandidates.map(\.bankObservationID))
        referenced.formUnion(document.crossProviderCandidates.compactMap(\.walletObservationID))
        referenced.formUnion(document.trustedRuleAuditEvents.compactMap(\.observationID))
        referenced.formUnion(document.trustedRuleObservationSuppressions.map(\.observationID))
        referenced.formUnion(retryObservationIDs)

        let retired = document.externalObservations.filter { observation in
            guard observation.identity == .provisionalSnapshot,
                  observation.status == .pending,
                  let current = authority[observation.provider],
                  !current.observationIDs.contains(observation.id),
                  resolutions[observation.id]?.state == .provisional,
                  !referenced.contains(observation.id) else { return false }
            return true
        }
        let ids = Set(retired.map(\.id))
        var live = document
        live.externalObservations.removeAll { ids.contains($0.id) }
        live.observationResolutions.removeAll { ids.contains($0.observationID) }
        return Partition(
            live: live,
            retired: Retired(
                observations: retired,
                resolutions: document.observationResolutions.filter { ids.contains($0.observationID) }
            )
        )
    }

    static func encode(_ retired: Retired) throws -> (data: Data, rawByteCount: Int, codec: Int) {
        let raw = try JSONEncoder().encode(retired)
        let source = [UInt8](raw)
        var target = [UInt8](repeating: 0, count: max(source.count + 128, 256))
        let size = source.withUnsafeBufferPointer { sourceBuffer in
            target.withUnsafeMutableBufferPointer { targetBuffer in
                compression_encode_buffer(
                    targetBuffer.baseAddress!, targetBuffer.count,
                    sourceBuffer.baseAddress!, sourceBuffer.count,
                    nil, COMPRESSION_LZFSE
                )
            }
        }
        if size > 0 && size < raw.count {
            return (Data(target.prefix(size)), raw.count, 1)
        }
        return (raw, raw.count, 0)
    }

    static func decode(data: Data, rawByteCount: Int, codec: Int) throws -> Retired {
        let raw: Data
        switch codec {
        case 0:
            guard data.count == rawByteCount else { throw ArchiveError.corrupt }
            raw = data
        case 1:
            guard rawByteCount > 0, rawByteCount <= 50_000_000 else {
                throw ArchiveError.corrupt
            }
            let source = [UInt8](data)
            var target = [UInt8](repeating: 0, count: rawByteCount)
            let size = source.withUnsafeBufferPointer { sourceBuffer in
                target.withUnsafeMutableBufferPointer { targetBuffer in
                    compression_decode_buffer(
                        targetBuffer.baseAddress!, targetBuffer.count,
                        sourceBuffer.baseAddress!, sourceBuffer.count,
                        nil, COMPRESSION_LZFSE
                    )
                }
            }
            guard size == rawByteCount else { throw ArchiveError.corrupt }
            raw = Data(target)
        default:
            throw ArchiveError.unsupportedCodec
        }
        return try JSONDecoder().decode(Retired.self, from: raw)
    }

    enum ArchiveError: Error {
        case corrupt
        case unsupportedCodec
    }
}

@Model
final class StoredPendingEvidenceArchive {
    #Unique<StoredPendingEvidenceArchive>([\.identifier])

    var identifier: String = ""
    var archivedAt: Date = Date.distantPast
    var payload: Data = Data()
    var rawByteCount: Int = 0
    var codec: Int = 0
    var observationCount: Int = 0

    init(_ retired: PendingEvidenceArchive.Retired) throws {
        let encoded = try PendingEvidenceArchive.encode(retired)
        identifier = UUID().uuidString
        archivedAt = Date()
        payload = encoded.data
        rawByteCount = encoded.rawByteCount
        codec = encoded.codec
        observationCount = retired.observations.count
    }

    func decoded() throws -> PendingEvidenceArchive.Retired {
        let result = try PendingEvidenceArchive.decode(
            data: payload, rawByteCount: rawByteCount, codec: codec
        )
        guard result.observations.count == observationCount,
              Set(result.observations.map(\.id)) == Set(result.resolutions.map(\.observationID))
        else { throw PendingEvidenceArchive.ArchiveError.corrupt }
        return result
    }
}
