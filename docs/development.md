# Development setup

## Run locally

Open `FinanceApp.xcodeproj`, choose the FinanceApp scheme and an available
simulator, and run. The current verified local toolchain is Xcode 27.0 / Swift
6.4. The application targets iOS 18+; FinanceCore uses Swift 6 language mode.
No third-party package installation is required for the app.

Production first launch starts empty. Add accounts and transactions yourself,
or restore a validated FinanceDocument backup. Bank sync requires separate
configuration; see [data and sync](data-and-sync.md).

For physical installation, choose your own signing team in Xcode. Keep signing
credentials, device identifiers, and provisioning artifacts outside the repository.

## Verification commands

Run these from the repository root:

```sh
Scripts/context        # branch, toolchain, and test destination
Scripts/build-debug    # Debug build
Scripts/test-core      # independent FinanceCore suite
Scripts/test-app       # app, integration, and scheme UI tests
Scripts/check          # Core tests plus Debug build
Scripts/release-gate   # Release build and private fixture exclusion
python3 Scripts/repository-safety.py
```

The wrappers select an available Xcode installation without changing the global
`xcode-select` setting. Override the toolchain and destination when needed:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export FINANCE_APP_DESTINATION='platform=iOS Simulator,name=iPhone 17'
Scripts/check
```

Use a simulator that exists on your machine; an explicit simulator UUID can
replace its name. Full logs are retained at the path printed by each wrapper.
A test command that executes zero tests is not a successful verification.

Hosted CI separates app/integration checks from the optional full UI suite.
See [GitHub workflow](github-workflow.md) for required checks and the manual UI
workflow input. Avoid duplicate hosted UI runs for documentation-only changes.

## Synthetic previews

Debug builds support in-memory demonstration scenarios. In Xcode, add these
arguments under **Edit Scheme → Run → Arguments Passed On Launch**:

```text
-HCIPrototype -HCIPrototypeVariant full -startTab activity
```

The `full` scenario includes pending movements, review items, and planning risk.
Use `positive` for a funded Home example, `healthySync` for fresh bank status,
and `emptyReview` for the completed review state. Tabs include `home`, `activity`,
`plan`, and `insights`. Remove the arguments to return to normal persistence.
Preview arguments are Debug-only and are not an onboarding mechanism.

## Repository images

The [README](../README.md) uses the actual simulator UI captured from the
`positive` Home scenario and the `full` Activity and Plan scenarios. They are
independent examples, not successive states of the same financial document.
The screenshots are resized to 480 pixels wide, retain the full screen, and
contain only synthetic data. Source screenshots can be captured with:

```sh
xcrun simctl launch --terminate-running-process <simulator-uuid> \
  com.anasait.financeapp -AppleLanguages '(en-US)' -AppleLocale en_US \
  -AppleInterfaceStyle Light -HCIPrototype -HCIPrototypeVariant full -startTab activity
xcrun simctl io <simulator-uuid> screenshot /tmp/finance-demo-activity.png
```

Wait for the screen to settle before capture. Verify the demo launch arguments
and inspect the image before adding any replacement image to Git. Never use
physical-device captures or real-data previews for repository artwork.

`media/hero.svg` uses the app's existing forest and paper colors. It is a
repository header illustration, not an application icon. Keep documentation
assets in `docs/media/` so they are not added to the application bundle.
