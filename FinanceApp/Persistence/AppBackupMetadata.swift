import Foundation
import FinanceCore

/// Additive app recovery envelope. Portable FinanceDocument readers ignore this
/// field; app restore validates it before staging or writing any records.
struct AppBackupMetadata: Codable, Hashable, Sendable {
    static let key = "financeAppBackup"
    var version = 1
    var transactionPresentation: [String: DomainMapper.TransactionPresentation] = [:]
    var incomeSourceActive: [String: Bool] = [:]

    static func read(from data: Data, document: FinanceDocument) throws -> Self {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] else { return Self() }
        guard JSONSerialization.isValidJSONObject(value),
              let bytes = try? JSONSerialization.data(withJSONObject: value),
              let metadata = try? JSONDecoder().decode(Self.self, from: bytes),
              metadata.version == 1 else { throw AppImportError.invalidBackupMetadata }
        let transactions = Set((document.transactions + document.expectedTransactions).map(\.id))
        let sources = Set(document.incomeSources.map(\.id))
        guard Set(metadata.transactionPresentation.keys).isSubset(of: transactions),
              Set(metadata.incomeSourceActive.keys).isSubset(of: sources) else {
            throw AppImportError.invalidBackupMetadata
        }
        return metadata
    }

    func encoding(_ document: FinanceDocument) throws -> Data {
        let domain = try Interchange.encode(document)
        guard var object = try JSONSerialization.jsonObject(with: domain) as? [String: Any] else {
            throw AppImportError.invalidBackupMetadata
        }
        let metadata = try JSONEncoder().encode(self)
        object[Self.key] = try JSONSerialization.jsonObject(with: metadata)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }
}
