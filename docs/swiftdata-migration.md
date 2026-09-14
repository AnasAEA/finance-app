# SwiftData schema: FinanceCore 1.1 integration

**Status: implemented as a clean pre-alpha schema replacement.**

The Phase-1 store contained only sample/fixture data and predates real user
entry. It is intentionally not migrated. The app opens a new
`FinanceCore-1.1` store and starts empty; the old disposable rows are left
unused. This decision is safe only while no real production user data exists.
After real entry begins, incompatible changes require a versioned migration.

## Normalized entity graph

| Entity | Purpose |
|---|---|
| `StoredDocumentMeta` | FinanceDocument schema/kind/note and write metadata |
| `StoredAccount` | Stable account identity, kind, currency, rails, draw order |
| `StoredAccountBalance` | Current account balance and as-of truth |
| `StoredTransaction` | Parent economic/account event metadata |
| `StoredAccountLeg` | Ordered signed account leg, role, value day, exact money |
| `StoredOwnershipSplit` | Ordered owner/self split with exact amount semantics |
| `StoredIncomeSource` | Recurrence, certainty/dependency, destination account |
| `StoredRecurringObligation` | Commitment, recurrence, spending class, payment requirement |
| `StoredBudgetAllocation` | Budget and scenario policy metadata |
| `StoredBudgetOverride` | Per-month budget amount |
| `StoredInstallmentPlan` | Purchase/financing plan and payment requirement |
| `StoredInstallment` | Ordered due leg and status |
| `StoredDebt` | Debt truth and commitment status |
| `StoredScheduledPayment` | Explicit debt payment only; empty means no schedule |
| `StoredCarriedValue` | Observed EUR carrying value for a non-EUR holding |
| `StoredEntryPreferences` | App-only last-used expense and income accounts |
| `StoredExternalAccountBinding` | Opaque provider account → local account mapping and cutover |
| `StoredExternalObservation` | Provider evidence with independent dates and merchant fields |
| `StoredProviderBalanceSnapshot` | Typed provider balance evidence |
| `StoredExternalEvidenceLink` | Explicit evidence → economic transaction role |
| `StoredObservationResolution` | One explicit review state per observation |
| `StoredCrossProviderCandidate` | Conservative suggestion-only provider pairing |
| `StoredTrustedRule` | Exact predicate, independent interpretation, trust and lifecycle |
| `StoredTrustedRuleAuditEvent` | Append-only rule lifecycle, application and reversal history |
| `StoredTrustedRuleObservationSuppression` | Audited veto preventing post-reversal reapplication |
| `StoredPlannedPurchase` | Durable planned purchase / goal; not a transaction |
| `StoredSinkingFund` | Durable reservation; not economic spending |

Transactions no longer privilege a primary/counter account. An arbitrary
multi-leg event is one `StoredTransaction` with ordered `StoredAccountLeg`
children. Ownership is not a nullable “my share” scalar: it is ordered
`StoredOwnershipSplit` children carrying `ownerIdentifier`, `isSelf`, and an
exact `Money` amount. Cascade relationships keep each event graph atomic.

The app-only transaction category and merchant remain optional presentation
metadata on the parent. Income-source activation and last-used entry accounts
are also app metadata. They do not define economic or accounting behavior.
Income-source IDs on transactions and preferred destination-account IDs on
sources remain FinanceCore/FinanceDocument relationships and survive export
and import.

## Stable representations

- IDs and all cross-references are `String`, matching FinanceCore and
  FinanceDocument without lossy UUID projection.
- Money is signed `Int64` minor units, ISO currency code, and currency exponent.
  Every flattened money value stores its own exponent where reconstruction
  requires it. The mapper never hard-codes 2.
- `Day` is `Int32` in `YYYYMMDD` ordinal form. `MonthKey` is `Int32` in
  `YYYYMM` form. App-layer bridges convert to/from Foundation `Date` in GMT.
- Rails are sorted semantic string tokens (`card_debit`,
  `sepa_direct_debit`, etc.), not `OptionSet` raw values or bit positions.
- `PaymentRequirement` is flattened beside the obligation, installment plan,
  or debt: currency code, exponent, and rails all survive reconstruction.
