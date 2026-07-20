# PraesciaPad Implementation Status

Audit date: July 20, 2026

## Scope

This status compares the current project with `praesicPadPrompt.md` and `REQUIREMENTS.md`. The repository does not contain files named `implementation.md` or `REQUIREMENT.md`; the two available documents are treated as the intended specification.

## Overall Status

PraesciaPad implements all six core product flows. A fresh audit found no unresolved high-priority code defect. The generic iOS build and the 17-test bundle compile cleanly; the prior 15 tests passed, while execution of the two new malformed-input regressions is blocked by the simulator runner. The sampled-mesh and memory findings are resolved, scene preparation no longer synchronously bakes meshes, and three of four UI workflows execute successfully. Physical-iPad profiling, simulator verification, and exhaustive corruption validation remain outstanding.

## Findings

### High

#### Resolved: near-half-turn qform normalization

`NIfTIParser` previously accepted quaternion vector components whose squared length was slightly greater than one, as can occur from floating-point rounding near a 180-degree rotation, but clamped the scalar component without normalizing the vector. That could introduce unintended scale into the affine and affect orientation, voxel size, and physical volume.

The parser now normalizes the quaternion vector for the NIfTI near-half-turn case and rejects values outside the accepted rounding tolerance. A regression test verifies the three physical axis lengths and affine-derived voxel volume.

Affected requirements: F1.4, F3.3, F4.4, and F4.5.

#### Resolved: command-line test execution

The installed iPad simulator initially failed to launch the test runner, reporting that it was waiting for workers to materialize followed by a CoreSimulator IPC server failure. After a clean simulator restart, the numerical suite executed successfully from `xcodebuild test`.

The Swift Testing suite now contains 17 cases covering affine determinant volume, world-space distance, `sform`, rotated `qform`, near-half-turn quaternion normalization, segmentation consistency, extreme numeric inputs, mesh orientation and proportions, sampled bounds, resource budgeting, invalid files, and asynchronous case lifecycle. The existing 15 cases have passed; the two new numeric-input cases compile but have not executed because of the simulator runner failure.

Affected requirements: N5.2 and the definition of done.

#### Resolved: stale asynchronous scan completion

`CaseStore` previously allowed multiple import tasks to run without cancellation or request identity. An older task could overwrite a newer scan, and a late completion could restore scan state after a case was closed.

Every open or close now invalidates the previous request generation and cancels the retained load task. Completion and error publication require the current generation, so even a loader that ignores cancellation cannot publish stale state. Cancellation propagates to the detached worker, with checkpoints during large parsing and segmentation loops. Regression tests cover both newer-import precedence and close-case invalidation.

Affected requirements: F1.1, F1.3, and N2.2.

#### Resolved in code: malformed numeric inputs cannot trap

The parser previously converted a finite but out-of-range NIfTI voxel offset directly from `Float` to `Int`, which could trap before producing a recoverable error. Segmentation also subtracted extreme finite `Float` intensities before widening them to `Double`; that subtraction could overflow and lead to a trapping histogram-bin conversion.

Voxel offsets are now bounded by the actual file size before conversion. Scaled intensities must fit the processing buffer's finite `Float` range, and histogram normalization widens operands before subtraction and validates the normalized value before converting it to a bin. Regression tests cover both formerly trapping inputs and compile successfully. Their simulator execution remains pending because Xcode could not materialize the test worker, including after a clean simulator reboot with parallel testing disabled.

Affected requirement: F1.3.

### Medium

#### Resolved: rendered orientation and physical proportions

The test target now exercises final generated mesh positions rather than only affine parsing. An asymmetric landmark fixture verifies that right, anterior, and superior RAS directions map to the intended RealityKit axes without reflection. A second fixture verifies exact physical mesh extents for anisotropic voxels.

Affected requirements: F4.4, F4.5, and N5.3.

#### Resolved: sampled mesh edge bounds

Sampled blocks now terminate at `-0.5 ... dimension - 0.5` on every voxel axis instead of extending a fixed half-stride beyond partial edge samples. This preserves the exact physical bounds and center when a dimension is not divisible by the display stride.

A stride-`2` regression fixture with non-divisible `40 x 39 x 38` dimensions and anisotropic `2 x 3 x 4 mm` voxels verifies exact RealityKit extents and centering.

Affected requirement: F4.4.

#### Resolved in code: enforceable memory budget

Parsing now enforces a conservative 512 MiB estimated working-set budget with 128 MiB reserved for runtime, mesh, collision, and RealityKit overhead. The estimate includes compressed and decoded source buffers, float intensities, and segmentation labels. Gzip expansion is checked before allocating its output buffer, and decoded NIfTI volume cost is checked before allocating intensities.

