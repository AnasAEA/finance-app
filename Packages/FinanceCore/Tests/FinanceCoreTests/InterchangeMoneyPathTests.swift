import XCTest
@testable import FinanceCore

/// Every monetary field FinanceDocument can carry, one focused trigger each.
///
/// The V1 preflight is the only thing standing between a non-canonical
/// exponent and a legacy export that silently rescales it. A field the
/// traversal forgets to visit is not a missing test — it is a document that
/// encodes as V1 and loses the exponent on the way. So the unit under test is
/// the traversal's *coverage*, asserted path by path against a document whose
/// every other field is canonical.
final class InterchangeMoneyPathTests: XCTestCase {

    private let day = Day(year: 2026, month: 9, day: 1)
    private let month = MonthKey(year: 2026, month: 9)
    private let instant = Date(timeIntervalSince1970: 1_757_000_000)

    /// EUR/0 is the smallest possible departure from the legacy table: same
    /// code, different exponent, so only an exponent-aware writer can tell the
    /// difference. `nil` builds the fully canonical document.
    private func currency(_ path: String, _ target: String?) -> Currency {
        path == target ? Currency(code: "EUR", minorUnitDigits: 0) : .eur
    }

    private func money(_ path: String, _ target: String?, _ minorUnits: Int64 = 1) -> Money {
        Money(minorUnits: minorUnits, currency: currency(path, target))
    }

    /// Populates every independently-variable monetary path at once, with
    /// exactly one of them —
    /// `target` — carrying a non-V1 exponent.
    private func document(nonCanonical target: String? = nil) -> FinanceDocument {
        // No ownership here: a split's currency is pinned to an inflow leg of
        // the same transaction (see `testOwnershipCannotCarryAnExponentItsLegsDoNot`),
        // so legs and splits cannot vary independently.
        func transactions(_ name: String, _ factivity: Factivity) -> [Transaction] {
            [
                Transaction(
                    id: "\(name)-tx",
                    date: day,
                    kind: .expense,
                    legs: [AccountLeg(accountID: "a", amount: money("\(name)[0].legs[0].amount", target))],
                    factivity: factivity
                )
            ]
        }

        return FinanceDocument(
            schemaVersion: "1.6.0",
            documentKind: "SYNTHETIC — NOT FINANCIAL EVIDENCE",
            accounts: [
                Account(
                    id: "a", name: "Synthetic",
                    currency: currency("accounts[0].currency", target),
                    kind: .bank, supportedRails: [.sepaCreditTransfer]
                )
            ],
            balances: [
                AccountBalance(
                    accountID: "a",
                    balance: money("balances[0].balance", target),
                    asOf: day
                )
            ],
            transactions: transactions("transactions", .observed),
            expectedTransactions: transactions("expectedTransactions", .expected),
            incomeSources: [
                IncomeSource(
                    id: "i", name: "Synthetic",
                    amount: money("incomeSources[0].amount", target),
                    certainty: .expected, schedule: .oneShot(on: day)
                )
            ],
            installments: [
                InstallmentPlan(
                    id: "plan", provider: "Synthetic", purchaseDescription: "Synthetic",
                    originalPurchaseAmount: money("installments[0].originalPurchaseAmount", target),
                    installments: [
                        Installment(
                            sequence: 1, dueDate: day,
                            amount: money("installments[0].installments[0].amount", target)
                        )
                    ],
                    paymentRequirement: PaymentRequirement(
                        currency: currency("installments[0].paymentRequirement.currency", target),
                        acceptableRails: [.sepaDirectDebit]
                    )
                )
            ],
            debts: [
                Debt(
                    id: "debt", name: "Synthetic",
                    originalAmount: money("debts[0].originalAmount", target),
                    paymentSchedule: [
                        ScheduledPayment(
                            day: day,
                            amount: money("debts[0].paymentSchedule[0].amount", target)
                        )
                    ],
                    paymentRequirement: PaymentRequirement(
                        currency: currency("debts[0].paymentRequirement.currency", target),
                        acceptableRails: [.sepaDirectDebit]
                    )
                )
            ],
            planning: FinanceDocument.Planning(
                safetyFloor: money("planning.safetyFloor", target),
                monthlyEconomicCeiling: money("planning.monthlyEconomicCeiling", target),
                budgets: [
                    BudgetAllocation(
                        id: "b", name: "Synthetic", spendingClass: .essential,
                        monthlyAmount: money("planning.budgets[0].monthlyAmount", target),
                        effectiveFrom: month,
                        monthlyOverrides: [
                            month: money("planning.budgets[0].monthlyOverrides[0].amount", target)
                        ]
                    )
                ],
                recurringObligations: [
                    RecurringObligation(
                        id: "o", name: "Synthetic",
                        amount: money("planning.recurringObligations[0].amount", target),
                        spec: .monthly(onDay: 1, from: month, through: nil),
                        requirement: PaymentRequirement(
                            currency: currency("planning.recurringObligations[0].requirement.currency", target),
                            acceptableRails: [.cardDebit]
                        ),
                        spendingClass: .essential
                    )
                ],
                carriedEURValues: ["a": money("planning.carriedEURValues[0].value", target)],
                plannedPurchases: [
                    PlannedPurchase(
                        id: "p", name: "Synthetic",
                        targetAmount: money("planning.plannedPurchases[0].targetAmount", target, 100),
                        reservedAmount: money("planning.plannedPurchases[0].reservedAmount", target, 0),
                        requirement: PaymentRequirement(
                            currency: currency("planning.plannedPurchases[0].requirement.currency", target),
                            acceptableRails: [.cardDebit]
                        )
                    )
                ],
                sinkingFunds: [
                    SinkingFund(
                        id: "f", name: "Synthetic",
                        targetAmount: money("planning.sinkingFunds[0].targetAmount", target, 100),
                        reservedAmount: money("planning.sinkingFunds[0].reservedAmount", target, 0),
                        contributionAmount: money("planning.sinkingFunds[0].contributionAmount", target, 10)
                    )
                ]
            ),
            externalObservations: [
                ExternalObservation(
                    id: "obs", bindingID: "bind", provider: .bnp, status: .booked,
                    creditDebitIndicator: .debit,
                    amount: money("externalObservations[0].amount", target),
                    bookingDate: day, eligibleForEconomicActual: true, observedAt: instant
                )
            ],
            providerBalanceSnapshots: [
                ProviderBalanceSnapshot(
                    id: "bal", bindingID: "bind", provider: .bnp, balanceType: "CLBD",
                    amount: money("providerBalanceSnapshots[0].amount", target),
                    observedAt: instant
                )
            ],
            crossProviderCandidates: [
                CrossProviderCandidate(
                    id: "cand", bankObservationID: "obs", walletObservationID: nil,
                    state: .unresolved, candidateCount: 1,
                    amount: money("crossProviderCandidates[0].amount", target),
                    rule: "synthetic", computedAt: instant
                )
            ]
        )
    }

