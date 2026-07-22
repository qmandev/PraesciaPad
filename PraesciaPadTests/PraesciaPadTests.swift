import Foundation
import simd
import Testing
@testable import PraesciaPad

struct PraesciaPadTests {
    @Test @MainActor
    func newerImportCannotBeOverwrittenByStaleCompletion() async throws {
        let older = processedScan(named: "older")
        let newer = processedScan(named: "newer")
        let store = CaseStore { url in
            if url.lastPathComponent == "older.nii" {
                try? await Task.sleep(for: .milliseconds(160))
                return older
            }
            try await Task.sleep(for: .milliseconds(10))
            return newer
        }

        store.open(URL(fileURLWithPath: "/tmp/older.nii"))
        store.open(URL(fileURLWithPath: "/tmp/newer.nii"))
        try await Task.sleep(for: .milliseconds(240))

        #expect(store.scan?.metadata.dataType == "newer")
    }

    @Test @MainActor
    func closingCasePreventsLateLoadFromRestoringScan() async throws {
        let store = CaseStore { _ in
            try? await Task.sleep(for: .milliseconds(100))
            return processedScan(named: "late")
        }

        store.open(URL(fileURLWithPath: "/tmp/late.nii"))
        store.close()
        try await Task.sleep(for: .milliseconds(160))

        if case .empty = store.state {
            #expect(store.scan == nil)
        } else {
            Issue.record("A cancelled load restored case state after close.")
        }
    }

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

    @Test func patientFacingNarrativeUsesComputedBandWithoutClinicalNumbers() {
        let region = Region(
            id: 2,
            name: "Middle-intensity band",
            voxelCount: 42_000,
            volumeML: 987.6,
            color: SIMD3(0.94, 0.55, 0.20)
        )
        let description = PatientFacingNarrative.description(for: region)

        #expect(description == "This description is for the middle-intensity band. It contains scan voxels assigned to that intensity range. The bands group scan voxels by intensity only. They are not anatomical tissue labels and do not identify a condition or medical finding.")
        #expect(!description.contains("42"))
        #expect(!description.contains("987"))
        #expect(!description.contains("mL"))
    }

    @Test func displayCoordinatesRoundTripKnownRASPointForObliqueAffine() {
        let affine = simd_double4x4(rows: [
            SIMD4(0, -2, 0, 10),
            SIMD4(1, 0, 0, -4),
            SIMD4(0, 0, 3, 7),
            SIMD4(0, 0, 0, 1)
        ])
        let coordinateSpace = ScanCoordinateSpace(
            dimensions: SIMD3(5, 7, 9),
            affineMM: affine
        )
        let ras = PhysicalMath.worldPoint(voxel: SIMD3(4, 2, 7), affine: affine)
        let display = coordinateSpace.displayPoint(rasMM: ras)

        #expect(ras == SIMD3(6, 0, 28))
        #expect(coordinateSpace.centerRASMM == SIMD3(4, -2, 19))
        #expect(display == SIMD3(-2, 9, 2))
        #expect(coordinateSpace.rasPoint(displayMM: display) == ras)
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

    @Test func parserNormalizesNearHalfTurnQFormQuaternion() throws {
        var fixture = makeNIfTI(
            dimensions: SIMD3(2, 2, 2),
            affineRows: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]],
            values: Array(0..<8).map(Int16.init)
        )
        fixture.writeInt16(1, at: 252)
        fixture.writeInt16(0, at: 254)
        fixture.writeFloat(2, at: 80)
        fixture.writeFloat(3, at: 84)
        fixture.writeFloat(4, at: 88)
        fixture.writeFloat(1.000002, at: 256)

        let volume = try NIfTIParser.parse(fixture)
        let affine = volume.metadata.affineMM

