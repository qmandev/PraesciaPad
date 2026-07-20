# PraesciaPad Physical iPad Profiling

This protocol verifies F1.1, F4.1, N4.1, and N4.2 on physical iPad hardware. Simulator results are not hardware evidence.

## Prerequisites

- A supported iPad running iPadOS 26.4 or later, connected and available to Xcode.
- Developer Mode enabled and the Mac trusted by the iPad.
- An Apple development account in Xcode with access to the project's configured signing team; the build permits automatic provisioning updates.
- The ignored `IXI648-Guys-1107-T1.nii.gz` sample available in the iPad Files app.
- The iPad disconnected from external displays and Low Power Mode disabled.
- At least 2 GB of free Mac storage for DerivedData and Instruments traces, plus enough iPad storage for the app.

Confirm that the device state is `available`:

```sh
xcrun devicectl list devices
```

## Capture

Run the profiling script with the exact device name or UDID shown by `devicectl`:

```sh
./scripts/profile-ipad.sh "Device Name"
```

The script builds the optimized Release configuration, installs it on the iPad, and records four traces under `/tmp`:

1. Time Profiler covers import, parsing, segmentation, scene creation, interaction, measurement, and case close.
2. Allocations covers two complete open/close cycles to expose peak memory and retained growth.
3. Animation Hitches covers sustained rotation, zoom, selection, visibility, undo, and clear interactions.
4. RealityKit Trace covers rendering and RealityKit-specific CPU/GPU work.

Do not include trace bundles in Git. Instruments traces contain process diagnostics and may include local filenames.

## Project Gates

Record observed values rather than rounding them into a pass. Apply these project-level gates consistently:

- Import must complete without watchdog termination, memory-pressure termination, crash, or corrupt output.
- The progress UI must remain visible while work exceeds one second, and buttons, scrolling, and scene interaction must not freeze.
- Peak physical memory footprint must remain below the 512 MiB processing budget.
- After closing the case, physical footprint must return to within 15% of the pre-import baseline before the second import.
- On a 60 Hz iPad, median interactive frame rate must be at least 55 fps during the scripted interaction run.
- No individual interaction hitch may reach 250 ms, and hitch time ratio must remain at or below 5 ms per second.
- Repeating open, interact, measure, and close must not show monotonically increasing retained allocations.

If a gate fails, keep the trace, record the failing interval, and identify the dominant stack or allocation category before changing the budget or geometry fidelity.

## Results

Record one row per physical device and app commit. Do not substitute simulator measurements.

| Field | Measured result |
|---|---|
| Date and commit | Not measured |
| iPad model | Not measured |
| iPadOS version | Not measured |
| Sample grid and datatype | Not measured |
| Import to acquisition facts | Not measured |
| Import to interactive scene | Not measured |
| Longest main-thread stall during loading | Not measured |
| Pre-import physical footprint | Not measured |
| Peak physical footprint | Not measured |
| Post-close physical footprint | Not measured |
| Second-cycle peak and post-close footprint | Not measured |
| Median interaction frame rate | Not measured |
| Hitch time ratio | Not measured |
| Longest interaction hitch | Not measured |
| RealityKit CPU/GPU bottleneck | Not measured |
| Rotation, selection, and measurement result | Not measured |
| Overall gate | Not measured |

## Current Availability

On July 20, 2026, `devicectl` listed Holly's iPad, a 9th-generation iPad, as `unavailable`. No physical measurements were recorded. The medium-priority finding remains open until this table contains a completed device run.
