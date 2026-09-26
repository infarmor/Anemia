#!/usr/bin/env bash
#
# Sourced by build-app.sh and test.sh: adapts the build to the standalone
# Command Line Tools (no Xcode). Exports SDKROOT and fills TOOLCHAIN_SWIFT_ARGS.
#
#  * CLT 27 ships the macOS 27 SDK, where SwiftUI's @State/@Entry became
#    macros backed by libSwiftUIMacros.dylib — a plugin Xcode bundles but the
#    CLT does not. Pin the newest pre-27 SDK, where they are plain property
#    wrappers.
#  * The CLT carries swift-testing (no XCTest), but its macro plugin lives in
#    a subdirectory the Swift Build engine doesn't search on its own.
#
TOOLCHAIN_SWIFT_ARGS=()
CLT=/Library/Developer/CommandLineTools
if [[ "$(xcode-select -p 2>/dev/null)" == "$CLT" ]]; then
    if [[ ! -e "$CLT/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
        FALLBACK_SDK="$(ls "$CLT/SDKs/" 2>/dev/null | grep -E '^MacOSX2[0-6]\.[0-9]+\.sdk$' | sort -V | tail -1 || true)"
        if [[ -n "$FALLBACK_SDK" ]]; then
            export SDKROOT="$CLT/SDKs/$FALLBACK_SDK"
            echo "→ CLT lacks the SwiftUI macro plugin; building against $FALLBACK_SDK"
        else
            echo "⚠ CLT lacks libSwiftUIMacros.dylib and no pre-27 SDK found — the app target may fail to build" >&2
        fi
    fi
    if [[ -d "$CLT/usr/lib/swift/host/plugins/testing" ]]; then
        TOOLCHAIN_SWIFT_ARGS+=(-Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing")
    fi
fi
