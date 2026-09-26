import SwiftUI
import LocalAuthentication
import UIKit

enum FinancePrivacy {
    static let lockPreference = "finance.privacy.app-lock"
    static var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
}

/// Lock is optional; background snapshots are covered regardless of preference.
struct FinancePrivacyView<Content: View>: View {
    @Environment(\.scenePhase) private var phase
    @AppStorage(FinancePrivacy.lockPreference) private var requiresUnlock = false
    @State private var unlocked = false
    @State private var authenticating = false
    @State private var message: String?
    @State private var authenticationContext: LAContext?
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        Group {
            if requiresUnlock && !unlocked {
                VStack(spacing: 20) {
                    Image(systemName: "lock.shield").font(.largeTitle)
                    Text("Finance is locked").font(.title2)
                    if let message { Text(message).font(.subheadline) }
                    Button("Unlock Finance") { Task { await authenticate() } }
                        .buttonStyle(.borderedProminent).disabled(authenticating)
                        .accessibilityIdentifier("privacy.unlock")
                }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Surface.background)
            } else { content }
        }
        .task { if requiresUnlock { await authenticate() } }
        .onChange(of: phase) { _, value in
            ScenePrivacyCover.setVisible(value != .active)
            if value == .background {
                authenticationContext?.invalidate()
                authenticationContext = nil
                unlocked = false
            }
        }
        .onChange(of: requiresUnlock) { _, enabled in
            unlocked = false
            if enabled { Task { await authenticate() } }
        }
    }

    @MainActor private func authenticate() async {
        guard !authenticating, phase == .active else { return }
        authenticating = true
        defer { authenticating = false }
        let context = LAContext()
        authenticationContext = context
        do {
            let accepted = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your financial records.")
            guard authenticationContext === context, requiresUnlock else { return }
            unlocked = accepted
            message = nil
        } catch { message = "Unlock with Face ID, Touch ID, or your device passcode." }
    }
}

@MainActor enum ScenePrivacyCover {
    private static let tag = 26092601
    static func setVisible(_ visible: Bool) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                if !visible { window.viewWithTag(tag)?.removeFromSuperview(); continue }
                guard window.viewWithTag(tag) == nil else { continue }
                let cover = UIView(frame: window.bounds)
                cover.tag = tag
                cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                cover.backgroundColor = .systemBackground
                let label = UILabel(frame: cover.bounds)
                label.text = "Finance"
                label.textAlignment = .center
                label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                cover.addSubview(label)
                cover.accessibilityIdentifier = "privacy.background-cover"
                window.addSubview(cover)
            }
        }
    }
}
