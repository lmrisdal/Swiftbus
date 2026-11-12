#!/bin/bash
# Xcode build phase: publishes the .NET helper with Native AOT, copies it into
# Contents/Helpers and signs it so it runs inside the app's sandbox.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/share/dotnet:/usr/local/bin:$PATH"

if ! command -v dotnet >/dev/null; then
    echo "error: the .NET 10 SDK is required to build the messaging helper (https://dot.net)" >&2
    exit 1
fi

# Debug builds use the host architecture; Release builds are universal (arm64 + x86_64) via lipo.
case "$(uname -m)" in
    arm64) HOST_RID=osx-arm64 ;;
    *) HOST_RID=osx-x64 ;;
esac
if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
    RIDS="osx-arm64 osx-x64"
else
    RIDS="$HOST_RID"
fi

OUT="${DERIVED_FILE_DIR:?}/swiftbus-helper-publish"
DEST="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Helpers"
rm -rf "$OUT"
mkdir -p "$DEST"

# Xcode exports many variables that MSBuild reads as properties (and renamed the output), so run clean.
# /usr/bin comes first so `clang` is the SDK-aware shim rather than the bare toolchain binary.
for RID in $RIDS; do
    env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/share/dotnet" \
        DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
        dotnet publish "${SRCROOT:?}/Helper/SwiftbusHelper/SwiftbusHelper.csproj" \
        -c Release -r "$RID" -o "$OUT/$RID" --nologo -v quiet -p:NuGetAudit=false -p:AssemblyName=swiftbus-helper
done

BINARIES=()
for RID in $RIDS; do BINARIES+=("$OUT/$RID/swiftbus-helper"); done
if [ "${#BINARIES[@]}" -gt 1 ]; then
    lipo -create "${BINARIES[@]}" -output "$DEST/swiftbus-helper"
else
    cp "${BINARIES[0]}" "$DEST/swiftbus-helper"
fi

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[ -z "$IDENTITY" ] && IDENTITY="-"
codesign --force --sign "$IDENTITY" --options runtime \
    --entitlements "$SRCROOT/Helper/helper.entitlements" "$DEST/swiftbus-helper"
