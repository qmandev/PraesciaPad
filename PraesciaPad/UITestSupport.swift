#if DEBUG
import Foundation
import simd

extension CaseStore {
    func configureForUITestingIfNeeded() {
        guard case .empty = state,
              let mode = ProcessInfo.processInfo.environment["PRAESCIA_UI_TEST_MODE"] else { return }

        if mode == "error" {
            state = .failed("The selected UI test fixture is corrupt.")
            return
        }

        guard mode == "loaded" || mode == "measurement" else { return }
        let scan = UITestFixture.scan()
        state = .loaded(scan)
        selectedRegionID = scan.regions.first?.id
        visibleRegionIDs = Set(scan.regions.map(\.id))
        if mode == "measurement" {
            measurementPointsRASMM = [SIMD3(0, 0, 0), SIMD3(3, 4, 0)]
        }
    }
}

private enum UITestFixture {
    static func scan() -> ProcessedScan {
        let dimensions = SIMD3(9, 9, 9)
        let affine = simd_double4x4(diagonal: SIMD4(12, 12, 12, 1))
        let metadata = ScanMetadata(
            dimensions: dimensions,
            voxelSizeMM: SIMD3(repeating: 12),
            dataType: "16-bit signed integer",
            affineMM: affine,
            voxelVolumeMM3: 1_728
        )
        var labels = [UInt8](repeating: 0, count: dimensions.x * dimensions.y * dimensions.z)
        var counts = [Int](repeating: 0, count: 4)
        for z in 0..<dimensions.z {
            for y in 0..<dimensions.y {
                for x in 0..<dimensions.x {
                    let label = UInt8(x / 3 + 1)
                    labels[x + dimensions.x * (y + dimensions.y * z)] = label
                    counts[Int(label)] += 1
                }
            }
        }

        let definitions: [(UInt8, String, SIMD3<Float>)] = [
            (1, "Lower-intensity band", SIMD3(0.13, 0.67, 0.65)),
            (2, "Middle-intensity band", SIMD3(0.94, 0.55, 0.20)),
            (3, "Higher-intensity band", SIMD3(0.91, 0.27, 0.25))
        ]
        let regions = definitions.map { id, name, color in
            Region(
                id: id,
                name: name,
                voxelCount: counts[Int(id)],
                volumeML: Double(counts[Int(id)]) * metadata.voxelVolumeMM3 / 1_000,
                color: color
            )
        }
        let meshes = ScanPipeline.buildMeshes(labels: labels, metadata: metadata)
        return ProcessedScan(
            metadata: metadata,
            regions: regions,
            meshes: meshes.meshes,
            segmentedVolumeML: regions.reduce(0) { $0 + $1.volumeML },
            displayStride: meshes.stride
        )
    }
}
#endif
