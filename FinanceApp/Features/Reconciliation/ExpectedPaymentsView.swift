import SwiftUI

/// Expected payments, and what answered them.
///
/// The list is deliberately a to-do rather than a ledger: what is waiting comes
/// first, what was settled sits underneath it, and nothing here is ever decided
/// on the person's behalf. An expected payment whose day has passed says
/// "Expected" — not "missed", which the app cannot know, and not "paid", which
/// would be worse.
struct ExpectedPaymentsView: View {
    @Environment(FinanceStore.self) private var store

    var body: some View {
        Self.content(store: store)
    }

    /// One live read per composition. Expected-payment standing is derived from
    /// the current civil day, so two reads either side of local midnight would
    /// show "due" and "overdue" rows from different days in one list. Taking
    /// the store as a parameter is what lets a test build this exact list.
    static func content(store: FinanceStore) -> some View {
        let snapshot = store.snapshot
        let waiting = snapshot.unresolvedExpectedPayments
            .sorted { $0.expectedDate < $1.expectedDate }
        let settled = snapshot.expectedPayments
            .filter(\.isResolved)
            .sorted { $0.expectedDate > $1.expectedDate }
        return List {
            if waiting.isEmpty && settled.isEmpty {
                ContentUnavailableView(
                    "No expected payments",
                    systemImage: "calendar.badge.clock",
                    description: Text("Recurring commitments will appear here as dated payments you can match.")
                )
                .listRowBackground(Color.clear)
            }

            if !waiting.isEmpty {
                Section {
                    ForEach(waiting) { payment in
                        NavigationLink {
                            ExpectedPaymentDetailView(payment: payment)
                        } label: {
                            ExpectedPaymentRow(payment: payment)
                        }
                    }
                } header: {
                    Text("Waiting")
                } footer: {
                    Text("A payment stays here until you say what happened to it. Matching one does not change the recurring commitment behind it.")
                }
            }

            if !settled.isEmpty {
                Section("Settled") {
                    ForEach(settled) { payment in
                        NavigationLink {
                            ExpectedPaymentDetailView(payment: payment)
                        } label: {
                            ExpectedPaymentRow(payment: payment)
                        }
                    }
                }
            }
        }
        .financeList()
        .navigationTitle("Expected payments")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One dated instance, with its standing as a quiet badge.
struct ExpectedPaymentRow: View {
    let payment: ExpectedPayment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    labels
                    MoneyText(amount: payment.amount.negated, size: 15, weight: .medium,
                              showsSign: true, colorBySign: true)
                }
            } else {
                HStack(spacing: 12) {
                    labels
                    Spacer(minLength: 8)
                    MoneyText(amount: payment.amount.negated, size: 15, weight: .medium,
                              showsSign: true, colorBySign: true)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(payment.ruleName)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(payment.expectedDate.formatted(.dateTime.day().month(.abbreviated)))
                if let status = payment.status.label {
                    StatusChip(text: status, tone: tone)
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.Role.supporting)
        }
    }

    private var tone: StatusChip.Tone {
        switch payment.status {
        case .paid: .positive
        case .overdue: .caution
        case .skipped, .noLongerDue: .quiet
        case .due: .quiet
        }
    }

    private var accessibilityLabel: String {
        var parts = [payment.ruleName, payment.amount.formatted()]
        parts.append("expected \(payment.expectedDate.formatted(date: .long, time: .omitted))")
        if let status = payment.status.label { parts.append(status) }
        return parts.joined(separator: ", ")
    }
}

/// A small, low-contrast status marker. Deliberately not a coloured pill on
/// every row: only a payment with something to say carries one.
struct StatusChip: View {
    enum Tone { case positive, caution, quiet }

    let text: String
    var tone: Tone = .quiet

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }

    private var foreground: Color {
        switch tone {
        case .positive: Theme.Role.positive
        case .caution: Theme.Role.caution
        case .quiet: Theme.Role.supporting
        }
    }

    private var background: Color {
        foreground.opacity(0.12)
    }
}

