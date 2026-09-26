import Foundation

extension BackupProtection {
    static func isEncrypted(_ data: Data) -> Bool { EncryptedBackup.isEncrypted(data) }
}

extension FinanceBackup {
    func encrypted(password: String) async throws -> Data {
        let plaintext = data
        return try await Task.detached(priority: .userInitiated) {
            let sealed = try EncryptedBackup.encrypt(plaintext, password: password)
            guard try EncryptedBackup.decrypt(sealed, password: password) == plaintext else {
                throw AppImportError.fileUnreadable
            }
            return sealed
        }.value
    }
}

extension FinanceStore {
    func readBackupFile(at url: URL) throws -> Data {
        if let blocker = importBlocker { throw blocker }
        return try DocumentImporter.readData(contentsOf: url)
    }

    func prepareEncryptedImport(from data: Data, password: String) async throws -> ImportPreview {
        if let blocker = importBlocker { throw blocker }
        cancelImport()
        let plaintext = try await Task.detached(priority: .userInitiated) {
            try EncryptedBackup.decrypt(data, password: password)
        }.value
        try Task.checkCancellation()
        return try prepareImport(from: plaintext)
    }
}
