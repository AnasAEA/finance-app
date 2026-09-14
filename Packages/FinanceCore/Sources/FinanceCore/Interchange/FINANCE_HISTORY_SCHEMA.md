# FinanceHistory Archive Schema

Versions **1.0.0**, **1.1.0** and **2.0.0** (the default wire) ·
`documentKind: "finance-history-archive"`

A private, versioned archive of reconstructed historical transactions. This is
deliberately a separate interchange root from `FinanceDocument`: archive rows
are searchable evidence, not live ledger transactions, account balances, or
forecast inputs. Importers persist them in the archive store and must never
compose them into current finance state.

**This is an independent version axis.** FinanceHistory versions do not track
`FinanceDocument` versions, and the two never share a version number's meaning.
FinanceHistory 2.0.0 and FinanceDocument 2.0.0 both happen to be the version
that made the monetary representation explicit, which is a coincidence of
history, not a coupling. Nothing may make one imply the other.

## Producers and consumers

The **only production writer** is the Python exporter in the separate budget
repository (`audit/scripts/export_finance_history.py`). The Swift app is a
**reader only**: `FinanceHistoryInterchange.make` and `.encode` exist for tests
and for callers that construct archives programmatically, and no production
code path in the app writes one.

Consumers: the app importer (`HistoryArchiveService`), SwiftData history
persistence, `HistoryArchiveQueries`, and the History screen.

## Encoding rules

- JSON, UTF-8, sorted keys, deterministic: identical document values produce
  identical bytes on any machine.
- Days are `"YYYY-MM-DD"`; months are `"YYYY-MM"`.
- Collections have a canonical order (accounts by id, records by stable id,
  gaps by range), so independently generated exports agree byte for byte.

## Versioning

`schemaVersion` uses semver, with this project's rule: **major** changes the
meaning or representation of an existing value; **minor** adds an optional
field; **patch** corrects documentation or fixtures.

| version | change |
|---|---|
| **2.0.0** | **major** — `originalAmount` carries its currency exponent explicitly. No field is added, removed or renamed. |
| **1.1.0** | **minor** — adds the optional record field `economicSource`. |
| **1.0.0** | initial contract. |

`FinanceHistoryInterchange.currentSchemaVersion` is `"2.0.0"`; readable
versions are `{1.0.0, 1.1.0, 2.0.0}`.

### Version dispatch

Decoding resolves the version **before** it interprets the body:

1. read `schemaVersion` out of the envelope, without parsing the body;
2. reject a version outside the readable set as `unsupported_schema_version`;
3. map it to a monetary grammar — 1.0.0 and 1.1.0 → legacy, 2.0.0 → V2;
4. run that grammar's strict closed-key schema;
5. verify the payload hash and cross-field semantics.

Version first means an unreadable future archive reports an unsupported
*version*, never a confusing monetary-shape error.

### Version and body are atomic

`FinanceHistoryDocument.encode(to:)` compares the encoder's selected monetary
grammar against the grammar its own `schemaVersion` speaks, and throws before
writing any payload if they differ — including when no grammar was stated at
all. The guarantee is therefore a property of the *document*, not of the
high-level wrapper, so it holds on every public encoding route: the validated
`encode(_:)`, `encoder(for:)`, `encoder()`, and a bare `JSONEncoder`. A body
grammar is never guessed from a default.

`FinanceHistoryOriginalAmount` fails closed the same way. It carries no version
of its own, so it has no authority to choose V1 or V2, and encoding it without
stated monetary context throws rather than picking one.

This matters because `schemaVersion` sits **outside** `contentSHA256`: no digest
can detect a body that disagrees with its envelope, so atomic encoding is the
only guard. On the way in, the strict schema for the declared version rejects
the other version's body. A
1.x envelope carrying a 2.0.0 body and a 2.0.0 envelope carrying a 1.x body are
both refused structurally.

### Sticky by construction

An ordinary re-encode keeps the document's own version: a 1.0.0 archive leaves
as 1.0.0, byte for byte. There is no `encode(as:)` and no downgrade API,
because there is no production Swift writer to need one.

## Monetary fields

The archive has exactly **four** amount fields per record, and exactly **one**
independent currency identity.

| field | wire key | type | meaning |
|---|---|---|---|
| original amount | `originalAmount` | object | the amount as the source stated it, in its own currency |
| booked EUR | `bookedAmountEURCents` | int64? | **EUR, fixed scale 2** |
| economic EUR | `economicAmountEURCents` | int64? | **EUR, fixed scale 2** |
| personal EUR | `personalAmountEURCents` | int64? | **EUR, fixed scale 2** |

The three `…EURCents` fields carry **no currency of their own and no exponent**.
They are euro minor units at scale 2 by definition, in every version. They are
not generalised here, and their names are not changed here.

### 2.0.0 — `originalAmount`

```json
{ "minorUnits": 100, "currency": { "code": "EUR", "exponent": 0 } }
```

All three keys required. `minorUnits` is a signed 64-bit integer and is the
**only** amount authority: there is no second field to disagree with it.
`code` is exactly three uppercase ASCII letters; `exponent` is an integer in
`0...6`. **No table is consulted and no exponent is ever defaulted** — a
missing `exponent` is a decoding error, not a two.

The shape is deliberately identical to the domain `Money`/`Currency` V2 wire,
so the two are easy to read side by side. The history codec is nevertheless a
**history-local** one: it never consults
`CodingUserInfoKey.financeDocumentMoneyWire`, so a FinanceDocument V1/V2
selection cannot reach in and change how an archive is written or read.

### 1.0.0 / 1.1.0 — `originalAmount`, frozen