// MARK: - One expected payment

/// What can be done about a single expected payment.
///
/// Three answers, and they are different answers: it was paid (and here is the
/// transaction), it was skipped this cycle, or it is not coming at all. None of
/// them stops the commitment recurring.
struct ExpectedPaymentDetailView: View {
    let payment: ExpectedPayment

    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var isPicking = false
    @State private var failure: AppReconciliationError?

    /// Re-read from the snapshot so the screen follows what was just done
    /// rather than the value it was pushed with — but read once, so the
    /// standing, the matched row and the paid date all describe one civil day.
    var body: some View {
        content(store.snapshot)
    }

    private func matchedRow(_ snapshot: FinanceAppSnapshot, _ current: ExpectedPayment) -> ActivityRow? {
        guard let id = current.status.matchedTransactionID else { return nil }
        return snapshot.activity.flatMap(\.rows).first { $0.id == id }
    }

    private func content(_ snapshot: FinanceAppSnapshot) -> some View {
        let current = snapshot.expectedPayments.first { $0.id == payment.id } ?? payment
        let matchedRow = matchedRow(snapshot, current)
        let paidDate = snapshot.reconciliations[current.status.matchedTransactionID ?? ""]?
            .actualDate.formatted(date: .long, time: .omitted)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 5) {
                    Text(current.ruleName).font(.headline)
                    MoneyText(amount: current.amount.negated, size: 34, weight: .bold,
                              showsSign: true, colorBySign: true)
                }
                .padding(.vertical, 6)
            }

            Section {
                LabeledContent("Expected") {
                    Text(current.expectedDate.formatted(.dateTime.day().month(.wide).year()))
                }
                if let status = current.status.label {
                    LabeledContent("Status", value: status)
                }
                if let matchedRow {
                    LabeledContent("Paid") {
                        Text(paidDate ?? "—")
                    }
                    LabeledContent("Transaction", value: matchedRow.title)
                    if let account = matchedRow.primaryAccountLabel {
                        LabeledContent("Account", value: account)
                    }
                }
            } header: {
                Text("This payment")
            } footer: {
                Text(current.status.isResolved
                     ? "The recurring commitment is unaffected. Its next payment is still expected as normal."
                     : "The expected date comes from the recurring commitment. The date it was really paid comes from the transaction, and the two are kept separate.")
            }

            if !current.status.isResolved {
                Section {
                    Button {
                        isPicking = true
                    } label: {
                        Label("Mark as paid", systemImage: "checkmark.circle")
                    }
                    Button {
                        act { try store.skipExpectedPayment(id: current.id) }
                    } label: {
                        Label("Skip this one", systemImage: "forward.end")
                    }
                    Button {
                        act { try store.markExpectedPaymentNoLongerDue(id: current.id) }
                    } label: {
                        Label("No longer due", systemImage: "xmark.circle")
                    }
                } footer: {
                    Text("Skipping this payment leaves the commitment running. It only says that this one is not being paid.")
                }
            } else {
                Section {
                    Button(role: .destructive) {
                        act { try store.unmatchExpectedPayment(id: current.id) }
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                } footer: {
                    Text("This removes the link only. The transaction and the commitment both stay exactly as they are.")
                }
            }
        }
        .financeList()
        .navigationTitle("Expected payment")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isPicking) {
            MatchPickerView(
                title: "Match a transaction",
                explanation: "Choose the transaction that paid \(current.ruleName).",
                matches: store.matches(forExpectedPayment: current.id),
                side: .actual
            ) { match, acceptsDifference in
                try store.matchPayment(
                    expectedPaymentID: match.expectedPaymentID,
                    transactionID: match.transactionID,
                    acceptingAmountDifference: acceptsDifference
                )
            }
        }
        .alert(
            "Not done",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) { failure = nil }
        } message: { error in
            Text(error.message)
        }
    }

    private func act(_ work: () throws -> Void) {
        do { try work() } catch let error as AppReconciliationError {
            failure = error
        } catch {
            failure = .persistenceFailed(String(describing: error))
        }
    }
}