        #expect(abs(simd_length(SIMD3(affine.columns.0.x, affine.columns.0.y, affine.columns.0.z)) - 2) < 1e-10)
        #expect(abs(simd_length(SIMD3(affine.columns.1.x, affine.columns.1.y, affine.columns.1.z)) - 3) < 1e-10)
        #expect(abs(simd_length(SIMD3(affine.columns.2.x, affine.columns.2.y, affine.columns.2.z)) - 4) < 1e-10)
        #expect(abs(volume.metadata.voxelVolumeMM3 - 24) < 1e-10)
    }

    @Test func parserRejectsVoxelOffsetOutsideAddressableFileData() {
        var fixture = makeNIfTI(
            dimensions: SIMD3(2, 2, 2),
            affineRows: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]],
            values: Array(0..<8).map(Int16.init)
        )
        fixture.writeFloat(.greatestFiniteMagnitude, at: 108)

        #expect(throws: ScanError.self) { try NIfTIParser.parse(fixture) }
    }

    @Test func segmentationHandlesFullFiniteFloatRangeWithoutTrapping() throws {
        let largest = Double(Float.greatestFiniteMagnitude)
        let intensities = (0...100).map { index in
            Float(-largest + 2 * largest * Double(index) / 100)
        }
        let metadata = ScanMetadata(
            dimensions: SIMD3(101, 1, 1),
            voxelSizeMM: SIMD3(repeating: 1),
            dataType: "32-bit floating point",
            affineMM: matrix_identity_double4x4,
            voxelVolumeMM3: 1
        )

        let result = try ScanPipeline.segment(ScanVolume(metadata: metadata, intensities: intensities))

        #expect(result.regions.count == 3)
        #expect(result.regions.allSatisfy { $0.voxelCount > 0 })
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

    @Test func meshCoordinatesUseAnteriorRASViewForAsymmetricLandmarks() throws {
        let dimensions = SIMD3(3, 3, 3)
        let metadata = ScanMetadata(
            dimensions: dimensions,
            voxelSizeMM: SIMD3(repeating: 1),
            dataType: "test",
            affineMM: matrix_identity_double4x4,
            voxelVolumeMM3: 1
        )
        var labels = [UInt8](repeating: 0, count: 27)
        labels[voxelIndex(SIMD3(2, 1, 1), dimensions: dimensions)] = 1 // Right
        labels[voxelIndex(SIMD3(1, 2, 1), dimensions: dimensions)] = 2 // Anterior
        labels[voxelIndex(SIMD3(1, 1, 2), dimensions: dimensions)] = 3 // Superior

        let result = ScanPipeline.buildMeshes(labels: labels, metadata: metadata)
        let right = try meshCentroid(result.meshes, id: 1)
        let anterior = try meshCentroid(result.meshes, id: 2)
        let superior = try meshCentroid(result.meshes, id: 3)

        #expect(result.stride == 1)
        #expect(simd_distance(right, SIMD3(-1, 0, 0)) < 1e-6)
        #expect(simd_distance(anterior, SIMD3(0, 0, 1)) < 1e-6)
        #expect(simd_distance(superior, SIMD3(0, 1, 0)) < 1e-6)
        #expect(simd_determinant(simd_float3x3(right, anterior, superior)) > 0)
    }

    @Test func negativeDeterminantAffineKeepsTriangleNormalsFacingOutward() throws {
        let dimensions = SIMD3(1, 1, 1)
        let affine = simd_double4x4(diagonal: SIMD4(-2, 3, 4, 1))
        let metadata = ScanMetadata(
            dimensions: dimensions,
            voxelSizeMM: SIMD3(2, 3, 4),
            dataType: "test",
            affineMM: affine,
            voxelVolumeMM3: 24
        )
        let result = ScanPipeline.buildMeshes(labels: [1], metadata: metadata)
        let mesh = try #require(result.meshes.first { $0.id == 1 })

        for offset in stride(from: 0, to: mesh.triangleIndices.count, by: 3) {
            let first = mesh.positionsMM[Int(mesh.triangleIndices[offset])]
            let second = mesh.positionsMM[Int(mesh.triangleIndices[offset + 1])]
            let third = mesh.positionsMM[Int(mesh.triangleIndices[offset + 2])]
            let normal = simd_cross(second - first, third - first)
            let triangleCenter = (first + second + third) / 3

            #expect(simd_dot(normal, triangleCenter) > 0)
        }
    }

    @Test func meshExtentsPreserveAnisotropicPhysicalProportions() throws {
        let dimensions = SIMD3(3, 4, 5)
        let affine = simd_double4x4(diagonal: SIMD4(2, 3, 4, 1))
        let metadata = ScanMetadata(
            dimensions: dimensions,
            voxelSizeMM: SIMD3(2, 3, 4),
            dataType: "test",
            affineMM: affine,
            voxelVolumeMM3: 24
        )
        let result = ScanPipeline.buildMeshes(
            labels: [UInt8](repeating: 1, count: dimensions.x * dimensions.y * dimensions.z),
            metadata: metadata
        )
        let mesh = try #require(result.meshes.first { $0.id == 1 })
        let bounds = try meshBounds(mesh.positionsMM)
        let extents = bounds.maximum - bounds.minimum

        #expect(result.stride == 1)
        #expect(simd_distance(extents, SIMD3(6, 20, 12)) < 1e-6)
    }

    @Test func sampledMeshClampsNonDivisibleDimensionsToPhysicalBounds() throws {
        let dimensions = SIMD3(40, 39, 38)
        let affine = simd_double4x4(diagonal: SIMD4(2, 3, 4, 1))
        let metadata = ScanMetadata(
            dimensions: dimensions,
            voxelSizeMM: SIMD3(2, 3, 4),
            dataType: "test",
            affineMM: affine,
            voxelVolumeMM3: 24
        )
        let result = ScanPipeline.buildMeshes(
            labels: [UInt8](repeating: 1, count: dimensions.x * dimensions.y * dimensions.z),
            metadata: metadata
        )
        let mesh = try #require(result.meshes.first { $0.id == 1 })
        let bounds = try meshBounds(mesh.positionsMM)

        #expect(result.stride == 2)
        #expect(simd_distance(bounds.maximum - bounds.minimum, SIMD3(80, 152, 117)) < 1e-6)
        #expect(simd_distance(bounds.maximum + bounds.minimum, .zero) < 1e-6)
    }

    @Test func memoryBudgetAllowsResearchScaleVolume() throws {
        try ScanResourceBudget.validateVolume(
            compressedSourceBytes: 8 * 1_024 * 1_024,
            decodedSourceBytes: 20 * 1_024 * 1_024,
            voxelCount: 9_830_400
        )
    }

    @Test func sourceFilePreflightEnforcesMaximumPossibleBudget() throws {
        try ScanResourceBudget.validateSourceFileSize(ScanResourceBudget.maximumSourceFileBytes)

        #expect(throws: ScanError.self) {
            try ScanResourceBudget.validateSourceFileSize(ScanResourceBudget.maximumSourceFileBytes + 1)
        }
    }

    @Test func memoryBudgetRejectsOversizedDecodedVolume() {
        #expect(throws: ScanError.self) {
            try ScanResourceBudget.validateVolume(
                compressedSourceBytes: 0,
                decodedSourceBytes: 300 * 1_024 * 1_024,
                voxelCount: 50_000_000
            )
        }
    }

    @Test func memoryBudgetRejectsOversizedGzipExpansionBeforeAllocation() {
        #expect(throws: ScanError.self) {
            try ScanResourceBudget.validateGzip(
                compressedBytes: 20 * 1_024 * 1_024,
                expandedBytes: 200 * 1_024 * 1_024
            )
        }
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