Tests verify that the supplied-scan scale is accepted and oversized decoded and compressed volumes are rejected. The 512 MiB limit is intentionally conservative; physical-device measurement is still required to calibrate it against supported iPad hardware.

Affected requirement: N4.2.

#### Hardware performance and memory remain unverified

The supplied scan is reduced to sampled surface geometry while full-resolution voxel counts remain in use for reported volumes. The UI discloses this reduction. Interactive frame rate, collision generation cost, loading responsiveness, and peak memory have not been measured on physical iPad hardware.

As a code-level improvement, the RealityKit scene now creates its two measurement markers once and updates only their positions and visibility. Dragging, zooming, undoing, and clearing measurements no longer destroy and recreate mesh entities during view updates. This removes known per-frame allocation work, but it does not replace hardware profiling.

RealityKit mesh resources now use the framework's nonisolated asynchronous initializer rather than synchronous main-actor generation. The anatomy view keeps a visible `Preparing 3D scene` state until meshes and collision shapes are ready. Collision generation remains a main-actor RealityKit API and must still be profiled on hardware.

An optimized, repeatable physical-device workflow now exists in `scripts/profile-ipad.sh` and `physicalProfiling.md`. It installs a Release build and captures Time Profiler, Allocations, Animation Hitches, and RealityKit traces across controlled loading and interaction scenarios. The protocol defines memory, frame-rate, hitch, responsiveness, and repeated-open/close gates without persisting scan data or committing trace artifacts.

Execution is currently blocked by device availability. On July 20, 2026, CoreDevice listed the registered 9th-generation test iPad as `unavailable`, so no physical measurements are claimed.

Affected requirements: F1.1, F4.1, N4.1, and N4.2.

### Low

#### Implemented: UI workflow coverage

The generated no-assertion UI test has been replaced with four product workflow tests covering the welcome and safety framing, recoverable scan errors, acquisition facts, selected-region descriptions, visibility state, and measurement undo and clear controls. The launch screenshot test now also asserts that the import action exists.

A deterministic scan fixture and error state are available only in `DEBUG` builds through the `PRAESCIA_UI_TEST_MODE` launch environment key. Release builds contain neither the fixture nor its configuration entry point.

The welcome, error-recovery, and loaded-scan workflows now pass on the iPad simulator. The welcome warning has a stable accessibility identifier without depending on SwiftUI's accessibility role.

The measurement run exposed that the top-level anatomy identifier propagated to all child controls, overwriting the identifiers for Measure, Undo, and Clear. The identifier now applies only to the RealityView surface, preserving each control's identity. A post-fix test build passed, but the simulator never launched its test runner; Xcode remained at `waiting for workers to materialize` until interrupted and then reported a dead simulator IPC server. The measurement workflow therefore remains execution-unverified after this fix, not an assertion failure.

#### Outstanding: exhaustive corruption validation

The parser validates the NIfTI magic prefix but not its required fourth null byte. Gzip header CRC bytes are skipped when present rather than verified. Payload and trailer validation still prevent garbage voxel output, but these technically corrupt headers are not rejected under a strict reading of F1.3.

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
- Swift test execution on the iPad (A16) simulator before the latest additions: 15 of 15 passed.
- Out-of-range voxel-offset and full finite-intensity-range regression tests: compiled; execution blocked while waiting for the simulator worker to materialize.
- Newer-import precedence and close-case invalidation tests: passed.
- Asymmetric RAS-to-RealityKit orientation fixture: passed without reflection.
- Anisotropic generated-mesh extent fixture: passed.
- Non-divisible sampled-mesh bounds and centering fixture: passed.
- Research-scale memory acceptance and oversized-volume rejection fixtures: passed.
- UI workflow test bundle compilation: passed.
- Welcome, recoverable-error, and loaded-scan UI workflows: passed.
- Measurement control accessibility defect: fixed; post-fix execution blocked by simulator runner launch failure.
- Physical iPad interaction and resource profiling: not yet performed.
- Physical profiling harness and acceptance protocol: implemented; device currently unavailable.

## Remaining Definition-of-Done Work

1. Connect and unlock a supported iPad, run `scripts/profile-ipad.sh`, record the results in `physicalProfiling.md`, and use them to validate or tune the 512 MiB budget.
2. Execute the two new malformed-numeric-input regressions and the post-fix measurement workflow on a stable simulator or physical test device.
3. Validate the complete NIfTI magic field and optional gzip header CRC.
