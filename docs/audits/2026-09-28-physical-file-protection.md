# Physical store file-protection check

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

No protection class is claimed by adding this diagnostic. A physical result
and WAL-aware state comparison are required to close the audit.

[apple-key]: https://developer.apple.com/documentation/foundation/fileattributekey/protectionkey
[apple-complete]: https://developer.apple.com/documentation/foundation/fileprotectiontype/complete
[apple-first-unlock]: https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication
