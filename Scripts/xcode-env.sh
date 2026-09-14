#!/bin/bash
# Selects a usable Xcode toolchain for the xcodebuild wrappers without
# changing the machine's global xcode-select setting.
#
# `xcode-select -p` on this machine may point at CommandLineTools, which has
# swift but no xcodebuild. DEVELOPER_DIR overrides that per process only.
#
# Override with: DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer
if ! xcodebuild -version >/dev/null 2>&1; then
    for candidate in "${DEVELOPER_DIR:-}" /Applications/Xcode*.app/Contents/Developer; do
        [ -n "$candidate" ] && [ -d "$candidate" ] || continue
        if DEVELOPER_DIR="$candidate" xcodebuild -version >/dev/null 2>&1; then
            export DEVELOPER_DIR="$candidate"
            break
        fi
    done
fi

if ! xcodebuild -version >/dev/null 2>&1; then
    echo "STATUS    FAIL — xcodebuild is unavailable."
    echo "          xcode-select -p is $(xcode-select -p 2>/dev/null)."
    echo "          Set DEVELOPER_DIR to an Xcode.app/Contents/Developer, or run"
    echo "          sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 127
fi

# The simulator or device the app suite runs on. Never hard-code a physical
# device UDID or a team id in a committed script.
APP_DESTINATION="${FINANCE_APP_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
export APP_DESTINATION