private func voxelIndex(_ voxel: SIMD3<Int>, dimensions: SIMD3<Int>) -> Int {
    voxel.x + dimensions.x * (voxel.y + dimensions.y * voxel.z)
}

private func processedScan(named name: String) -> ProcessedScan {
    ProcessedScan(
        metadata: ScanMetadata(
            dimensions: SIMD3(repeating: 1),
            voxelSizeMM: SIMD3(repeating: 1),
            dataType: name,
            affineMM: matrix_identity_double4x4,
            voxelVolumeMM3: 1
        ),
        regions: [],
        meshes: [],
        segmentedVolumeML: 0,
        displayStride: 1
    )
}

private func meshCentroid(_ meshes: [RegionMesh], id: UInt8) throws -> SIMD3<Float> {
    let mesh = try #require(meshes.first { $0.id == id })
    let positions = mesh.positionsMM
    try #require(!positions.isEmpty)
    return positions.reduce(.zero, +) / Float(positions.count)
}

private func meshBounds(_ positions: [SIMD3<Float>]) throws -> (minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
    let first = try #require(positions.first)
    return positions.dropFirst().reduce(into: (minimum: first, maximum: first)) { bounds, point in
        bounds.minimum = simd_min(bounds.minimum, point)
        bounds.maximum = simd_max(bounds.maximum, point)
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