    /// Every monetary path FinanceDocument carries, machine-derived from the
    /// type graph rather than from memory. Adding a monetary field without
    /// adding it here and to the preflight fails this test.
    private static let allMonetaryPaths = [
        "accounts[0].currency",
        "balances[0].balance",
        "transactions[0].legs[0].amount",
        "expectedTransactions[0].legs[0].amount",
        "incomeSources[0].amount",
        "installments[0].originalPurchaseAmount",
        "installments[0].paymentRequirement.currency",
        "installments[0].installments[0].amount",
        "debts[0].originalAmount",
        "debts[0].paymentRequirement.currency",
        "debts[0].paymentSchedule[0].amount",
        "planning.safetyFloor",
        "planning.monthlyEconomicCeiling",
        "planning.budgets[0].monthlyAmount",
        "planning.budgets[0].monthlyOverrides[0].amount",
        "planning.recurringObligations[0].amount",
        "planning.recurringObligations[0].requirement.currency",
        "planning.carriedEURValues[0].value",
        "planning.plannedPurchases[0].targetAmount",
        "planning.plannedPurchases[0].reservedAmount",
        "planning.plannedPurchases[0].requirement.currency",
        "planning.sinkingFunds[0].targetAmount",
        "planning.sinkingFunds[0].reservedAmount",
        "planning.sinkingFunds[0].contributionAmount",
        "externalObservations[0].amount",
        "providerBalanceSnapshots[0].amount",
        "crossProviderCandidates[0].amount",
    ]

    /// The canonical document must be V1-clean, or every trigger below would
    /// pass for the wrong reason.
    func testFullyPopulatedCanonicalDocumentNeedsNoUpgrade() throws {
        let canonical = document()
        XCTAssertNil(Interchange.firstV1IncompatibleField(in: canonical))
        XCTAssertFalse(Interchange.documentRequiresV2(canonical))
        XCTAssertEqual(
            try Interchange.decode(Interchange.encode(canonical)).schemaVersion, "1.6.0"
        )
    }

