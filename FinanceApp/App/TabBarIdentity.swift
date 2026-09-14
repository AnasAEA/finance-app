import SwiftUI
import UIKit

/// Names the four tab bar buttons so automation can address them.
///
/// SwiftUI has no accessibility-identifier API for a tab that works on its own
/// here. All three candidates were built and measured against the tab bar on
/// iOS 26: `TabContent.accessibilityIdentifier` on a `Tab`, an identifier on a
/// `Tab`'s own label view, and an identifier on a `.tabItem` label. Under each
/// one the bar kept reporting buttons named only by their title — which
/// collides with the navigation title a screen away — or by their SF Symbol,
/// the two spellings a physical canary saw one tab answer to on different runs.
///
/// The bar underneath is UIKit and `UITabBarItem` does take an identifier, so
/// the four items are named there, in the one order `AppTab.allCases` declares
/// and `RootView` builds. This is the whole extent of the UIKit reach: it
/// assigns accessibility identifiers and touches nothing else.
///
/// It is not the only writer. SwiftUI later pushes the `.tabItem` label's own
/// identifier onto the same item, so `RootView` declares the matching value
/// there; without it SwiftUI pushes the SF Symbol's name instead and undoes
/// this. The two agree, so the order they run in does not matter.
///
/// It refuses to guess. A bar whose item count does not match the number of
/// tabs is left alone rather than labelled off by one.
struct TabBarIdentity: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Applier() }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        (controller as? Applier)?.apply()
    }

    final class Applier: UIViewController {
        /// The bar is built on SwiftUI's schedule, not this controller's, so
        /// the first attempt can land before there is anything to name. Each
        /// entry point gets a bounded budget of short retries; the bound exists
        /// so a bar that never arrives costs about two seconds of empty checks
        /// rather than a permanent timer.
        private static let attempts = 40
        private static let retryInterval: TimeInterval = 0.05

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            apply()
        }

        func apply() { apply(remainingAttempts: Self.attempts) }

        /// Idempotent: the same four names, re-applied whenever the bar is
        /// rebuilt.
        private func apply(remainingAttempts: Int) {
            let identifiers = AppTab.allCases.map(RouteID.tab)
            guard let items = enclosingTabBarController()?.tabBar.items,
                  items.count == identifiers.count
            else {
                guard remainingAttempts > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) {
                    [weak self] in
                    self?.apply(remainingAttempts: remainingAttempts - 1)
                }
                return
            }
            for (item, identifier) in zip(items, identifiers)
            where item.accessibilityIdentifier != identifier {
                item.accessibilityIdentifier = identifier
            }
        }

        /// The tab bar controller may be an ancestor of this controller or, when
        /// this sits beside the `TabView` rather than inside a tab, a
        /// descendant of the window's root. Both are searched; neither is
        /// assumed.
        private func enclosingTabBarController() -> UITabBarController? {
            if let ancestor = tabBarController { return ancestor }
            guard let root = view.window?.rootViewController else { return nil }
            return Self.firstTabBarController(in: root)
        }

        private static func firstTabBarController(
            in controller: UIViewController
        ) -> UITabBarController? {
            if let bar = controller as? UITabBarController { return bar }
            for child in controller.children {
                if let bar = firstTabBarController(in: child) { return bar }
            }
            if let presented = controller.presentedViewController {
                return firstTabBarController(in: presented)
            }
            return nil
        }
    }
}
