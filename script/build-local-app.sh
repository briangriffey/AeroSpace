#!/usr/bin/env bash
# Build AeroSpace.app and the aerospace CLI for this machine only (no docs, no man pages, no shell completion).
# Output goes to .local-release/. Unlike build-release.sh this doesn't need Ruby, asciidoctor or Rust.
#
# Usage: script/build-local-app.sh [--build-version <v>] [--codesign-identity <identity>]
#   --codesign-identity '-' (default) is an ad-hoc signature. macOS ties the Accessibility permission to the
#   signature, so with an ad-hoc one you have to grant it again after every rebuild. Use a self-signed
#   certificate (see dev-docs/development.md) to avoid that.
cd "$(dirname "$0")/.."
source ./script/setup.sh

build_version="0.21.3-staircase"
codesign_identity="-"
while test $# -gt 0; do
    case $1 in
        --build-version) build_version="$2"; shift 2;;
        --codesign-identity) codesign_identity="$2"; shift 2;;
        *) echo "Unknown option $1" > /dev/stderr; exit 1 ;;
    esac
done

./generate.sh --ignore-cmd-help --build-version "$build_version" --codesign-identity "$codesign_identity" --generate-git-hash
trap 'git checkout -- Sources/Common/versionGenerated.swift Sources/Common/gitHashGenerated.swift 2>/dev/null || true' EXIT

swift build -c release --product aerospace # CLI

rm -rf .local-release && mkdir .local-release

(
    cd xcode
    xcodebuild-pretty ../.local-release/xcodebuild.log build \
        -scheme AeroSpace \
        -destination "generic/platform=macOS" \
        -configuration Release \
        -derivedDataPath .xcode-build \
        CODE_SIGN_IDENTITY="$codesign_identity"
)

cp -r xcode/.xcode-build/Build/Products/Release/AeroSpace.app .local-release
cp "$(swift build -c release --show-bin-path)/aerospace" .local-release
codesign --force -s "$codesign_identity" .local-release/aerospace
codesign --force --deep -s "$codesign_identity" .local-release/AeroSpace.app

codesign -v .local-release/AeroSpace.app
echo "Built: $PWD/.local-release/AeroSpace.app and $PWD/.local-release/aerospace"