```json
{ "cents": 100, "currency": "EUR" }
```

`cents` is a historical name for what has always been **minor units at the
currency's own scale**, not a claim of scale 2.

The exponent is not on the wire. Its permanent meaning is
`Currency.legacyDefaultDigits(code)` — the frozen historical table, which must
never gain, lose or change an entry. It is deliberately **not**
`Currency(code:)`, whose table is free to grow: an unrelated "add currency
support" commit must not be able to change what an archive already on disk
says. `JPY` in a 1.x archive is zero digits forever; an unknown but valid code
is two digits forever.

### Historical loss policy

If a 1.x archive says `{"cents": 100, "currency": "EUR"}`, its permanent
meaning is 100 minor units of EUR at the frozen scale for `EUR`. If the source
was really EUR/0 before it was written, **that exponent is gone**. It is never
reconstructed from the current registry, the account, the provider, the
canonical ledger, the economic source, notes, digit patterns, or a later
archive. 1.x states honest 1.x meaning and claims nothing more.

Consequently a document labelled 1.x can only be *encoded* when its original
currency's exponent equals the frozen default for its code. Anything else is
refused as `not_representable_in_legacy_version`. Never rescaled, never
normalised, never silently dropped.

### EUR consistency, versioned

When the original currency is EUR and `bookedAmountEURCents` is present, the
two must agree.

- **1.x** — raw integer equality, frozen. A 1.x original EUR amount is always
  EUR/2, so nothing else was ever meant.
- **2.0.0** — the two must be the same **value**, compared exactly at EUR/2.
  Scaling up uses checked multiplication; scaling down requires exact
  divisibility first. EUR/0 `1` is `100` booked cents; EUR/3 `100` is `10`;
  EUR/3 `1` has no exact EUR/2 value and is **rejected**, not rounded.

There is no rounding policy here, in either direction.

### Int64 range

All four amount fields accept the full signed 64-bit range **except
`Int64.min`**, which is rejected as `invalid_amount`.

This is an intentional archive invariant, not an oversight. History
persistence maintains an indexed magnitude column
(`StoredHistoricalTransaction.absoluteAmountMinor`), and `abs(Int64.min)`
traps. `Money.magnitude` and `Money.allocated` trap the same way. FinanceDocument
2.0.0 treats `Int64.min` as ordinary data; **history is deliberately stricter,
and 2.0.0 does not widen it.**

`Int64.max` and `2^53 + 1` round-trip exactly. No amount ever passes through a
`Double`.

## Malformed input

A malformed archive always throws; it never traps and never defaults.

- A currency code that is not three uppercase ASCII letters → `invalid_currency`.
- An exponent outside `0...6` → `invalid_currency_exponent`.
- A missing `exponent` under 2.0.0 → a schema error naming the field.
- `FinanceHistoryOriginalAmount.money` returns `nil` rather than constructing a
  `Currency` that would trip a precondition.

The importer only ever sees validated documents, so no unvalidated string
reaches a `Currency` initializer.

## Strict validation

The schema is **closed**: an unknown key at any level is rejected before
Codable parsing, naming its path. The record key set is identical for both
grammars — only the `originalAmount` body differs by version.

That shared record key set preserves one historical quirk deliberately: a
1.0.0 document carrying the 1.1.0 `economicSource` field has always been
accepted, and still is. That is untidy, but already-written archives rely on
it, and a monetary repair is not the place to start rejecting them.

## Payload hash

`contentSHA256` is SHA-256 over the canonical **compact** encoding of `payload`
as that version writes it. A 1.x payload hashes its 1.x form; a 2.0.0 payload
hashes its explicit-exponent form, so `minorUnits`, `currency.code` and
`currency.exponent` are all covered because they are inside `payload`. There is
no separate exponent digest.

The scope is unchanged by 2.0.0: the digest covers the payload only, never the
envelope, so changing `schemaVersion` alone does not change it. Version/body
atomicity, not the hash, is what prevents a mismatched envelope and body.

## Old readers

A build that predates 2.0.0 refuses a 2.0.0 archive **by version**, cleanly,
and writes nothing. If the version were forged down to one such a build reads,
its closed-key legacy schema rejects the 2.0.0 monetary body structurally. A
2.0.0 archive is therefore never silently accepted with a different monetary
meaning — the failure mode that matters most on a monetary wire.

## Python producer

An external exporter emits 2.0.0 by default and keeps
`--schema-version 1.1.0` for compatibility fixtures.

The canonical ledger has **no scale column** — every monetary column is named
`_cents` — so the exporter derives the exponent from a frozen mirror of
`Currency.legacyDefaultDigits` at write time. That exponent is **derived
metadata, not source evidence**. The value recorded is exactly what readers
have always inferred; what changed is that the archive now states it once
instead of every reader re-deriving it forever against a table free to grow.

A currency whose frozen scale is not 2 is refused rather than exported, because
`amount_original_cents` is built as fixed scale-2 cents and the integer would
be ambiguous. No such row exists in the canonical corpus.

A FinanceHistory monetary version bump therefore requires a **coordinated
change in both repositories**, as the 1.0.0 → 1.1.0 bump already did.

## Persistence

No SwiftData migration is needed for 2.0.0. `StoredHistoricalTransaction`
already stores `currencyCode` and `currencyExponent` separately, and the
three EUR amounts as optional `Int64`. The importer writes the explicit 2.0.0
exponent straight through, and writes the frozen-table exponent for 1.x.
`HistoryArchiveQueries` already renders each row at its own
`fractionDigits`, so an archive's stated scale reaches the screen unchanged.
