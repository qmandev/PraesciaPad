import Foundation
import simd
import Testing
@testable import PraesciaPad

struct PraesciaPadTests {
    @Test func determinantGivesVoxelVolumeForRotatedAnisotropicAffine() throws {
        let angle = Double.pi / 5
        let rotation = simd_double3x3(rows: [
            SIMD3(cos(angle), -sin(angle), 0),
            SIMD3(sin(angle), cos(angle), 0),
            SIMD3(0, 0, 1)
        ])
        let linear = rotation * simd_double3x3(diagonal: SIMD3(0.7, 1.3, 2.5))
        let affine = simd_double4x4(
            SIMD4(linear.columns.0, 0), SIMD4(linear.columns.1, 0),
            SIMD4(linear.columns.2, 0), SIMD4(11, -9, 4, 1)
        )

        #expect(abs(try PhysicalMath.voxelVolumeMM3(affine: affine) - 2.275) < 1e-12)
    }

    @Test func worldDistanceUsesAffineMillimetresRatherThanVoxelCount() {
        let affine = simd_double4x4(diagonal: SIMD4(2, 3, 4, 1))
        let first = PhysicalMath.worldPoint(voxel: SIMD3(0, 0, 0), affine: affine)
        let second = PhysicalMath.worldPoint(voxel: SIMD3(1, 2, 2), affine: affine)

        #expect(abs(PhysicalMath.distanceMM(first, second) - sqrt(104)) < 1e-12)
    }

    @Test func parserReadsSFormUnitsScalingAndVoxelValues() throws {
        let affineRows: [[Float]] = [
            [0, -2, 0, 10],
            [1, 0, 0, -4],
            [0, 0, 3, 7]
        ]
        let fixture = makeNIfTI(
            dimensions: SIMD3(2, 2, 2),
            affineRows: affineRows,
            values: [0, 1, 2, 3, 4, 5, 6, 7],
            slope: 2,
            intercept: -1
        )

        let volume = try NIfTIParser.parse(fixture)
        #expect(volume.metadata.dimensions == SIMD3(2, 2, 2))
        #expect(abs(volume.metadata.voxelSizeMM.x - 1) < 1e-12)
        #expect(abs(volume.metadata.voxelSizeMM.y - 2) < 1e-12)
        #expect(abs(volume.metadata.voxelSizeMM.z - 3) < 1e-12)
        #expect(abs(volume.metadata.voxelVolumeMM3 - 6) < 1e-12)
        #expect(volume.intensities == [-1, 1, 3, 5, 7, 9, 11, 13])
    }

