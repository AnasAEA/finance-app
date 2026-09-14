# Period checkpoint baseline comparison

How a period is compared against its own last close, and what the answer is
allowed to say. Phase 2.9C-B implements the comparison as pure values;
**nothing here persists anything**, and no production caller yet reads a
checkpoint history. Wiring a repository is a later phase.

Types: `PeriodCheckpointBaselineComparison.swift` (state model, change classes,
errors) and `PeriodCheckpointBaselineComparator.swift` (inputs, comparator,
classifier).

## The two questions the state model keeps apart

| Question | Accessor |
| --- | --- |
| Did we learn what the checkpoint source says about this period? | `isEstablished` |
| Did the comparison reach a conclusion a caller may act on? | `isConclusive` |

Conflating them is the modelling error this phase corrects. A source that is
read successfully and holds nothing has established a real fact — *this period
has never been closed* — and must not be reported as unavailable. A baseline
that exists but cannot presently be compared has equally been established; it
simply cannot yet be called changed or unchanged.

## States

| State | `isEstablished` | `isConclusive` | `previousQuality` | Means |
| --- | --- | --- | --- | --- |
| `unavailable(reason)` | ✗ | ✗ | nil | The source could not be read, or a stored payload could not be validated. |
| `notPreviouslyClosed` | ✓ | ✓ | nil | The source was read and holds no revision. The period has never been closed. |
| `unchangedSinceClose` | ✓ | ✓ | stored | Current canonical semantic state equals the accepted state. |
| `changedSinceClose` | ✓ | ✓ | stored | Comparable, and it differs, along a non-empty set of change classes. |
| `indeterminate` | ✓ | ✗ | stored | A baseline exists; the *current* period's evidence cannot support a comparison. |
| `requiresReverification` | ✓ | ✗ | stored | A baseline exists and is readable; its projection format is not one this build compares in. |

`Unavailability` carries only genuine source failures:
`noBaselinePersistence` (no checkpoint store exists in this build) and
`baselineProjectionUnreadable` (a stored payload that could not be read or
validated). "Read successfully, holds nothing" is **not** an unavailability —
that was the earlier `noPriorCheckpoint` case, and it is gone.

### `previousQuality`

The quality recorded by the latest accepted revision. It is an audit fact
carried forward from that revision and is **never recomputed from current
facts**: a period that has moved since a `.withExceptions` close still reports
`.withExceptions`, even where today's projection would close clean.

`unavailable` and `notPreviouslyClosed` carry no quality — an unreadable source
proves none, and a period that was never closed has none to have.

## Comparison authority

`SemanticPeriodProjection`, canonicalized, is the only authority.
`ReviewTotals`, `ReviewResult.totals` and `Economics.totals` are never read;
neither JSON, SwiftData nor a `ReviewResult` is ever diffed. The comparator's
production sources import nothing at all.

Both sides of a comparison are canonical payloads. A stored baseline is decoded
canonical bytes; the current side is re-encoded from the current projection.
Collection order, deduplicated coverage reasons and NFC string form are
therefore normalization, not change.

## Precedence

1. **Period and period kind are preconditions.** A revision for August compared
   against September throws `periodMismatch`; a weekly close against a monthly
   period throws `periodKindMismatch`. Neither is ever reported as a change.
2. **Format incompatibility outranks current comparability.** It is a durable
   property of the stored baseline that better current evidence will never
   resolve, whereas an indeterminate current period is transient. Reporting the
   durable answer keeps the state stable.
3. **Current comparability outranks any digest comparison.** A period whose own
   evidence is insufficient is `indeterminate`, never `changedSinceClose`.
4. **Digest equality decides unchanged.** Equal digests mean equal canonical
   bytes, because both digests are derived from their own validated payloads.
   Only a *difference* is explained, by decoding and classifying the payloads.
   The digest is the equality shortcut; the canonical payload is the
   explanation source.

## Same-format requirement

A comparison is only defined between payloads of the same projection format,
`comparisonFormat` (`v1`). A stored baseline in any other format returns
`requiresReverification(previousQuality:storedFormatToken:comparisonFormat:)`.
No digest is compared and neither changed nor unchanged is claimed: the period
must be verified and closed again under the current format.

A baseline in an unreadable format carries **no bytes**, because bytes in an
unknown format cannot be parsed into this build's types. Declaring a format
this build *does* support as unreadable throws
`supportedFormatDeclaredUnreadable`, so V1 validation cannot be bypassed by
that door.

## Indeterminate

Reasons are the checkpoint's own blocker taxonomy
(`PeriodCheckpointBlockerKind`), not a parallel vocabulary: a period the
evaluator refuses to close is a period whose current state cannot be asserted
against a prior close either. `PeriodCheckpointComparabilityLimits` is
non-empty by construction, so "indeterminate for no stated reason" is
unsayable.

