# Physical store file-protection check — completed 28 September 2026

The opt-in `PhysicalFileProtectionDiagnostics` app-hosted test reads only the
effective `FileAttributeKey.protectionKey` of `FinanceCore-1.1.store`, `-wal`
and `-shm` on a physical iPhone. It prints class names, not paths or contents.
An absent sidecar is reported as unverified, never inferred from the SQLite
file or from a Mac-side container copy. Apple documents the
[protection attribute][apple-key] and the different locked-device behavior of
[complete][apple-complete] and
[complete until first user authentication][apple-first-unlock].

Before running on the paired phone, follow `.agent/DEVICE_POLICY.md`: run
`ios-device doctor` and `ios-device inspect`, take a WAL-aware pre-install copy,
over-install without uninstall/reset, disable foreground sync, and compare a
settled post-run copy. Require `NO_BUSINESS_MUTATION`, then remove private
copies and logs. The app host can initialize its store before this test runs;
the metadata read itself is not a financial write.

Run only this test with `TEST_RUNNER_FINANCE_PHYSICAL_FILE_PROTECTION_AUDIT=1`
and a physical-device `xcodebuild test -only-testing` destination. The ordinary
simulator/CI suite leaves it disabled. Report each of SQLite, WAL and SHM
separately. If a class is `none`, missing or unavailable, investigate before
choosing an explicit protection policy. `complete` forbids access while locked;
background sync and recovery must be tested before imposing that class.

## Physical result

On the paired iPhone (iOS 27.0), the opt-in app-hosted test executed exactly
once and passed. `FileManager.attributesOfItem` reported
`NSFileProtectionCompleteUntilFirstUserAuthentication` separately for the
existing SQLite, WAL and SHM files. All three were present. This is effective
per-file metadata read inside the app container, not an inference from the
directory or from files copied to the Mac. Apple's description says this class
encrypts the files at rest and denies access until the first device unlock
after boot; after that unlock, the app may access them while the device is
locked. It is not the stronger `complete` class, and this result makes no claim
about exported backup or temporary files.

The test was launched with `-disableForegroundSync` in a temporary Xcode test
scheme. A WAL-aware copy of the live store preceded the test. The test only
read metadata and printed the three class names. A second copy compared
`NO_BUSINESS_MUTATION` with zero business and operational tables changed. The
current-main signed Release build then passed the release-bundle gate and
strict code-signature verification, was over-installed without uninstall or
reset, and was launched with foreground sync disabled. The final WAL-aware
comparison against the original pre-test copy again reported
`NO_BUSINESS_MUTATION` and zero business and operational changes. No Sync Now,
financial save, pairing change or store deletion occurred. Private store
copies, test results, logs, screenshots and the temporary scheme were removed.

The measured class closes the SQLite/WAL/SHM attribute uncertainty. Changing
it to `complete` would be a separate product decision because background
activity and locked-device recovery need testing under that access policy.

[apple-key]: https://developer.apple.com/documentation/foundation/fileattributekey/protectionkey
[apple-complete]: https://developer.apple.com/documentation/foundation/fileprotectiontype/complete
[apple-first-unlock]: https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication
