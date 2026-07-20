#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <physical-iPad-name-or-CoreDevice-identifier> [output-directory]" >&2
    exit 64
fi

DEVICE="$1"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIRECTORY="${2:-/tmp/PraesciaPadProfile-${TIMESTAMP}}"
SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
DERIVED_DATA="${OUTPUT_DIRECTORY}/DerivedData"
APP_PATH="${DERIVED_DATA}/Build/Products/Release-iphoneos/PraesciaPad.app"

mkdir -p "$OUTPUT_DIRECTORY"

DEVICE_LINE="$(xcrun devicectl list devices | grep -F "$DEVICE" | head -n 1 || true)"
if [[ -z "$DEVICE_LINE" || "$DEVICE_LINE" != *" available "* ]]; then
    echo "The requested physical device is not available to Xcode: $DEVICE" >&2
    echo "Connect and unlock it, trust this Mac, enable Developer Mode, then retry." >&2
    exit 69
fi

DEVICE_DETAILS="$(xcrun devicectl device info details --device "$DEVICE")"
PROFILE_DEVICE="$(printf '%s\n' "$DEVICE_DETAILS" | awk -F': ' '/udid:/{print $2; exit}')"
if [[ -z "$PROFILE_DEVICE" ]]; then
    echo "Could not resolve the device UDID for Instruments: $DEVICE" >&2
    exit 69
fi

DEVICE_OS="$(printf '%s\n' "$DEVICE_DETAILS" | awk -F': ' '/osVersionNumber:/{print $2; exit}')"
SDK_OS="$(xcrun --sdk iphoneos --show-sdk-version)"
if [[ -z "$DEVICE_OS" || -z "$SDK_OS" ]]; then
    echo "Could not compare the iPadOS version with the installed iPhoneOS SDK." >&2
    exit 69
fi

DEVICE_MAJOR="${DEVICE_OS%%.*}"
DEVICE_REMAINDER="${DEVICE_OS#*.}"
DEVICE_MINOR="${DEVICE_REMAINDER%%.*}"
SDK_MAJOR="${SDK_OS%%.*}"
SDK_REMAINDER="${SDK_OS#*.}"
SDK_MINOR="${SDK_REMAINDER%%.*}"
if (( DEVICE_MAJOR > SDK_MAJOR || (DEVICE_MAJOR == SDK_MAJOR && DEVICE_MINOR > SDK_MINOR) )); then
    echo "The installed iPhoneOS ${SDK_OS} SDK does not support this iPadOS ${DEVICE_OS} device." >&2
    echo "Update Xcode to a release that supports iPadOS ${DEVICE_MAJOR}.${DEVICE_MINOR}, then retry." >&2
    exit 69
fi

XCTRACE_DEVICES="$(xcrun xctrace list devices)"
ONLINE_XCTRACE_DEVICES="$(printf '%s\n' "$XCTRACE_DEVICES" | awk '
    /^== Devices ==$/ { listing = 1; next }
    /^== / { listing = 0 }
    listing { print }
')"
if ! printf '%s\n' "$ONLINE_XCTRACE_DEVICES" | grep -Fq "($PROFILE_DEVICE)"; then
    echo "Instruments does not see the iPad online: $DEVICE" >&2
    echo "Connect it by USB, unlock it, and keep the screen awake before retrying." >&2
    exit 69
fi

if [[ -f "${PROJECT_DIRECTORY}/IXI648-Guys-1107-T1.nii.gz" ]]; then
    echo "Before recording, place IXI648-Guys-1107-T1.nii.gz in the iPad Files app."
fi

echo "Building the optimized app for $DEVICE..."
xcodebuild -quiet \
    -project "${PROJECT_DIRECTORY}/PraesciaPad.xcodeproj" \
    -scheme PraesciaPad \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    build

echo "Installing and launching PraesciaPad..."
xcrun devicectl device install app --device "$DEVICE" "$APP_PATH"
xcrun devicectl device process launch \
    --device "$DEVICE" \
    --terminate-existing \
    com.armstrongmobile.PraesciaPad

record_trace() {
    local template="$1"
    local filename="$2"
    local duration="$3"
    local instructions="$4"

    echo
    echo "$instructions"
    read -r -p "Press Return when the iPad is ready to record ${template}: "
    xcrun xctrace record \
        --template "$template" \
        --device "$PROFILE_DEVICE" \
        --attach PraesciaPad \
        --time-limit "$duration" \
        --output "${OUTPUT_DIRECTORY}/${filename}.trace"
}

record_trace \
    "Time Profiler" \
    "01-loading-time-profiler" \
    "2m" \
    "Close any open case. During recording, import the sample, wait for the scene, select each band, measure two points, then close the case."

record_trace \
    "Allocations" \
    "02-loading-allocations" \
    "3m" \
    "Close any open case. During recording, import the sample, wait for the scene, close it, then repeat once to expose retained-memory growth."

record_trace \
    "Animation Hitches" \
    "03-interaction-hitches" \
    "90s" \
    "Load the sample and wait for Preparing 3D scene to disappear before continuing. During recording, continuously rotate and zoom, toggle every band, select each band, and perform measurement undo and clear."

record_trace \
    "RealityKit Trace" \
    "04-realitykit" \
    "90s" \
    "Keep the sample loaded. During recording, repeat rotation, zoom, selection, visibility, and measurement interactions."

echo
echo "Profiling complete. Trace files are in: $OUTPUT_DIRECTORY"
echo "Review and record the results using physicalProfiling.md."
