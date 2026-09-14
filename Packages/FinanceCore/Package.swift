// swift-tools-version:6.0
// FinanceCore — pure Swift financial domain + forecast foundation.
// No SwiftUI, no UIKit, no SwiftData, no networking. Consumable by the iOS
// app as a library. Swift 6 language mode: the domain is fully Sendable and
// free of data races by construction.
import PackageDescription

let package = Package(
    name: "FinanceCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "FinanceCore", targets: ["FinanceCore"]),
    ],
    targets: [
        .target(
            name: "FinanceCore",
            path: "Sources/FinanceCore"
        ),
        .testTarget(
            name: "FinanceCoreTests",
            dependencies: ["FinanceCore"],
            path: "Tests/FinanceCoreTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
