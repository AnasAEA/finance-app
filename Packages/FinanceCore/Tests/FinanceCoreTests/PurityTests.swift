import XCTest
import Foundation
@testable import FinanceCore

/// Proof #18 — the forecast engine and the whole FinanceCore package have no
/// UI dependency. The package must stay usable from any Swift host (tests,
/// CLI, server) and linkable into the app as a pure domain library.
final class PurityTests: XCTestCase {

    /// Package root derived from this file's location — independent of the
    /// working directory the tests happen to run from.
    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        // …/Tests/FinanceCoreTests/PurityTests.swift → package root
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private var sourceFiles: [URL] {
        let sources = packageRoot.appendingPathComponent("Sources/FinanceCore")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    func testEveryProductionSourceFileIsFreeOfUIDependencies() throws {
        let files = sourceFiles
        XCTAssertGreaterThanOrEqual(files.count, 20, "sanity: the source tree was found")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["import SwiftUI", "import UIKit", "import AppKit", "import CoreData", "import CloudKit", "import SwiftData"] {
                XCTAssertFalse(
                    text.contains(forbidden),
                    "\(file.lastPathComponent) contains '\(forbidden)' — FinanceCore must stay UI-free"
                )
            }
            XCTAssertFalse(text.contains("URLSession"), "\(file.lastPathComponent) references networking")
        }
    }

    func testPackageManifestDeclaresNoUIDependency() throws {
        let manifest = packageRoot.appendingPathComponent("Package.swift")
        let code = try String(contentsOf: manifest, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for forbidden in ["SwiftUI", "UIKit", "AppKit"] {
            XCTAssertFalse(code.contains(forbidden), "Package.swift mentions '\(forbidden)' in code")
        }
    }

    func testDoubleNeverAppearsInMoneyTypes() throws {
        // Guard the core invariant at the source level: the money types must
        // not drift toward floating point. (Doc comments may discuss Double;
        // code may not use it.)
        let moneySources = sourceFiles.filter { $0.path.contains("/Money/") }
        XCTAssertGreaterThanOrEqual(moneySources.count, 3)
        for file in moneySources {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            XCTAssertFalse(code.contains("Double"), "\(file.lastPathComponent) uses Double — money is integer minor units only")
        }
    }
}
