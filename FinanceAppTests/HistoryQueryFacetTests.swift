import Testing
@testable import FinanceApp

/// Applied Activity filters, one removable chip each.
///
/// A chip that removes more than its own filter surprises the person, and one
/// that leaves an amount range behind after its currency is gone would compare
/// minor units across currencies. Both are pinned here.
@Suite("Activity filter facets")
struct HistoryQueryFacetTests {

    private func everything() -> HistoryQuery {
        var query = HistoryQuery()
        query.searchText = "coffee"
        query.dateRange = CalendarDay(year: 2026, month: 9, day: 1)...CalendarDay(year: 2026, month: 9, day: 30)
        query.accountIDs = ["bank"]
        query.categoryIDs = ["food"]
        query.economicTypes = ["Expense"]
        query.economicSourceIDs = ["salary"]
        query.currencies = ["EUR"]
        query.minimumAmountMinor = 500
        query.maximumAmountMinor = 5_000
        query.amountFractionDigits = 2
        query.sourceIDs = ["bnp"]
        query.statuses = ["booked"]
        query.provenanceValues = ["bank_sync"]
        query.sort = .amountHighToLow
        return query
    }

    @Test("An empty query has no chips, and search or sort alone is not a filter")
    func searchAndSortAreNotFilters() {
        var query = HistoryQuery()
        #expect(query.appliedFacets.isEmpty)
        query.searchText = "rent"
        query.sort = .oldestFirst
        #expect(query.appliedFacets.isEmpty)
    }

    @Test("Every applied filter has exactly one chip, in a stable order")
    func everyFilterHasOneChip() {
        #expect(everything().appliedFacets == HistoryFilterFacet.allCases)
    }

    @Test("Removing a chip removes that filter and nothing else")
    func removalIsLocal() {
        let full = everything()
        for facet in HistoryFilterFacet.allCases where facet != .currencies {
            let next = full.removing(facet)
            #expect(!next.appliedFacets.contains(facet), "\(facet)")
            #expect(Set(next.appliedFacets) == Set(full.appliedFacets).subtracting([facet]), "\(facet)")
            #expect(next.searchText == full.searchText)
            #expect(next.sort == full.sort)
        }
    }

    @Test("Removing the currency also removes what only works inside one currency")
    func currencyTakesItsAmountFiltersWithIt() {
        let next = everything().removing(.currencies)
        #expect(next.currencies.isEmpty)
        #expect(next.minimumAmountMinor == nil && next.maximumAmountMinor == nil)
        #expect(next.amountFractionDigits == nil)
        #expect(next.sort == .newestFirst)
        #expect(!next.appliedFacets.contains(.amount))
        // Unrelated filters survive.
        #expect(next.categoryIDs == ["food"] && next.dateRange != nil)
    }

    @Test("Removing an amount range keeps the currency and its amount sort")
    func amountRemovalKeepsCurrency() {
        let next = everything().removing(.amount)
        #expect(next.currencies == ["EUR"])
        #expect(next.amountFractionDigits == 2)
        #expect(next.sort == .amountHighToLow)
    }
}
