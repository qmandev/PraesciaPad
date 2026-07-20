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

#### Implemented: UI workflow coverage

The generated no-assertion UI test has been replaced with four product workflow tests covering the welcome and safety framing, recoverable scan errors, acquisition facts, selected-region descriptions, visibility state, and measurement undo and clear controls. The launch screenshot test now also asserts that the import action exists.

A deterministic scan fixture and error state are available only in `DEBUG` builds through the `PRAESCIA_UI_TEST_MODE` launch environment key. Release builds contain neither the fixture nor its configuration entry point.

The complete UI test bundle compiles. The error-recovery workflow passed on the iPad simulator. Xcode repeatedly failed to launch runners for the other workflows before their test cases started, including with parallel execution disabled and on a second simulator. Those three tests therefore remain execution-unverified rather than failed assertions.

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
- UI workflow test bundle compilation: passed.
- Recoverable-error UI workflow: passed.
- Welcome, loaded-scan, and measurement UI workflows: execution blocked by simulator runner launch failures.
- Physical iPad interaction and resource profiling: not yet performed.

## Remaining Definition-of-Done Work

1. Profile loading, memory, rotation, selection, and measurement on supported iPad hardware.
2. Execute the remaining three UI workflows on a stable simulator or physical test device.
