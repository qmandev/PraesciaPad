# PraesciaPad

PraesciaPad is an iPad research prototype for opening and exploring 3D brain MRI volumes stored as NIfTI files. It processes scans entirely on the device, displays deterministic intensity bands as an interactive RealityKit model, and provides affine-aware volume and straight-line distance measurements.

> PraesciaPad is not a medical device. It is intended for education, consent conversations, and research review only. Do not use it for diagnosis, treatment decisions, surgical planning, or intraoperative guidance.

## Features

- Imports single-file NIfTI-1 scans in `.nii` or gzip-compressed `.nii.gz` format.
- Reads little- and big-endian voxel data across common integer and floating-point datatypes.
- Uses the NIfTI `sform` or `qform` affine to preserve orientation and calculate physical dimensions in millimetres.
- Separates foreground voxels into three deterministic intensity bands using an Otsu cutoff and histogram splits.
- Calculates region volumes from the full-resolution voxel count and affine determinant.
- Generates sampled 3D meshes for responsive RealityKit rendering without changing reported volumes.
- Supports rotation, zoom, region selection, per-region visibility, and view reset.
- Measures straight-line distance between two selected surface points, with undo and clear controls.
- Keeps scan processing in memory and does not use network services, analytics, or persistent case storage.

## Requirements

- Xcode with the iOS 26.4 SDK or later
- iPad running iPadOS 26.4 or later, or a compatible iPad simulator
- Swift 6

The project uses only Apple frameworks, including SwiftUI, RealityKit, Uniform Type Identifiers, Compression, and Swift Testing. It has no third-party package dependencies.

## Getting Started

1. Open `PraesciaPad.xcodeproj` in Xcode.
2. Select the `PraesciaPad` scheme and an iPad destination.
3. Build and run the application.
4. Choose **Open NIfTI scan** and select a `.nii` or `.nii.gz` file from Files.
5. Drag to rotate, pinch to zoom, or tap a rendered band to select it.
6. Enable **Measure**, then tap two visible surface points to calculate their straight-line separation in millimetres.

All decompression, parsing, segmentation, geometry generation, and measurement occur locally. Closing a case removes the processed scan from the app's in-memory state.

## Supported Input

PraesciaPad currently accepts single-file, three-dimensional NIfTI-1 volumes with:

- A valid `n+1` header and voxel payload
- A valid `sform` or `qform` spatial transform
- Metre, millimetre, or micrometre spatial units
- Signed or unsigned 8-, 16-, 32-, or 64-bit integer voxels
- 32- or 64-bit floating-point voxels
- At most 300 million voxels and a gzip-expanded size no greater than 1 GB
- An estimated processing working set no greater than 512 MiB, including source buffers, intensities, labels, and runtime headroom

NIfTI-2, paired `.hdr`/`.img` files, multi-frame volumes, complex values, RGB data, and scans without an unambiguous spatial transform are not supported.

## Processing Model

The processing pipeline is deterministic:

1. Validate and optionally decompress the source file.
2. Parse voxel values, intensity scaling, spatial units, and the affine transform.
3. Use an Otsu histogram threshold to separate background from foreground.
4. Divide retained foreground voxels into low, middle, and high equal-count intensity ranges.
5. Calculate physical volume as `voxel count × abs(det(affine)) / 1000` mL.
6. Build affine-transformed surface meshes for RealityKit.

The intensity bands are not anatomical tissue labels, a brain extraction result, or a validated clinical segmentation. Their volumes may include non-brain foreground structures present in the scan.

## Build and Test

Build without code signing from the command line:

```sh
xcodebuild \
  -project PraesciaPad.xcodeproj \
  -scheme PraesciaPad \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

List available simulator destinations and run the test suite with an installed iPad simulator:

```sh
xcodebuild -project PraesciaPad.xcodeproj -scheme PraesciaPad -showdestinations

xcodebuild test \
  -project PraesciaPad.xcodeproj \
  -scheme PraesciaPad \
  -destination 'platform=iOS Simulator,name=iPad (A16)'
```

The tests cover rotated and anisotropic affine volume calculations, world-space distance, `sform` and `qform` parsing, intensity scaling, deterministic segmentation volume totals, and malformed-file errors.

Physical-device performance and memory are verified separately with Instruments. See `physicalProfiling.md` and run `./scripts/profile-ipad.sh "Device Name"` with a connected iPad; simulator measurements are not accepted as hardware evidence.

## Project Structure

- `ContentView.swift`: import workflow, scan facts, region controls, and safety disclosures
- `CaseStore.swift`: transient case state and background processing coordination
- `GzipDecoder.swift`: gzip header validation, decompression, and CRC verification
- `NIfTIParser.swift`: NIfTI-1 header, affine, datatype, and voxel parsing
- `ScanModels.swift`: scan models and affine-based physical calculations
- `ScanPipeline.swift`: segmentation, volume calculation, and mesh generation
- `AnatomyView.swift`: RealityKit rendering, interaction, selection, and measurement
- `PraesciaPadTests.swift`: numerical and parser tests

## Privacy and Safety

PraesciaPad does not upload scans, make network requests, persist case data, or log voxel contents. Source files are accessed through the system file importer and processed in memory. This privacy model does not replace an institutional security, privacy, or clinical validation review.
