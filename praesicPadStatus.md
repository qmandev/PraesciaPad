# PraesciaPad Implementation Status

Audit date: July 19, 2026

## Scope

This status compares the current project with `praesicPadPrompt.md` and `REQUIREMENTS.md`. The repository does not contain files named `implementation.md` or `REQUIREMENT.md`; the two available documents are treated as the intended specification.

## Overall Status

PraesciaPad implements all six core product flows, and both high-priority audit findings are resolved. The generic iOS build and all seven numerical tests pass from the command line, and the supplied research scan processes successfully through the numerical core. Direct rendered-orientation tests and physical-iPad performance verification remain outstanding acceptance checks.

## Findings

### High

#### Resolved: near-half-turn qform normalization

`NIfTIParser` previously accepted quaternion vector components whose squared length was slightly greater than one, as can occur from floating-point rounding near a 180-degree rotation, but clamped the scalar component without normalizing the vector. That could introduce unintended scale into the affine and affect orientation, voxel size, and physical volume.

The parser now normalizes the quaternion vector for the NIfTI near-half-turn case and rejects values outside the accepted rounding tolerance. A regression test verifies the three physical axis lengths and affine-derived voxel volume.

Affected requirements: F1.4, F3.3, F4.4, and F4.5.

#### Resolved: command-line test execution

The installed iPad simulator initially failed to launch the test runner, reporting that it was waiting for workers to materialize followed by a CoreSimulator IPC server failure. After a clean simulator restart, the numerical suite executed successfully from `xcodebuild test`.

All seven Swift Testing cases pass, including affine determinant volume, world-space distance, `sform`, rotated `qform`, near-half-turn quaternion normalization, segmentation volume consistency, and invalid-file handling.

Affected requirements: N5.2 and the definition of done.

### Medium

#### Rendered orientation and proportions lack direct tests

The parser tests cover affine construction, anisotropic spacing, rotations, negative slice direction, determinant volume, and world-space distance. They do not directly assert the final RAS-to-RealityKit coordinate conversion or generated mesh coordinates. Consequently, F4.4 and F4.5 are implemented but not independently proven by automated geometry tests.

#### Hardware performance and memory remain unverified

The supplied scan is reduced to sampled surface geometry while full-resolution voxel counts remain in use for reported volumes. The UI discloses this reduction. Interactive frame rate, collision generation cost, loading responsiveness, and peak memory have not been measured on physical iPad hardware.

Affected requirements: F1.1, F4.1, N4.1, and N4.2.

### Low

#### UI tests do not exercise product workflows

The UI test target contains generated launch and launch-performance tests but no assertions for file import, error recovery, region visibility, selection, or measurement. These tests are not explicitly required, but their absence leaves the main interaction paths dependent on manual verification.

## Implemented Requirements

- User-selected `.nii` and `.nii.gz` import with background processing, loading UI, and recoverable errors.
- NIfTI-1 datatype, intensity scaling, spatial-unit, `sform`, and `qform` parsing.
- Deterministic three-band segmentation with an in-product explanation of its limitations.
- Per-region and total volumes in millilitres derived from the affine determinant.
- RealityKit rendering with rotation, zoom, visibility controls, selection, and reset.
- Two-point straight-line measurement in millimetres with anchored markers, undo, clear, and a validation caveat.
- Deterministic, quantitatively grounded selected-region descriptions with a visible source.
- Visible research-prototype and non-diagnostic framing.
- No network calls, third-party dependencies, logging, analytics, user-default storage, or persistent case data.

## Verification Record

- Generic iOS device build with Swift 6 strict concurrency: passed.
- Supplied `IXI648-Guys-1107-T1.nii.gz` core processing: passed.
- Sample acquisition result: `256 x 256 x 150` voxels at approximately `0.9375 x 0.9375 x 1.200004 mm`.
- Sample segmentation: three deterministic non-empty intensity bands.
- Swift test bundle compilation: passed.
- Swift test execution on the iPad (A16) simulator: seven of seven passed.
- Physical iPad interaction and resource profiling: not yet performed.

## Remaining Definition-of-Done Work

1. Add direct tests for final mesh proportions and anatomical coordinate conversion.
2. Validate orientation using a known asymmetric fixture or orientation landmark.
3. Profile loading, memory, rotation, selection, and measurement on supported iPad hardware.