    @Test func parserBuildsRotatedQFormWithNegativeSliceDirection() throws {
        var fixture = makeNIfTI(
            dimensions: SIMD3(2, 2, 2),
            affineRows: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]],
            values: Array(0..<8).map(Int16.init)
        )
        fixture.writeInt16(1, at: 252)
        fixture.writeInt16(0, at: 254)
        fixture.writeFloat(-1, at: 76)
        fixture.writeFloat(2, at: 80)
        fixture.writeFloat(3, at: 84)
        fixture.writeFloat(4, at: 88)
        fixture.writeFloat(Float(sin(Double.pi / 4)), at: 264)
        fixture.writeFloat(10, at: 268)
        fixture.writeFloat(20, at: 272)
        fixture.writeFloat(30, at: 276)

        let volume = try NIfTIParser.parse(fixture)
        let origin = PhysicalMath.worldPoint(voxel: .zero, affine: volume.metadata.affineMM)
        let xStep = PhysicalMath.worldPoint(voxel: SIMD3(1, 0, 0), affine: volume.metadata.affineMM) - origin

        #expect(abs(volume.metadata.voxelVolumeMM3 - 24) < 1e-5)
        #expect(simd_distance(xStep, SIMD3(0, 2, 0)) < 1e-5)
        #expect(abs(simd_determinant(simd_double3x3(
            SIMD3(volume.metadata.affineMM.columns.0.x, volume.metadata.affineMM.columns.0.y, volume.metadata.affineMM.columns.0.z),
            SIMD3(volume.metadata.affineMM.columns.1.x, volume.metadata.affineMM.columns.1.y, volume.metadata.affineMM.columns.1.z),
            SIMD3(volume.metadata.affineMM.columns.2.x, volume.metadata.affineMM.columns.2.y, volume.metadata.affineMM.columns.2.z)
        )) + 24) < 1e-4)
    }

    @Test func segmentationVolumesUseAllVoxelsAndSumExactly() throws {
        let affine = simd_double4x4(
            SIMD4(0, 2, 0, 0), SIMD4(-3, 0, 0, 0),
            SIMD4(0, 0, 4, 0), SIMD4(0, 0, 0, 1)
        )
        let metadata = ScanMetadata(
            dimensions: SIMD3(4, 4, 4),
            voxelSizeMM: SIMD3(2, 3, 4),
            dataType: "test",
            affineMM: affine,
            voxelVolumeMM3: 24
        )
        let volume = ScanVolume(metadata: metadata, intensities: (0..<64).map(Float.init))
        let result = try ScanPipeline.segment(volume)
        let foregroundCount = result.regions.reduce(0) { $0 + $1.voxelCount }
        let totalML = result.regions.reduce(0) { $0 + $1.volumeML }

        #expect(result.regions.count == 3)
        #expect(result.regions.allSatisfy { $0.voxelCount > 0 })
        #expect(abs(totalML - Double(foregroundCount) * 24 / 1_000) < 1e-12)
        #expect(result.labels.count == 64)
    }

    @Test func corruptAndAmbiguousFilesFailClearly() {
        #expect(throws: ScanError.self) { try NIfTIParser.parse(Data(repeating: 0, count: 40)) }

        var missingTransform = makeNIfTI(
            dimensions: SIMD3(2, 2, 2),
            affineRows: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]],
            values: Array(0..<8).map(Int16.init)
        )
        missingTransform.writeInt16(0, at: 254)
        #expect(throws: ScanError.self) { try NIfTIParser.parse(missingTransform) }
    }
}

private func makeNIfTI(
    dimensions: SIMD3<Int>,
    affineRows: [[Float]],
    values: [Int16],
    slope: Float = 1,
    intercept: Float = 0
) -> Data {
    var data = Data(repeating: 0, count: 352 + values.count * 2)
    data.writeInt32(348, at: 0)
    data.writeInt16(3, at: 40)
    data.writeInt16(Int16(dimensions.x), at: 42)
    data.writeInt16(Int16(dimensions.y), at: 44)
    data.writeInt16(Int16(dimensions.z), at: 46)
    data.writeInt16(1, at: 48)
    data.writeInt16(4, at: 70)
    data.writeInt16(16, at: 72)
    data.writeFloat(1, at: 76)
    data.writeFloat(1, at: 80)
    data.writeFloat(1, at: 84)
    data.writeFloat(1, at: 88)
    data.writeFloat(352, at: 108)
    data.writeFloat(slope, at: 112)
    data.writeFloat(intercept, at: 116)
    data[123] = 2
    data.writeInt16(1, at: 254)
    for row in 0..<3 {
        for column in 0..<4 { data.writeFloat(affineRows[row][column], at: 280 + row * 16 + column * 4) }
    }
    data.replaceSubrange(344..<348, with: [0x6e, 0x2b, 0x31, 0])
    for (index, value) in values.enumerated() { data.writeInt16(value, at: 352 + index * 2) }
    return data
}

private extension Data {
    mutating func writeInt16(_ value: Int16, at offset: Int) {
        writeBytes(value.littleEndian, at: offset)
    }

    mutating func writeInt32(_ value: Int32, at offset: Int) {
        writeBytes(value.littleEndian, at: offset)
    }

    mutating func writeFloat(_ value: Float, at offset: Int) {
        writeBytes(value.bitPattern.littleEndian, at: offset)
    }

    mutating func writeBytes<T>(_ value: T, at offset: Int) {
        var copy = value
        Swift.withUnsafeBytes(of: &copy) { bytes in replaceSubrange(offset..<(offset + bytes.count), with: bytes) }
    }
}