Building `PeriodCheckpointCurrentState` from a `PeriodCheckpointReadiness`
gives the end-to-end behaviour: blockers win, and a projection that is absent
or fails to canonicalize is itself the limit `semanticProjectionUnavailable` —
never a claim that the period changed.

## Change classes

A class is a deterministic statement about **which projected dimension
differs**. It is never a causal explanation: `economicsChanged` does not say a
person spent differently, only that the projected economic facts of this period
are not the ones that were closed.

The vocabulary is closed and finite. There is no `other` and no
`unknownChange`. A digest difference that maps to no class is a failure of the
classifier or of the serializer, and the comparator throws `unclassifiedChange`
rather than reporting an unexplained change.

`PeriodCheckpointChangeClasses` is non-empty by construction, so
`changedSinceClose(..., [])` cannot be expressed.

### Which projection fields feed each class

| Class | Fed by |
| --- | --- |
| `coverageChanged` | `SemanticCoverage` — completeness, status, missing intervals, reason kinds |
| `economicsChanged` | `SemanticBudgetFact.periodEconomicSpending`, **and** `SemanticTransactionFact` membership, `day`, `kind`, `lifecycle`, `factivity`, `legs`, `incomeSourceID`, `ownedMinorUnits` |
| `budgetAttributionChanged` | `SemanticBudgetFact.attributions` and `.uncategorized`, and `SemanticTransactionFact.categoryKey` |
| `evidenceChanged` | `SemanticObservationFact` membership, `minorUnits`, `currencyCode`, `economicDay`, `resolution`, `links` |
| `providerStateChanged` | `SemanticObservationFact.statusToken`, `identity`, `providerEligibleForEconomicActual`, `bindingIsActive`, for rows present on both sides |
| `aggregateRelationshipChanged` | `SemanticAggregateFact.basis` and `pairedTransactionIDs`, for rows present on both sides |
| `expectationChanged` | `SemanticExpectationFact` — membership, `obligationID`, `expectedDay`, amount, currency, `statusToken`, `settledByTransactionID` |

`period` and `kind` feed no class; they are preconditions.

Classes are **not exclusive**. One mutation that genuinely moves several
projected dimensions reports all of them — a recategorization that also moves
the resolved period figure is both attribution and economics.

### Why `periodEconomicSpending` is economics

A cross-period linked original can change this period's *resolved* economic
spending while every transaction fact inside the period stays byte-identical.
Classifying that as budget attribution alone would understate what moved, so
the resolved figure feeds `economicsChanged` directly. The semantic-projection
prerequisite exists to make that closure hold.

### Observation membership is evidence

An observation that appeared or disappeared is an evidence change. Provider
state and aggregate relationship are compared only for rows present on **both**
sides, so `providerStateChanged` keeps meaning *the provider changed its mind
about a row that is still here* — eligibility withdrawal, durable→provisional
regression, binding activation — rather than firing on every sync that adds a
row. A single observation mutation may still emit more than one class when more
than one axis moved, so a provider change is never hidden behind an evidence
change.

### Coverage: comparable change versus no longer comparable

Two different things, kept apart:

- comparable coverage moved → `coverageChanged`;
- the current period's coverage is too weak to compare → `indeterminate`.

Today a stored baseline always carries complete coverage
(`PeriodCheckpointRevision` requires it) and an incomplete current period is a
blocker, so `coverageChanged` is reachable only from direct classifier use. It
is defined and tested anyway, so a future coverage model cannot escape
classification silently.

## What cannot churn a baseline

`SemanticPeriodProjection` excludes merchant text, notes, `observedAt`,
`resolvedAt`, sync run ids, transport cursors, budget ceilings, income-source
display names, spending nature, `ReviewTotals`, forecast and goals. None of
them can produce a change class, because none of them is in the projection.

Checkpoint quality, safe claims and acknowledgment decisions are outside the
digest too. Safe claims are derived from exception semantics, which the
prerequisite invariant already ties to the projection: equal projection ⇒ equal
checkpoint-relevant exception and safe-claim state. Differing safe claims over
an equal projection would be a violation of that invariant, not a new class.

## Acknowledgment identity — deliberately unresolved

Carrying acknowledgments forward across revisions needs a semantic key that
accounts for paired aggregate relationships, and no such key is frozen. This
phase compares semantic projections only. `AcknowledgedExceptionRecord` remains
a within-revision snapshot with no `Equatable`/`Hashable` conformance, and
nothing here matches acknowledgments across closes.

## Forward protection

`PeriodCheckpointBaselineComparisonTests` walks every reachable position of the
frozen V1 wire grammar — 239 single-field mutations over 64 distinct positions
— and asserts for each that the digest moves and that the classifier names
exactly the classes a hand-written path→class table says it should. The table's
key set must equal the set of positions the walk reaches, in both directions,
so a V2 field added to any record fails the test until someone decides
explicitly which class it belongs to. No reflection is used: the walk is over
the wire contract, which is what is actually frozen.
