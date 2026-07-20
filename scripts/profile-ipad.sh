#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <physical-iPad-name-or-UDID> [output-directory]" >&2
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
        --device "$DEVICE" \
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
