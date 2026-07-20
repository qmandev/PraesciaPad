import Foundation
import simd

enum ScanError: LocalizedError, Sendable {
    case invalidFile(String)
    case unsupported(String)
    case processing(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile(let detail): "This file is not a valid NIfTI scan. \(detail)"
        case .unsupported(let detail): "This scan is not supported. \(detail)"
        case .processing(let detail): "The scan could not be processed. \(detail)"
        }
    }
}

struct ScanMetadata: Sendable, Equatable {
    let dimensions: SIMD3<Int>
    let voxelSizeMM: SIMD3<Double>
    let dataType: String
    let affineMM: simd_double4x4
    let voxelVolumeMM3: Double

    var voxelCount: Int { dimensions.x * dimensions.y * dimensions.z }
}

struct ScanVolume: Sendable {
    let metadata: ScanMetadata
    let intensities: [Float]
}

struct Region: Identifiable, Sendable, Equatable {
    let id: UInt8
    let name: String
    let voxelCount: Int
    let volumeML: Double
    let color: SIMD3<Float>
}

struct RegionMesh: Identifiable, Sendable {
    let id: UInt8
    let positionsMM: [SIMD3<Float>]
    let triangleIndices: [UInt32]
}

struct ProcessedScan: Sendable {
    let metadata: ScanMetadata
    let regions: [Region]
    let meshes: [RegionMesh]
    let segmentedVolumeML: Double
    let displayStride: Int
}

enum PhysicalMath {
    static func voxelVolumeMM3(affine: simd_double4x4) throws -> Double {
        let linear = simd_double3x3(
            SIMD3(affine.columns.0.x, affine.columns.0.y, affine.columns.0.z),
            SIMD3(affine.columns.1.x, affine.columns.1.y, affine.columns.1.z),
            SIMD3(affine.columns.2.x, affine.columns.2.y, affine.columns.2.z)
        )
        let volume = abs(simd_determinant(linear))
        guard volume.isFinite, volume > 0 else {
            throw ScanError.invalidFile("Its spatial transform has zero or invalid volume.")
        }
        return volume
    }

    static func worldPoint(voxel: SIMD3<Double>, affine: simd_double4x4) -> SIMD3<Double> {
        let result = affine * SIMD4(voxel.x, voxel.y, voxel.z, 1)
        return SIMD3(result.x, result.y, result.z)
    }

    static func distanceMM(_ first: SIMD3<Double>, _ second: SIMD3<Double>) -> Double {
        simd_distance(first, second)
    }
}