// MARK: - Choosing the other half

/// The candidate list, used from both directions.
///
/// Every row is a suggestion. Nothing is preselected, nothing is linked by
/// arriving here, and a row whose amount does not match says so on its own
/// confirm button rather than in a footnote.
struct MatchPickerView: View {
    enum Side { case actual, expected }

    let title: String
    let explanation: String
    let matches: [PaymentMatch]
    let side: Side
    let confirm: (PaymentMatch, Bool) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var failure: AppReconciliationError?
    @State private var pendingDifference: PaymentMatch?

    var body: some View {
        NavigationStack {
            List {
                if matches.isEmpty {
                    ContentUnavailableView(
                        "Nothing to match",
                        systemImage: "questionmark.circle",
                        description: Text(side == .actual
                            ? "No recorded transaction is close enough in amount, currency and date to be a plausible match."
                            : "No expected payment is close enough in amount, currency and date to be a plausible match.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(matches) { match in
                            Button {
                                attempt(match, acceptsDifference: false)
                            } label: {
                                MatchRow(match: match, side: side)
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        Text("Suggestions only. Nothing is linked until you choose it.")
                    }
                }
            }
            .financeList()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .top) {
                if !matches.isEmpty {
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(Theme.Role.supporting)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Metric.screenPadding)
                        .padding(.bottom, 8)
                        .background(.bar)
                }
            }
            .alert(
                "Amounts are different",
                isPresented: Binding(get: { pendingDifference != nil }, set: { if !$0 { pendingDifference = nil } }),
                presenting: pendingDifference
            ) { match in
                Button("Match anyway") {
                    attempt(match, acceptsDifference: true)
                    pendingDifference = nil
                }
                Button("Cancel", role: .cancel) { pendingDifference = nil }
            } message: { match in
                Text("\(match.ruleName) expects \(match.expectedAmount.formatted()), and this transaction is \(match.actualAmount.formatted()). Matching them records that difference deliberately.")
            }
            .alert(
                "Not matched",
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                presenting: failure
            ) { _ in
                Button("OK", role: .cancel) { failure = nil }
            } message: { error in
                Text(error.message)
            }
        }
    }

    private func attempt(_ match: PaymentMatch, acceptsDifference: Bool) {
        if match.requiresAmountConfirmation && !acceptsDifference {
            pendingDifference = match
            return
        }
        do {
            try confirm(match, acceptsDifference)
            dismiss()
        } catch let error as AppReconciliationError {
            failure = error
        } catch {
            failure = .persistenceFailed(String(describing: error))
        }
    }
}

/// One suggestion, with its reasons visible.
struct MatchRow: View {
    let match: PaymentMatch
    let side: MatchPickerView.Side

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(headline)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                MoneyText(amount: shownAmount.negated, size: 15, weight: .medium,
                          showsSign: true, colorBySign: true)
            }

            HStack(spacing: 6) {
                Text(shownDate.formatted(.dateTime.day().month(.abbreviated).year()))
                StatusChip(text: match.strength.label, tone: chipTone)
            }
            .font(.caption)
            .foregroundStyle(Theme.Role.supporting)

            ForEach(match.reasons, id: \.self) { reason in
                Label(reason, systemImage: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(Theme.Role.supporting)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Links these two")
    }

    private var headline: String {
        switch side {
        case .actual: match.transactionTitle ?? match.ruleName
        case .expected: match.ruleName
        }
    }

    private var shownAmount: Amount {
        side == .actual ? match.actualAmount : match.expectedAmount
    }

    private var shownDate: CalendarDay {
        side == .actual ? match.actualDate : match.expectedDate
    }

    private var chipTone: StatusChip.Tone {
        switch match.strength {
        case .strong: .positive
        case .plausible: .quiet
        case .weak: .caution
        }
    }
}
