# Canonical semantic period projection V1

This is a byte contract for `SemanticPeriodProjection`, independent of Swift
stored-property names, enum declaration order, Codable and JSON. Renaming a
Swift property must preserve the literals and positions below. The synthetic
constructor and fixed bytes in `CanonicalProjectionTests` are the compatibility
alarm; do not regenerate the vector to make an accidental format change pass.

## Byte grammar

All punctuation below is literal ASCII. No whitespace is implied.

```
natural = "0" | [1-9][0-9]*
decimal = "0" | "-"?[1-9][0-9]*       (within signed Int64)
string  = "s" natural ":" UTF8_BYTES  (length is UTF-8 byte count)
integer = "i" natural ":" decimal     (length is ASCII byte count)
bool    = "b0" | "b1"
optional = "n" | "p" value
array   = "a" natural ":" value*      (count, not byte length)
record  = "r" string array            (tag, then positional fields)
value   = string | integer | bool | optional | array | record
```

Strings use Unicode NFC, preserving Swift String's canonical-equivalence
semantics. Embedded colons, NUL, non-ASCII and empty strings are allowed and
length-delimited. Lengths have no sign, whitespace or leading zero. Integers
have no plus sign, leading zeros, decimal point or negative zero. Integer
encoding uses decimal conversion, never native memory layout. Record arity is
exact: extra/duplicated fields, omitted fields and unknown tags are rejected.
There are no keyed fields, and therefore no dictionary-order dependency.

The parser checks lengths against remaining bytes before consuming or
allocating children, uses checked integer arithmetic, rejects invalid UTF-8,
and limits nesting to 32 levels. Valid V1 projections are shallower. Errors
carry only typed reasons, never input contents. The outer reader rejects
trailing bytes and unknown versions. It then reconstructs the existing
projection and re-encodes it; unequal bytes are rejected as noncanonical.
Thus unsorted collections, duplicate coverage reasons and non-NFC strings
cannot enter through canonical decoding. Encoding normalizes them itself.

## Record layouts

`R(tag; ...)` means a record with the listed positional fields. Names in this
table document the positions; **no Swift field names are emitted**.
`S`, `I`, `B`, `O`, and `A` denote string, integer, bool, optional and array.

| Tag | Fields, in exact order |
| --- | --- |
| `semantic-period-projection` | S format (`v1`), interval, period-kind enum, coverage, budget, A transactions, A observations, A expectations |
| `interval` | day start, day end |
| `day` | I day index (days since 1970-01-01) |
| `budget` | money resolved period spending, money uncategorized, A attributions |
| `money` | I minor units, S currency code, I minor-unit digits |
| `attribution` | S transaction ID, O(S budget ID), attribution-basis enum, money amount |
| `transaction` | S ID, day, kind enum, lifecycle enum, factivity enum, A legs, O(S income-source ID), O(I owned minor units), O(S category key) |
| `leg` | S account ID, I minor units, S currency code |
| `observation` | S ID, S provider status, identity enum, B provider eligibility, B binding active, resolution enum, I minor units, S currency code, O(day economic day), A links, O(aggregate) |
| `link` | S transaction ID, evidence-role enum |
| `aggregate` | aggregate-basis enum, A(S paired transaction IDs) |
| `expectation` | S obligation ID, day expected day, I minor units, S currency code, expectation-status enum, O(S settling transaction ID) |
| `complete` | no fields (coverage) |
| `incomplete` | coverage-status enum (partial or insufficient), A missing intervals, A coverage-reason enums |

Intervals are **inclusive at both ends**, matching `SemanticInterval` and
`ReviewInterval`; start must be <= end. No formatted period label, Foundation
Date, timezone or locale enters a day. A day index must fit the host's safe
Day arithmetic range (`Int.min / 2 < index < Int.max / 2`); unsupported extremes
fail explicitly. Supported package platforms are 64-bit. Encoding also guards
the civil-year arithmetic before evaluating the index.

Currency codes are exactly three uppercase ASCII letters, validated rather
than silently repaired. Money digits are 0...6, preserved exactly even for
codes absent from the global currency table. The decoder calls
`Currency(code:minorUnitDigits:)` and `Money(minorUnits:currency:)`; it never
uses Money Codable, decimal text, description, or currency exponent lookup.
The existing leg, observation and expectation facts contain code + minor
units only; V1 preserves precisely those fields and invents no exponent.

## Frozen enum tokens

Unless otherwise specified, each token is a record tag with zero fields.

