# PraesciaPad Implementation Status

Audit date: July 20, 2026

## Scope

This status compares the current project with `praesicPadPrompt.md` and `REQUIREMENTS.md`. The repository does not contain files named `implementation.md` or `REQUIREMENT.md`; the two available documents are treated as the intended specification.

## Overall Status

PraesciaPad implements all six core product flows. Both high-priority findings and the testable medium-priority geometry finding are resolved. The generic iOS build and all nine numerical and geometry tests pass from the command line, and the supplied research scan processes successfully through the numerical core. Physical-iPad performance and memory verification remain outstanding acceptance checks.

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

#### Resolved: rendered orientation and physical proportions

The test target now exercises final generated mesh positions rather than only affine parsing. An asymmetric landmark fixture verifies that right, anterior, and superior RAS directions map to the intended RealityKit axes without reflection. A second fixture verifies exact physical mesh extents for anisotropic voxels.

Affected requirements: F4.4, F4.5, and N5.3.

#### Hardware performance and memory remain unverified

The supplied scan is reduced to sampled surface geometry while full-resolution voxel counts remain in use for reported volumes. The UI discloses this reduction. Interactive frame rate, collision generation cost, loading responsiveness, and peak memory have not been measured on physical iPad hardware.

As a code-level improvement, the RealityKit scene now creates its two measurement markers once and updates only their positions and visibility. Dragging, zooming, undoing, and clearing measurements no longer destroy and recreate mesh entities during view updates. This removes known per-frame allocation work, but it does not replace hardware profiling.

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
- Swift test execution on the iPad (A16) simulator: nine of nine passed.
- Asymmetric RAS-to-RealityKit orientation fixture: passed without reflection.
- Anisotropic generated-mesh extent fixture: passed.
- Physical iPad interaction and resource profiling: not yet performed.

## Remaining Definition-of-Done Work

1. Profile loading, memory, rotation, selection, and measurement on supported iPad hardware.
