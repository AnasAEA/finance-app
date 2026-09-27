import XCTest

/// Setup, recovery and bank-sync state, read off the running screens.
///
/// The unit suite proves the sentences are built correctly. This proves the
/// screens show those sentences and nothing else — which is the half that
/// actually failed before: `BankSyncView` has always distinguished a build with
/// no service address from a device that has not paired, and Settings, one
/// screen up, called both of them "Not paired".
///
/// The file picker is not driven here. A restore below the picker is proved by
/// `FirstRunRecoveryCoherenceTests` and `BackupExportTests` against the real
/// importer; what is left for a UI test is the navigation and the language,
/// which is what this asserts.
final class FirstRunRecoveryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - First run

    /// Two ways in, named for what the person is doing rather than for the
    /// function behind it, and no third option this build cannot execute.
    func testEmptyStoreOffersRestoreAndManualSetup() {
        launch(arguments: ["-useEmptyPreview"])
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Set up your money"].exists)

        XCTAssertTrue(choice(startingWith: "Restore backup.").exists)
        XCTAssertTrue(choice(startingWith: "Set up manually.").exists)
        // Pairing a bank before there are accounts to map onto opens a step
        // that cannot complete, so it is not offered here on any build.
        XCTAssertFalse(app.buttons["Connect bank"].exists)
        XCTAssertFalse(app.buttons["Pair this device"].exists)
        // The old name for the primary action.
        XCTAssertFalse(choice(startingWith: "Import current state.").exists)
    }

    /// The claim the packet was opened for. This build has no sync service, so
    /// it says that — rather than denying that the product has sync at all,
    /// one tap away from the Banks & Sync screen that proves otherwise.
    func testOnboardingStatesSyncPerBuildRatherThanDenyingIt() {
        launch(arguments: ["-useEmptyPreview"])
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 8))

        XCTAssertTrue(app.staticTexts[
            "Your records stay on this device and are never uploaded. No sample data is ever added. This build has no bank sync."
        ].exists)
        XCTAssertFalse(app.staticTexts[
            "Everything stays on this device. There is no server, no sync and no sample data."
        ].exists)
    }

    // MARK: - Bank sync, four states

    /// The mutation: summarising an unconfigured service as "Not paired".
    /// A person cannot fix a missing build service address by pressing Pair,
    /// and this row is where they decide whether to go looking for the button.
    func testSettingsDoesNotCallAnUnconfiguredBuildUnpaired() {
        launch(arguments: ["-useEmptyPreview"], route: "settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))

        let row = app.descendants(matching: .any)["settings.banks"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Not available on this build"))
        XCTAssertFalse(row.label.contains("Not paired"))
    }

    /// And the screen it leads to offers no action, because there is none.
    func testUnconfiguredBankSyncOffersNoPairingAction() {
        launch(arguments: ["-useEmptyPreview"], route: "banks")
        XCTAssertTrue(app.navigationBars["Banks & Sync"].waitForExistence(timeout: 8))

        XCTAssertTrue(app.staticTexts["Bank sync is not configured"].exists)
        XCTAssertTrue(app.staticTexts["This build has no sync service address."].exists)
        XCTAssertFalse(app.buttons["Pair this device"].exists)
        XCTAssertFalse(app.buttons["Sync Now"].exists)
    }

    /// Configured, not paired: the state that *does* have a pairing action, so
    /// the distinction above removes nothing a person could have used.
    func testConfiguredButUnpairedStillOffersPairing() {
        launch(arguments: ["-useBankInboxPreview", "-visualScreen", "bankSyncUnpaired"])
        XCTAssertTrue(app.navigationBars["Banks & Sync"].waitForExistence(timeout: 8))

        XCTAssertTrue(app.buttons["Pair this device"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Bank sync is not configured"].exists)
    }

    /// Paired, unchanged.
    func testPairedDeviceStillSyncs() {
        launch(arguments: ["-useBankInboxPreview", "-visualScreen", "bankSyncConnected"])
        XCTAssertTrue(app.navigationBars["Banks & Sync"].waitForExistence(timeout: 8))

        XCTAssertTrue(app.buttons["Sync Now"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Pair this device"].exists)
        XCTAssertFalse(app.staticTexts["Bank sync is not configured"].exists)
    }

    // MARK: - Data & Privacy

    /// One vocabulary across the two screens that own the file: the row that
    /// reads a backup is named for reading a backup, and the word "import"
    /// survives only on the archive, which is a document type this app cannot
    /// produce and does not back up.
    func testDataAndPrivacyNamesRestoreExportAndArchiveDistinctly() {
        launch(arguments: ["-useEmptyPreview"], route: "data")
        XCTAssertTrue(app.navigationBars["Data & Privacy"].waitForExistence(timeout: 8))

        XCTAssertTrue(app.buttons["Restore backup"].exists)
        XCTAssertTrue(app.buttons["Import historical archive"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["data.export"].exists)
        XCTAssertFalse(app.buttons["Import current state"].exists)
    }

    func testBackupDefaultsToEncryptionAndPlaintextRequiresOptOut() {
        launch(arguments: ["-useAuditRecoveryPreview"], route: "data")
        let export = app.descendants(matching: .any)["data.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 8))
        export.tap()
        XCTAssertTrue(app.navigationBars["Your backup"].waitForExistence(timeout: 8))
        let encrypt = app.switches["backup.encrypt"]
        XCTAssertTrue(encrypt.exists)
        XCTAssertEqual(encrypt.value as? String, "1")
        XCTAssertTrue(app.secureTextFields["backup.password"].exists)
        XCTAssertTrue(app.secureTextFields["backup.password-confirmation"].exists)
        let save = app.buttons["data.export.save"]
        for _ in 0..<8 where !save.exists { app.swipeUp() }
        XCTAssertTrue(save.exists)
        XCTAssertFalse(save.isEnabled)
        // A partially clipped row can be hittable behind the navigation bar.
        // Scroll until the switch row is below the navigation bar.
        for _ in 0..<8 {
            let navigationBottom = app.navigationBars["Your backup"].frame.maxY
            if encrypt.isHittable && encrypt.frame.minY > navigationBottom { break }
            app.swipeDown()
        }
        XCTAssertGreaterThan(encrypt.frame.minY, app.navigationBars["Your backup"].frame.maxY)
        encrypt.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let disabledEncryption = NSPredicate(format: "value == '0'")
        expectation(for: disabledEncryption, evaluatedWith: encrypt)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.secureTextFields["backup.password"].exists)
        for _ in 0..<8 where !save.exists { app.swipeUp() }
        XCTAssertTrue(save.exists)
        XCTAssertTrue(save.isEnabled)
    }

    func testForeignFundOpensInProductionPlan() {
        launch(arguments: ["-useAuditRecoveryPreview"], route: "goals")
        XCTAssertTrue(app.staticTexts["Synthetic foreign fund"].waitForExistence(timeout: 8))
    }

    // MARK: - Helpers

    /// An onboarding card, addressed by the sentence it reads out. The card
    /// combines its children into one accessibility element whose label is
    /// "<title>. <explanation>", so a prefix match addresses the title alone.
    private func choice(startingWith prefix: String) -> XCUIElement {
        app.buttons.containing(
            NSPredicate(format: "label BEGINSWITH %@", prefix)
        ).firstMatch
    }

    private func launch(arguments: [String], route: String? = nil) {
        var all = ["-AppleLanguages", "(en-US)", "-AppleLocale", "en_US"] + arguments
        if let route { all += ["-startRoute", route] }
        app.launchArguments = all
        app.launch()
    }
}