    func testEveryMonetaryPathIndependentlyTriggersV2() throws {
        for path in Self.allMonetaryPaths {
            let value = document(nonCanonical: path)
            XCTAssertEqual(
                Interchange.firstV1IncompatibleField(in: value), path,
                "preflight does not visit \(path) — a V1 export would silently rescale it"
            )
            XCTAssertTrue(Interchange.documentRequiresV2(value), path)
        }
    }

    /// Planning requires a goal's and a fund's amounts to share one currency,
    /// so flipping one half of a matched pair is a planning violation rather
    /// than an interchange one. Those paths stay covered by the traversal test
    /// above; naming them here keeps the end-to-end exclusion explicit instead
    /// of arithmetic, so a path that silently stops round-tripping is caught.
    private static let currencyPairedPaths: Set<String> = [
        "planning.plannedPurchases[0].targetAmount",
        "planning.plannedPurchases[0].reservedAmount",
        "planning.sinkingFunds[0].targetAmount",
        "planning.sinkingFunds[0].reservedAmount",
        "planning.sinkingFunds[0].contributionAmount",
    ]

    /// End-to-end for every path whose single-field mutation still forms a
    /// document the planning rules accept.
    func testTriggeringPathRefusesV1AndRoundTripsExactlyAsV2() throws {
        var exercised: Set<String> = []
        for path in Self.allMonetaryPaths {
            let value = document(nonCanonical: path)
            guard (try? PlanningValidation.validate(value)) != nil else {
                XCTAssertTrue(Self.currencyPairedPaths.contains(path), "unexpected planning refusal for \(path)")
                continue
            }
            exercised.insert(path)

            XCTAssertThrowsError(try Interchange.encode(value, as: .format(.v1)), path) { error in
                XCTAssertEqual(error as? InterchangeError, .notRepresentableInV1(field: path), path)
            }

            let output = try Interchange.encode(value)
            let read = try Interchange.decode(output)
            var expected = value
            expected.schemaVersion = "2.0.0"
            XCTAssertEqual(read, expected, path)
            XCTAssertEqual(read.schemaVersion, "2.0.0", path)
        }
        XCTAssertEqual(exercised, Set(Self.allMonetaryPaths).subtracting(Self.currencyPairedPaths))
    }

    /// Ownership is the one monetary path that cannot be triggered on its own.
    ///
    /// A split must account for the transaction's inflow *exactly, in the
    /// split's own currency* (`OwnershipValidation`), so a split in EUR/0 is
    /// only constructible when a leg already carries EUR/0. The preflight
    /// visits ownership anyway, but the legs guard it: there is no document in
    /// which a split smuggles an exponent past a canonical leg list.
    func testOwnershipCannotCarryAnExponentItsLegsDoNot() throws {
        let zeroExponent = Currency(code: "EUR", minorUnitDigits: 0)

        // The domain refuses a split whose currency no inflow leg carries.
        XCTAssertNotNil(
            OwnershipValidation.validationProblem(
                splits: [OwnershipSplit(ownerID: "me", isSelf: true, amount: Money(minorUnits: 1, currency: zeroExponent))],
                legs: [AccountLeg(accountID: "a", amount: Money(minorUnits: 1, currency: .eur))]
            )
        )

        // Constructible only when the leg agrees — and then the leg trips first.
        var value = document()
        value.transactions = [
            Transaction(
                id: "pass", date: day, kind: .passThrough,
                legs: [AccountLeg(accountID: "a", amount: Money(minorUnits: 1, currency: zeroExponent))],
                ownership: [OwnershipSplit(ownerID: "me", isSelf: true, amount: Money(minorUnits: 1, currency: zeroExponent))],
                factivity: .observed
            )
        ]
        XCTAssertEqual(Interchange.firstV1IncompatibleField(in: value), "transactions[0].legs[0].amount")
        XCTAssertTrue(Interchange.documentRequiresV2(value))
        XCTAssertThrowsError(try Interchange.encode(value, as: .format(.v1)))

        // And the split survives the V2 round trip with its own exponent.
        let read = try Interchange.decode(Interchange.encode(value))
        XCTAssertEqual(read.transactions[0].ownership?.first?.amount.currency, zeroExponent)
    }
}
