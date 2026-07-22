import Foundation
import simd

enum ScanPipeline {
    static func process(_ data: Data) throws -> ProcessedScan {
        let volume = try NIfTIParser.parse(data)
        let segmentation = try segment(volume)
        let meshes = buildMeshes(labels: segmentation.labels, metadata: volume.metadata)
        let totalVolume = segmentation.regions.reduce(0) { $0 + $1.volumeML }
        return ProcessedScan(
            metadata: volume.metadata,
            regions: segmentation.regions,
            meshes: meshes.meshes,
            segmentedVolumeML: totalVolume,
            displayStride: meshes.stride
        )
    }

    static func segment(_ volume: ScanVolume) throws -> (labels: [UInt8], regions: [Region]) {
        guard let minimum = volume.intensities.min(), let maximum = volume.intensities.max(),
              minimum.isFinite, maximum.isFinite, maximum > minimum else {
            throw ScanError.processing("The intensity range is empty or constant.")
        }

        let binCount = 4_096
        let minimumValue = Double(minimum)
        let range = Double(maximum) - minimumValue
        guard range.isFinite, range > 0 else {
            throw ScanError.processing("The intensity range is invalid.")
        }
        var histogram = [Int](repeating: 0, count: binCount)
        for (index, value) in volume.intensities.enumerated() {
            if index.isMultiple(of: 262_144) { try Task.checkCancellation() }
            let normalized = (Double(value) - minimumValue) / range
            guard normalized.isFinite else {
                throw ScanError.processing("The voxel data contains invalid intensity values.")
            }
            let bin = Int(min(1, max(0, normalized)) * Double(binCount - 1))
            histogram[bin] += 1
        }

        // Otsu separates the dominant scanner background from the head, then the retained
        // distribution is split into equal-count bands. This is not anatomical inference.
        let backgroundBin = otsuThreshold(histogram: histogram)
        let foregroundCount = histogram.dropFirst(backgroundBin + 1).reduce(0, +)
        guard foregroundCount >= 3 else {
            throw ScanError.processing("Too few non-background voxels remain for three intensity bands.")
        }
        let lowBoundary = quantileBin(histogram: histogram, startingAt: backgroundBin + 1, target: foregroundCount / 3)
        let highBoundary = quantileBin(histogram: histogram, startingAt: backgroundBin + 1, target: foregroundCount * 2 / 3)

        var labels = [UInt8](repeating: 0, count: volume.intensities.count)
        var counts = [Int](repeating: 0, count: 4)
        for (index, value) in volume.intensities.enumerated() {
            if index.isMultiple(of: 262_144) { try Task.checkCancellation() }
            let normalized = (Double(value) - minimumValue) / range
            guard normalized.isFinite else {
                throw ScanError.processing("The voxel data contains invalid intensity values.")
            }
            let bin = Int(min(1, max(0, normalized)) * Double(binCount - 1))
            let label: UInt8
            if bin <= backgroundBin {
                label = 0
            } else if bin <= lowBoundary {
                label = 1
            } else if bin <= highBoundary {
                label = 2
            } else {
                label = 3
            }
            labels[index] = label
            counts[Int(label)] += 1
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
                volumeML: Double(counts[Int(id)]) * volume.metadata.voxelVolumeMM3 / 1_000,
                color: color
            )
        }
        guard regions.allSatisfy({ $0.voxelCount > 0 }) else {
            throw ScanError.processing("The intensity distribution cannot form three non-empty bands.")
        }
        return (labels, regions)
    }

    private static func quantileBin(histogram: [Int], startingAt start: Int, target: Int) -> Int {
        var cumulative = 0
        for bin in start..<histogram.count {
            cumulative += histogram[bin]
            if cumulative >= max(1, target) { return bin }
        }
        return histogram.count - 1
    }

    private static func otsuThreshold(histogram: [Int]) -> Int {
        let total = histogram.reduce(0, +)
        let weightedTotal = histogram.enumerated().reduce(0.0) { partial, entry in
            partial + Double(entry.offset * entry.element)
        }
        var backgroundWeight = 0
        var backgroundSum = 0.0
        var bestVariance = -Double.infinity
        var bestThreshold = 0

        for threshold in 0..<(histogram.count - 1) {
            backgroundWeight += histogram[threshold]
            backgroundSum += Double(threshold * histogram[threshold])
            let foregroundWeight = total - backgroundWeight
            guard backgroundWeight > 0, foregroundWeight > 0 else { continue }
            let backgroundMean = backgroundSum / Double(backgroundWeight)
            let foregroundMean = (weightedTotal - backgroundSum) / Double(foregroundWeight)
            let difference = backgroundMean - foregroundMean
            let variance = Double(backgroundWeight) * Double(foregroundWeight) * difference * difference
            if variance > bestVariance {
                bestVariance = variance
                bestThreshold = threshold
            }
        }
        return bestThreshold
    }

    static func buildMeshes(labels: [UInt8], metadata: ScanMetadata) -> (meshes: [RegionMesh], stride: Int) {
        let dimensions = metadata.dimensions
        let stride = max(1, Int(ceil(Double(max(dimensions.x, max(dimensions.y, dimensions.z))) / 36.0)))
        let coordinateSpace = metadata.coordinateSpace
        let reversesHandedness = affineReversesHandedness(metadata.affineMM)
        var positions = [[SIMD3<Float>]](repeating: [], count: 4)
        var indices = [[UInt32]](repeating: [], count: 4)

        func labelAt(_ x: Int, _ y: Int, _ z: Int) -> UInt8 {
            guard x >= 0, y >= 0, z >= 0, x < dimensions.x, y < dimensions.y, z < dimensions.z else { return 0 }
            return labels[x + dimensions.x * (y + dimensions.y * z)]
        }

        for z in Swift.stride(from: 0, to: dimensions.z, by: stride) {
            for y in Swift.stride(from: 0, to: dimensions.y, by: stride) {
                for x in Swift.stride(from: 0, to: dimensions.x, by: stride) {
                    let label = labelAt(x, y, z)
                    guard label > 0 else { continue }
                    let boundary = labelAt(x - stride, y, z) != label
                        || labelAt(x + stride, y, z) != label
                        || labelAt(x, y - stride, z) != label
                        || labelAt(x, y + stride, z) != label
                        || labelAt(x, y, z - stride) != label
                        || labelAt(x, y, z + stride) != label
                    guard boundary else { continue }
                    let minimum = sampledBlockMinimum(
                        voxel: SIMD3(x, y, z),
                        stride: stride
                    )
                    let maximum = sampledBlockMaximum(
                        voxel: SIMD3(x, y, z),
                        dimensions: dimensions,
                        stride: stride
                    )
                    appendVoxelBlock(
                        minimum: minimum,
                        maximum: maximum,
                        affine: metadata.affineMM,
                        coordinateSpace: coordinateSpace,
                        reversesHandedness: reversesHandedness,
                        positions: &positions[Int(label)],
                        indices: &indices[Int(label)]
                    )
                }
            }
        }

        let meshes = (1...3).map {
            RegionMesh(id: UInt8($0), positionsMM: positions[$0], triangleIndices: indices[$0])
        }
        return (meshes, stride)
    }

    private static func sampledBlockMinimum(voxel: SIMD3<Int>, stride: Int) -> SIMD3<Double> {
        SIMD3(
            voxel.x == 0 ? -0.5 : Double(voxel.x) - Double(stride) / 2,
            voxel.y == 0 ? -0.5 : Double(voxel.y) - Double(stride) / 2,
            voxel.z == 0 ? -0.5 : Double(voxel.z) - Double(stride) / 2
        )
    }

    private static func sampledBlockMaximum(
        voxel: SIMD3<Int>,
        dimensions: SIMD3<Int>,
        stride: Int
    ) -> SIMD3<Double> {
        SIMD3(
            voxel.x + stride >= dimensions.x ? Double(dimensions.x) - 0.5 : Double(voxel.x) + Double(stride) / 2,
            voxel.y + stride >= dimensions.y ? Double(dimensions.y) - 0.5 : Double(voxel.y) + Double(stride) / 2,
            voxel.z + stride >= dimensions.z ? Double(dimensions.z) - 0.5 : Double(voxel.z) + Double(stride) / 2
        )
    }

    private static func appendVoxelBlock(
        minimum: SIMD3<Double>,
        maximum: SIMD3<Double>,
        affine: simd_double4x4,
        coordinateSpace: ScanCoordinateSpace,
        reversesHandedness: Bool,
        positions: inout [SIMD3<Float>],
        indices: inout [UInt32]
    ) {
        let corners: [SIMD3<Double>] = [
            SIMD3(minimum.x, minimum.y, minimum.z), SIMD3(maximum.x, minimum.y, minimum.z),
            SIMD3(maximum.x, maximum.y, minimum.z), SIMD3(minimum.x, maximum.y, minimum.z),
            SIMD3(minimum.x, minimum.y, maximum.z), SIMD3(maximum.x, minimum.y, maximum.z),
            SIMD3(maximum.x, maximum.y, maximum.z), SIMD3(minimum.x, maximum.y, maximum.z)
        ]
        let base = UInt32(positions.count)
        positions.append(contentsOf: corners.map { corner in
            let ras = PhysicalMath.worldPoint(voxel: corner, affine: affine)
            return SIMD3<Float>(coordinateSpace.displayPoint(rasMM: ras))
        })
        let cubeIndices: [UInt32] = [
            0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7,
            0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2,
            0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5
        ]
        for offset in stride(from: 0, to: cubeIndices.count, by: 3) {
            indices.append(base + cubeIndices[offset])
            if reversesHandedness {
                indices.append(base + cubeIndices[offset + 2])
                indices.append(base + cubeIndices[offset + 1])
            } else {
                indices.append(base + cubeIndices[offset + 1])
                indices.append(base + cubeIndices[offset + 2])
            }
        }
    }

    private static func affineReversesHandedness(_ affine: simd_double4x4) -> Bool {
        let linear = simd_double3x3(
            SIMD3(affine.columns.0.x, affine.columns.0.y, affine.columns.0.z),
            SIMD3(affine.columns.1.x, affine.columns.1.y, affine.columns.1.z),
            SIMD3(affine.columns.2.x, affine.columns.2.y, affine.columns.2.z)
        )
        return simd_determinant(linear) < 0
    }
}