- Closed recurrence values remain Codable `Data`; they are read as a whole and
  are not queried by individual associated values.
- `documentSequence` and child `sequence` values preserve authoritative array
  and leg order across round trips.

## Import and export

`StoredDocumentGraph.replace(with:in:writtenOn:presentation:)` writes a
FinanceDocument into normalized rows. `StoredDocumentGraph.load(from:)`
reconstructs a FinanceDocument. No whole-document blob is stored.

The integration suite imports the bundled FinanceDocument 1.3.0 development
fixture, reconstructs it from an in-memory SwiftData store, and compares both
domain equality and deterministic interchange encoding. It also checks row
counts and persisted rail tokens so a blob-backed implementation cannot satisfy
the test accidentally.

## Refusals, not repairs

Reading the stored graph back is a total function into "a document or an
error", never into "a document that is probably right".

| Situation | Behaviour |
|---|---|
| Unrecognised token in a closed vocabulary | `unknownEnumValue(field:value:)` |
| Unreadable encoded blob (e.g. a recurrence) | `corruptEncodedValue(field:value:)` |
| Stored or imported document at an unsupported schema | `unsupportedSchemaVersion(found:supported:)` |
| Two accounts with one identifier | `duplicateAccountIdentifier(id:)` |
| Two current balances for one account | `duplicateAccountBalance(accountID:)` |
| Day/month ordinal that is not a calendar date | `corruptDay` / `corruptMonth` |

Closed vocabularies are transaction kind, factivity, lifecycle, date precision,
evidence grade, income certainty, account kind, balance status, commitment
status, spending class, payment status, installment/debt status and scenario.
Each previously decoded to a default — `expense`, `observed`, `cleared`,
`bank`, `committed`, `scheduled` — which is the failure mode this table exists
to remove: a malformed or future-version row silently became a *valid* but
wrong financial statement, and nothing downstream could tell.

Payment rails stay open by design: `PaymentRail` is an id/summary pair, not an
enumeration, so an unknown token reconstructs as a named rail.

Factivity is decoded before transactions are partitioned into observed and
expected. Comparing raw strings would have dropped an unrecognised row from
both lists — the same silent loss by another route.

`PersistedSchema.supported` is `["1.1.0", "1.2.0", "1.3.0", "1.4.0", "1.5.0", "1.6.0"]`,
and `PersistedSchema.current` — the newest this build can write — is `1.6.0`.
An older store without planned purchases or sinking funds keeps its original
schema version through ordinary writes. The first persisted Phase 2.7 planning
row upgrades that document to at least 1.6.0. Earlier
versions are readable because every difference is additive: missing
settlements, external evidence, monthly ceiling, trusted rules, or rule audit
events decode as absent/empty rather than as zero or inferred state. A disk
migration test proves adding the three rule entities preserves a pre-1.5 store.
`StoredDocumentGraph.load` gates on the stored meta version and
`replace` gates on the incoming document, before purging anything. Versions
outside that list are not decoded on the assumption that their fields still
mean the same thing; a version that should be readable gets explicit migration
logic
and a place on that list together.

A load failure does not reset the store. `FinanceStore` records it, serves an
empty plan, and refuses to write, so the first entry after a bad open cannot
overwrite rows that failed to read but are still the only copy of themselves.
Only an explicit `importDocument` replaces them.

## Correctness coverage

Persistence/domain round trips cover ordinary expense, ordinary income,
owned-account transfer, ATM withdrawal, financing repayment, refund/reversal,
arbitrary multi-leg transactions, 1,000.00/400.00 ownership, pass-through disposal,
all lifecycle values, and three-decimal KWD. The KWD case is the regression
proof for the former exponent-2 bug.

The authoritative fixture additionally proves:

- 396.00 starting financial-account pool;
- 200 MAD outside the EUR electronic pool;
- first risk on September 11;
- debit-before-credit ordering and a −267.50 intraday minimum on March 16;
- a 267.50 minimum bridge and a 54.00 March month-end;
- guaranteed equals base because the owned share is guaranteed;
- 960.00 EUR arrears with no scheduled payment events.

The Phase 1.8 suite adds refusal coverage for every row in the table above,
plus proof that a clean document still round-trips unchanged.
