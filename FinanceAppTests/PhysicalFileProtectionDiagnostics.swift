import Foundation
import Testing
@testable import FinanceApp

/// Opt-in, app-hosted physical-device audit. Reads only filesystem metadata;
/// never opens a database, exports a document, or prints a financial value.
@Suite("Physical store file protection")
struct PhysicalFileProtectionDiagnostics {
    @Test("Report the effective SQLite and sidecar protection classes",
          .enabled(if: ProcessInfo.processInfo.environment["FINANCE_PHYSICAL_FILE_PROTECTION_AUDIT"] == "1"))
    func storeAndSidecars() throws {
        #if targetEnvironment(simulator)
        Issue.record("This audit must run on a physical iPhone")
        #else
        guard Bundle.main.bundleIdentifier == "com.anasait.financeapp" else {
            Issue.record("The test is not hosted in FinanceApp's container")
            return
        }
        let manager = FileManager.default
        let directory = try #require(manager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first)
        for (label, suffix) in [("sqlite", ""), ("wal", "-wal"), ("shm", "-shm")] {
            let url = directory.appendingPathComponent("FinanceCore-1.1.store\(suffix)")
            guard manager.fileExists(atPath: url.path) else {
                Issue.record("\(label) is absent; its protection class is unverified")
                continue
            }
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard let protection = attributes[.protectionKey] as? FileProtectionType else {
                Issue.record("\(label) has no readable file-protection attribute")
                continue
            }
            print("[file-protection] \(label)=\(protection.rawValue)")
            #expect(protection != .none)
        }
        #endif
    }
}
