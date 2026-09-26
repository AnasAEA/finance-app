// xcode: set sdk=iOS

import SwiftUI
import SwiftData

@main
struct FinanceApp: App {
    private let container: ModelContainer?
    @State private var store: FinanceStore?

    init() {
        #if DEBUG
        if LaunchOptions.current.usesHCIPrototype {
            container = nil
            _store = State(
                initialValue: FinanceStore.hciPrototypePreview(
                    variant: LaunchOptions.current.hciPrototypeVariant
                )
            )
            return
        }
        if LaunchOptions.current.usesBankInboxPreview {
            container = nil
            // Visual validation for the sync screens needs the backend
            // directory as well as the Inbox, and the sync state it is
            // supposed to be showing.
            let screen = LaunchOptions.current.visualValidationScreen
            let activity: BankSyncActivity = switch screen {
            case .bankSyncSyncing: .syncing
            case .bankSyncSucceeded: .succeeded(at: Date(timeIntervalSince1970: 1_804_334_400))
            case .bankSyncFailed: .failed("PayPal is rate limited. Try again later.")
            default: .idle
            }
            let pairing: BankPairingState = switch screen {
            case .bankSyncPairing, .bankSyncUnpaired: .unpaired
            default: .paired
            }
            _store = State(
                initialValue: FinanceStore.bankSyncPreview(pairing: pairing, activity: activity)
            )
            return
        }
        if LaunchOptions.current.usesDailyUsePreview {
            container = nil
            _store = State(initialValue: FinanceStore.dailyUsePreview())
            return
        }
        if LaunchOptions.current.usesPlanningPreview {
            container = nil
            _store = State(initialValue: FinanceStore.planningPreview())
            return
        }
        if LaunchOptions.current.usesEmptyPreview {
            container = nil
            _store = State(initialValue: FinanceStore.emptyPreview())
            return
        }
        if LaunchOptions.current.usesDevelopmentFixture {
            container = nil
            _store = State(initialValue: FinanceStore.preview())
            return
        }
        #endif

        // A freshly installed device has `Library` before it has
        // `Library/Application Support`, and SwiftData only discovers that at
        // its first write — which then rolls back an otherwise valid import.
        // See `PersistenceLocation` for the whole shape of that failure.
        //
        // Launch does not depend on this succeeding: if the directory cannot
        // be made, the container below will not open either, and the app
        // starts empty rather than not at all.
        let locationProblem: String? = {
            do {
                try PersistenceLocation.prepareApplicationSupport()
                return nil
            } catch {
                return String(describing: error)
            }
        }()

        let container = try? ModelContainer(
            for: Schema(FinanceSchema.models),
            // Phase 1.7 is the intentional pre-alpha schema reset. A distinct
            // store name prevents SwiftData from trying to migrate disposable
            // Phase-1 sample rows into the normalized FinanceCore 1.1 graph.
            configurations: ModelConfiguration(
                "FinanceCore-1.1",
                isStoredInMemoryOnly: false
            )
        )
        self.container = container
        // A store that cannot open is not a reason to fail to launch. Production
        // starts empty; fixture data is only loaded by explicit preview/tests.
        _store = State(
            initialValue: try? FinanceStore(
                context: container?.mainContext,
                // Naming the reason keeps a store that cannot be written from
                // looking like a store with nothing in it.
                unavailableReason: container == nil ? (locationProblem ?? "The store could not be opened.") : nil
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            if let store {
                RootView().environment(store)
            } else {
                ContentUnavailableView("Current date unavailable", systemImage: "calendar.badge.exclamationmark",
                    description: Text("Check your device’s date and time, then reopen the app."))
            }
        }
    }
}