| Vocabulary | Tokens |
| --- | --- |
| Period kind | `weekly`, `monthly` |
| Transaction kind | `expense`, `income`, `transfer`, `refund`, `financingRepayment`, `passThrough`, `cashWithdrawal`, `currencyConversion` |
| Lifecycle | `pending`, `cleared`, `reconciled`, `reversed` |
| Factivity | `observed`, `expected` |
| Observation identity | `durable`, `provisionalSnapshot` |
| Observation resolution | `unreviewed`, `linkedToTransaction`, `noEconomicEffect`, `outsideSyncBoundary`, `provisional`, `economicallyIneligible` |
| Evidence role | `accountMovement`, `merchantEnrichment`, `supportingEvidence` |
| Aggregate basis | `sourceEstablishedAggregateRelationship`, `structuralCandidateOnly` |
| Expectation status | `due`, `overdue`, `paid`, `skipped`, `noLongerDue` |
| Coverage status | `complete`, `partial`, `insufficient` (`complete` is forbidden inside `incomplete`) |
| Coverage reason | `coverageMetadataAbsent`, `archiveHistoryAbsent`, `missingArchiveInterval`, `missingLiveInterval`, `sourceGap` |
| Attribution basis | `settled-obligation` + one S obligation ID; `category` + one S key; `linked-refund` + one S original transaction ID; `unattributed` + no fields |

Observation provider status is intentionally an **open string vocabulary**,
matching the semantic fact. Unknown provider status text survives losslessly;
unknown closed enum tokens fail. Optional facts are independent: the serializer
preserves even a paid expectation with absent settling ID instead of inventing
meaning or silently repairing its producer.

## Normalization and equality

Every semantic collection is sorted by unsigned lexicographic comparison of
the element's complete recursively canonical bytes. This is a total semantic
field order, including ties in identity. It does not consult display text,
Swift Hasher, a dictionary's iteration order or existing partial Comparables.
Only coverage reasons are deduplicated, matching `SemanticCoverage`'s set
semantics. Other multiplicities are preserved.

Decoding returns `SemanticPeriodProjection`. Its existing initializer sorts
top-level rows by their established identity order; nested collections retain
the canonical order. Define normalized P as `decode(encode(P)).projection`.
The normalization includes NFC, collection order and coverage-reason uniqueness;
all scalar semantic values and all other multiplicities survive. For any
accepted canonical bytes, `encode(decode(bytes)) == bytes`.

## Digest envelope

SHA-256 via CryptoKit hashes exactly:

```
R("digest";
  S("finance-core/checkpoint-projection"),
  S("v1"),
  S(the complete canonical payload as UTF-8))
```

The ASCII domain is `finance-core/checkpoint-projection`. The typed grammar
frames domain, version and payload unambiguously. Repeating the version in
both envelope and payload is intentional. `SemanticPeriodProjectionFormat.v1`
is the sole version definition. `SemanticProjectionDigest` validates exactly
32 bytes and offers lowercase hex only through `diagnosticHex`.

Quality, safe claims, acknowledgment snapshots, revision number and close time
are outside the projection and outside its digest. Canonical payload and digest
are both held by a pure validated value; no persistence mapping is present.

## Revision boundary

`PeriodCheckpointRevision` validates revision number/predecessor consistency,
a finite caller-supplied timestamp, ready disposition, empty blockers and
undecided exceptions, complete coverage, matching period/kind/projection,
quality and safe-claim consistency, and full acknowledgment. Metadata format,
digest, period and kind are derived from the validated values, preventing
mismatches by construction. Disposition is not retained.

`AcknowledgedExceptionRecord` snapshots one carried exception. It deliberately
has no carry-forward equality or key. Paired aggregate transaction identities
must be considered before any future acknowledgment identity is approved.
No persistence, action, comparison, baseline policy or monthly write policy
is implemented here.

## Golden and adversarial proof

The 1,195-byte synthetic golden in `CanonicalProjectionTests` includes two
transactions, two observations, two expectations, a linked refund attribution,
an aggregate pairing, provider-state flags, nil and present values, positive,
negative and zero amounts, and EUR (2), XAF (0), KWD (3) Money metadata.
Its independently calculated SHA-256 digest is:

```
9913eaec56cc0d43a4cb825c766576f986e50ff94df8b74364b5a751b29f6a7d
```

Tests cover recursive field mutations, all closed enums and associated-value
branches, whole-payload truncation at every byte, malformed lengths/integers,
invalid currency/interval/version, nesting limits, Unicode, optional markers,
reversed/randomized collections, duplicate identities and decision separation.
Fresh-process validation can run the existing built XCTest bundle via
`xcrun xctest -XCTest FinanceCoreTests.CanonicalProjectionTests <bundle>` under
different `LANG`, `LC_ALL` and `TZ` values; every process asserts the same fixed
bytes and digest without emitting any payload.
