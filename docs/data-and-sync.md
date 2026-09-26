# Data, backups, and bank sync

## Local document

FinanceDocument is the portable financial interchange format. SwiftData stores
the normalized operational graph locally; FinanceCore validates domain content.
Export a backup before migrations or replacing a document, and keep exports
private. A restore must validate before replacing the current document.

Historical archive imports and FinanceDocument restores are separate formats
and flows. An archive preserves past history; it is not an operational-ledger
restore. Do not rename one format to make it look like the other.

Closed vocabulary values and unsupported schemas fail explicitly. A store that
cannot load refuses writes; deleting the store is not a recovery procedure.
The old pre-alpha reset is historical. Real user data now requires preservation
and tested migrations. See [persistence history](swiftdata-migration.md) and
[architecture](architecture.md).

## Optional bank service

```text
Provider → private bank service → signed HTTPS → iOS evidence store → review
```

The app pairs with a separately operated service using a single-use code and a
device-generated P-256 key. Requests are signed; the service can revoke a device.
Provider credentials and administrative service tokens are never app configuration.

The tracked configuration uses `https://finance-bank-sync.example.invalid`.
To connect your deployment, create the ignored file `Config/BankSync.local.xcconfig`:

```xcconfig
BANK_SYNC_HOST = your-service.example.com
```

The host override is incorporated by `Config/BankSync.xcconfig`; the resulting
URL must use HTTPS. Build and pair the device, then explicitly map remote
accounts to local accounts. Mapping cutovers prevent older activity already
represented by an opening balance from being counted again. Keep pairing codes,
private endpoint settings, exported evidence, and account identifiers outside Git.

## Balances, history, and review

Balance snapshots, provider movements, and economic transactions are independent
records. A current balance does not prove complete activity coverage. Imports
use incremental paging and provider authority to determine current pending
membership; failed or incomplete reads must not erase previously known evidence.
Sync Now reports the service job outcome separately from the local import.

Activity includes recorded transactions and bank movements, including unreviewed
booked history. A persisted evidence link suppresses the corresponding bank row
only when its ledger transaction is already displayed. Amount, date, or merchant
resemblance cannot substitute for a saved identity link.

Review turns evidence into an explicit financial interpretation. Clear expenses
can use quick categorization. Existing-payment suggestions require stronger
corroboration than a shared amount, and foreign-currency expenses require the
actual account-currency charge when it is not supplied by the evidence.

Approved merchant rules can handle eligible evidence only when the user enables
the automation master switch. Duplicate checks and safety gates still apply;
toggling the switch alone does not retrospectively apply the queue.

Superseded provisional snapshots are preserved in a compact audit archive.
Routine loading uses the operational graph; full exports reassemble retained
history. Compaction limits operational work, while total retained history can
still grow over time.

## Further reading

- [Sync audit](design/sync-service-audit.md)
- [Recorded-payment matching](design/recorded-payment-matching.md)
- [Foreign-currency categorization](design/foreign-currency-categorization.md)
- [Activity history and persistence contracts](architecture.md)
