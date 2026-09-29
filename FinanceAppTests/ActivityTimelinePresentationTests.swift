import Foundation
import Testing
@testable import FinanceApp

@Suite("Activity timeline presentation")
struct ActivityTimelinePresentationTests {
    private struct Row: Identifiable {
        let id: String
        let date: CalendarDay?
    }

    @Test("An undated first row forms a group without indexing an empty array")
    func undatedFirst() {
        let rows = [Row(id: "unknown-1", date: nil), Row(id: "unknown-2", date: nil)]
        let groups = ActivityTimelineGrouping.adjacent(rows, date: \.date)
        #expect(groups.count == 1)
        #expect(groups.first?.date == nil)
        #expect(groups.first?.rows.map(\.id) == ["unknown-1", "unknown-2"])
    }

    @Test("Date headings preserve a selected amount order")
    func adjacentOnly() {
        let day = CalendarDay(year: 2026, month: 9, day: 23)
        let other = CalendarDay(year: 2026, month: 9, day: 22)
        let rows = [Row(id: "largest", date: day), Row(id: "middle", date: other), Row(id: "smallest", date: day)]
        let groups = ActivityTimelineGrouping.adjacent(rows, date: \.date)
        #expect(groups.count == 3)
        #expect(groups.flatMap(\.rows).map(\.id) == rows.map(\.id))
    }

    @Test("Readable statement casing preserves mixed case and known acronyms")
    func readableTitles() {
        #expect(ActivityTextPresentation.readableTitle("PAYPAL EUROPE") == "PayPal Europe")
        #expect(ActivityTextPresentation.readableTitle("BNP SEPA TRANSFER") == "BNP SEPA Transfer")
        #expect(ActivityTextPresentation.readableTitle("Google Payment Ireland") == "Google Payment Ireland")
        #expect(ActivityTextPresentation.readableTitle("ATM") == "ATM")
    }

    // Every descriptor below is invented: no real merchant, card or date.

    @Test("A card statement line is listed by its merchant")
    func cardLinesListTheirMerchant() {
        let payment = "FACTURE CARTE DU 010126 SYNTHETIC CAFE DU PORT CARTE 1234XXXXXXXX5678"
        #expect(ActivityTextPresentation.cardMerchant(in: payment) == "SYNTHETIC CAFE DU PORT")
        #expect(ActivityTextPresentation.listTitle(payment) == "Synthetic Cafe Du Port")
        #expect(ActivityTextPresentation.ledgerListTitle(payment) == "Synthetic Cafe Du Port")

        let refund = "AVOIR CARTE DU 020126 SYNTHETIC SHOP CARTE 1234XXXXXXXX5678"
        #expect(ActivityTextPresentation.listTitle(refund) == "Synthetic Shop")
    }

    @Test("Anything not exactly a card statement line keeps its words")
    func otherTitlesKeepTheirWords() {
        for title in [
            "PRLV SEPA SYNTHETIC MOBILE",                              // a direct debit
            "FACTURE CARTE DU 010126 CARTE 1234XXXXXXXX5678",          // no merchant
            "FACTURE CARTE DU 0101 SYNTHETIC CAFE CARTE 1234XXXXXXXX5678", // short date
            "Synthetic Cafe",
        ] {
            #expect(ActivityTextPresentation.cardMerchant(in: title) == nil, "\(title)")
            #expect(ActivityTextPresentation.listTitle(title) == ActivityTextPresentation.readableTitle(title))
            #expect(ActivityTextPresentation.ledgerListTitle(title) == title)
        }
    }

    @Test("A SEPA direct debit line is listed by its creditor")
    func directDebitsListTheirCreditor() {
        let debit = "PRLV SEPA SYNTHETIC POWER S.A. ECH/010126 ID EMETTEUR/FR00ZZZ000000 "
            + "MDT/SYN0001 REF/0000000000 LIB/SYNTHETIC INVOICE 01"
        #expect(ActivityTextPresentation.directDebitCreditor(in: debit) == "SYNTHETIC POWER S.A.")
        #expect(ActivityTextPresentation.listTitle(debit)
                == ActivityTextPresentation.readableTitle("SYNTHETIC POWER S.A."))
        #expect(!ActivityTextPresentation.listTitle(debit).contains("MDT/"))
        #expect(ActivityTextPresentation.ledgerListTitle(debit) == ActivityTextPresentation.listTitle(debit))
        // Any one of the bank's markers ends the creditor's name.
        #expect(ActivityTextPresentation.directDebitCreditor(in: "PRLV SEPA SYNTHETIC GYM MDT/SYN0002")
                == "SYNTHETIC GYM")
        // The first space-delimited marker bounds the name, so punctuation
        // inside the creditor's own name is kept.
        #expect(ActivityTextPresentation.directDebitCreditor(in: "PRLV SEPA SYNTHETIC/POWER ECH/010126")
                == "SYNTHETIC/POWER")
        // Without a marker there is no shape to trust, so the words stay.
        #expect(ActivityTextPresentation.directDebitCreditor(in: "PRLV SEPA SYNTHETIC GYM") == nil)
        #expect(ActivityTextPresentation.directDebitCreditor(in: "PRLV SEPA ECH/010126") == nil)
    }

    @Test("A name typed into the ledger keeps its exact spelling")
    func typedLedgerNamesAreUntouched() {
        #expect(ActivityTextPresentation.ledgerListTitle("SNCF") == "SNCF")
        #expect(ActivityTextPresentation.ledgerListTitle("RENT FOR MARCH") == "RENT FOR MARCH")
    }
}
