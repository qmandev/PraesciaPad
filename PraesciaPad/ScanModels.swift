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

enum ScanResourceBudget {
    static let maximumWorkingSetBytes = 512 * 1_024 * 1_024
    private static let runtimeHeadroomBytes = 128 * 1_024 * 1_024
    static let maximumSourceFileBytes = maximumWorkingSetBytes - runtimeHeadroomBytes

    static func validateSourceFileSize(_ sourceBytes: Int) throws {
        guard sourceBytes >= 0 else {
            throw ScanError.invalidFile("Its file size is invalid.")
        }
        guard sourceBytes <= maximumSourceFileBytes else {
            let sourceMiB = Int(ceil(Double(sourceBytes) / Double(1_024 * 1_024)))
            let limitMiB = maximumSourceFileBytes / (1_024 * 1_024)
            throw ScanError.unsupported(
                "Its source file is \(sourceMiB) MiB, above the \(limitMiB) MiB preflight limit."
            )
        }
    }

    static func validateVolume(
        compressedSourceBytes: Int,
        decodedSourceBytes: Int,
        voxelCount: Int
    ) throws {
        try validate(
            components: [
                compressedSourceBytes,
                decodedSourceBytes,
                try multiplied(voxelCount, by: MemoryLayout<Float>.stride),
                try multiplied(voxelCount, by: MemoryLayout<UInt8>.stride),
                runtimeHeadroomBytes
            ],
            context: "The decoded volume"
        )
    }

    static func validateGzip(compressedBytes: Int, expandedBytes: Int) throws {
        // Decompression may briefly retain the compressed input, output buffer, and Data copy.
        try validate(
            components: [
                compressedBytes,
                try multiplied(expandedBytes, by: 2),
                runtimeHeadroomBytes
            ],
            context: "The compressed volume"
        )
    }

    private static func multiplied(_ value: Int, by multiplier: Int) throws -> Int {
        let (result, overflow) = value.multipliedReportingOverflow(by: multiplier)
        guard value >= 0, multiplier >= 0, !overflow else {
            throw ScanError.unsupported("Its estimated memory requirement is too large.")
        }
        return result
    }

    private static func validate(components: [Int], context: String) throws {
        var total = 0
        for component in components {
            let (result, overflow) = total.addingReportingOverflow(component)
            guard component >= 0, !overflow else {
                throw ScanError.unsupported("Its estimated memory requirement is too large.")
            }
            total = result
        }
        guard total <= maximumWorkingSetBytes else {
            let estimatedMiB = Int(ceil(Double(total) / Double(1_024 * 1_024)))
            let limitMiB = maximumWorkingSetBytes / (1_024 * 1_024)
            throw ScanError.unsupported(
                "\(context) needs an estimated \(estimatedMiB) MiB, above the \(limitMiB) MiB on-device processing budget."
            )
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

    var coordinateSpace: ScanCoordinateSpace {
        ScanCoordinateSpace(dimensions: dimensions, affineMM: affineMM)
    }
}

struct ScanCoordinateSpace: Sendable, Equatable {
    let centerRASMM: SIMD3<Double>

    init(dimensions: SIMD3<Int>, affineMM: simd_double4x4) {
        let maximum = SIMD3<Double>(
            Double(dimensions.x - 1),
            Double(dimensions.y - 1),
            Double(dimensions.z - 1)
        )
        centerRASMM = PhysicalMath.worldPoint(voxel: maximum / 2, affine: affineMM)
    }

    func displayPoint(rasMM: SIMD3<Double>) -> SIMD3<Double> {
        let centered = rasMM - centerRASMM
        // The reset view looks from anterior toward posterior: patient right appears on
        // screen-left, superior is up, and anterior points toward the RealityKit camera.
        return SIMD3(-centered.x, centered.z, centered.y)
    }

    func rasPoint(displayMM: SIMD3<Double>) -> SIMD3<Double> {
        centerRASMM + SIMD3(-displayMM.x, displayMM.z, displayMM.y)
    }
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
