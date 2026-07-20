import Foundation
import simd

enum NIfTIParser {
    static func parse(_ source: Data) throws -> ScanVolume {
        let data = try GzipDecoder.decodeIfNeeded(source)
        guard data.count >= 352 else { throw ScanError.invalidFile("The header is truncated.") }

        let littleHeader = try DataReader(data: data, endian: .little).int32(at: 0)
        let endian: Endian
        if littleHeader == 348 {
            endian = .little
        } else if littleHeader.byteSwapped == 348 {
            endian = .big
        } else {
            throw ScanError.invalidFile("The NIfTI header size is not 348 bytes.")
        }
        let reader = DataReader(data: data, endian: endian)

        let magic = String(bytes: data[344..<348].prefix(3), encoding: .ascii)
        guard magic == "n+1" else {
            throw ScanError.unsupported("Only single-file NIfTI-1 .nii volumes are accepted.")
        }

        let dimensionCount = Int(try reader.int16(at: 40))
        guard dimensionCount >= 3, dimensionCount <= 7 else {
            throw ScanError.invalidFile("Its dimension count is invalid.")
        }
        let dimensions = SIMD3(
            Int(try reader.int16(at: 42)),
            Int(try reader.int16(at: 44)),
            Int(try reader.int16(at: 46))
        )
        guard dimensions.x > 0, dimensions.y > 0, dimensions.z > 0 else {
            throw ScanError.invalidFile("Its voxel dimensions must be positive.")
        }
        if dimensionCount > 3 {
            for axis in 4...dimensionCount where try reader.int16(at: 40 + axis * 2) > 1 {
                throw ScanError.unsupported("Only a single 3D volume is supported; this file has multiple frames.")
            }
        }
        let (voxelCount, overflow) = dimensions.x.multipliedReportingOverflow(by: dimensions.y)
        let (totalVoxels, secondOverflow) = voxelCount.multipliedReportingOverflow(by: dimensions.z)
        guard !overflow, !secondOverflow, totalVoxels <= 300_000_000 else {
            throw ScanError.unsupported("Its voxel grid exceeds the 300-million-voxel safety limit.")
        }

        let dataTypeCode = Int(try reader.int16(at: 70))
        let dataType = try NIfTIDataType(code: dataTypeCode)
        guard Int(try reader.int16(at: 72)) == dataType.byteCount * 8 else {
            throw ScanError.invalidFile("Its datatype and bit depth disagree.")
        }
        let offsetFloat = try reader.float32(at: 108)
        guard offsetFloat.isFinite, offsetFloat >= 352, offsetFloat.rounded(.down) == offsetFloat else {
            throw ScanError.invalidFile("Its voxel-data offset is invalid.")
        }
        let dataOffset = Int(offsetFloat)
        let (payloadSize, payloadOverflow) = totalVoxels.multipliedReportingOverflow(by: dataType.byteCount)
        guard !payloadOverflow, dataOffset <= data.count, payloadSize <= data.count - dataOffset else {
            throw ScanError.invalidFile("The voxel payload is truncated.")
        }

        let unitScale = try spatialUnitScale(code: data[123] & 0x07)
        let affine = try spatialAffine(reader: reader, unitScale: unitScale)
        let voxelVolume = try PhysicalMath.voxelVolumeMM3(affine: affine)
        let voxelSizes = SIMD3(
            simd_length(SIMD3(affine.columns.0.x, affine.columns.0.y, affine.columns.0.z)),
            simd_length(SIMD3(affine.columns.1.x, affine.columns.1.y, affine.columns.1.z)),
            simd_length(SIMD3(affine.columns.2.x, affine.columns.2.y, affine.columns.2.z))
        )

        var slope = Double(try reader.float32(at: 112))
        let intercept = Double(try reader.float32(at: 116))
        if slope == 0 { slope = 1 }
        guard slope.isFinite, intercept.isFinite else {
            throw ScanError.invalidFile("Its intensity scaling values are invalid.")
        }

        var intensities = [Float]()
        intensities.reserveCapacity(totalVoxels)
        for index in 0..<totalVoxels {
            let raw = try dataType.value(reader: reader, at: dataOffset + index * dataType.byteCount)
            let scaled = raw * slope + intercept
            guard scaled.isFinite else { throw ScanError.invalidFile("Its voxel data contains non-finite values.") }
            intensities.append(Float(scaled))
        }

        let metadata = ScanMetadata(
            dimensions: dimensions,
            voxelSizeMM: voxelSizes,
            dataType: dataType.displayName,
            affineMM: affine,
            voxelVolumeMM3: voxelVolume
        )
        return ScanVolume(metadata: metadata, intensities: intensities)
    }

    private static func spatialUnitScale(code: UInt8) throws -> Double {
        switch code {
        case 1: 1_000
        case 2: 1
        case 3: 0.001
        default: throw ScanError.invalidFile("It does not declare metre, millimetre, or micrometre spatial units.")
        }
    }

    private static func spatialAffine(reader: DataReader, unitScale: Double) throws -> simd_double4x4 {
        let sformCode = try reader.int16(at: 254)
        let qformCode = try reader.int16(at: 252)
        var affine: simd_double4x4
        if sformCode > 0 {
            let x = try (0..<4).map { try Double(reader.float32(at: 280 + $0 * 4)) }
            let y = try (0..<4).map { try Double(reader.float32(at: 296 + $0 * 4)) }
            let z = try (0..<4).map { try Double(reader.float32(at: 312 + $0 * 4)) }
            affine = simd_double4x4(rows: [
                SIMD4(x[0], x[1], x[2], x[3]),
                SIMD4(y[0], y[1], y[2], y[3]),
                SIMD4(z[0], z[1], z[2], z[3]),
                SIMD4(0, 0, 0, 1)
            ])
        } else if qformCode > 0 {
            affine = try quaternionAffine(reader: reader)
        } else {
            throw ScanError.invalidFile("It has neither a qform nor an sform spatial transform, so orientation is ambiguous.")
        }
        for column in 0..<4 {
            affine[column].x *= unitScale
            affine[column].y *= unitScale
            affine[column].z *= unitScale
        }
        guard affine.columns.0.allFinite, affine.columns.1.allFinite,
              affine.columns.2.allFinite, affine.columns.3.allFinite else {
            throw ScanError.invalidFile("Its spatial transform contains invalid values.")
        }
        return affine
    }

    private static func quaternionAffine(reader: DataReader) throws -> simd_double4x4 {
        var b = Double(try reader.float32(at: 256))
        var c = Double(try reader.float32(at: 260))
        var d = Double(try reader.float32(at: 264))
        let vectorSquared = b * b + c * c + d * d
        guard vectorSquared.isFinite else { throw ScanError.invalidFile("Its qform quaternion is invalid.") }
        let aSquared = 1 - vectorSquared
        if aSquared < -1e-5 { throw ScanError.invalidFile("Its qform quaternion is invalid.") }
        let a: Double
        if aSquared < 1e-7 {
            // NIfTI permits rounding around a 180-degree rotation; normalize the vector
            // components so that rounding cannot introduce scale into the affine.
            guard vectorSquared > 0 else { throw ScanError.invalidFile("Its qform quaternion is invalid.") }
            let inverseLength = 1 / sqrt(vectorSquared)
            b *= inverseLength
            c *= inverseLength
            d *= inverseLength
            a = 0
        } else {
            a = sqrt(aSquared)
        }
        let dx = abs(Double(try reader.float32(at: 80)))
        let dy = abs(Double(try reader.float32(at: 84)))
        let dz = abs(Double(try reader.float32(at: 88)))
        guard dx > 0, dy > 0, dz > 0 else { throw ScanError.invalidFile("Its voxel spacing is invalid.") }
        let qfac = try reader.float32(at: 76) < 0 ? -1.0 : 1.0

        let rotation = simd_double3x3(rows: [
            SIMD3(a * a + b * b - c * c - d * d, 2 * (b * c - a * d), 2 * (b * d + a * c)),
            SIMD3(2 * (b * c + a * d), a * a + c * c - b * b - d * d, 2 * (c * d - a * b)),
            SIMD3(2 * (b * d - a * c), 2 * (c * d + a * b), a * a + d * d - c * c - b * b)
        ])
        let linear = rotation * simd_double3x3(diagonal: SIMD3(dx, dy, dz * qfac))
        return simd_double4x4(
            SIMD4(linear.columns.0, 0),
            SIMD4(linear.columns.1, 0),
            SIMD4(linear.columns.2, 0),
            SIMD4(
                Double(try reader.float32(at: 268)),
                Double(try reader.float32(at: 272)),
                Double(try reader.float32(at: 276)),
                1
            )
        )
    }
}

private enum Endian { case little, big }

private struct DataReader {
    let data: Data
    let endian: Endian

    func int16(at offset: Int) throws -> Int16 { Int16(bitPattern: try uint16(at: offset)) }
    func int32(at offset: Int) throws -> Int32 { Int32(bitPattern: try uint32(at: offset)) }
    func int64(at offset: Int) throws -> Int64 { Int64(bitPattern: try uint64(at: offset)) }
    func float32(at offset: Int) throws -> Float { Float(bitPattern: try uint32(at: offset)) }
    func float64(at offset: Int) throws -> Double { Double(bitPattern: try uint64(at: offset)) }

    func uint16(at offset: Int) throws -> UInt16 {
        let bytes = try checkedBytes(at: offset, count: 2)
        let start = bytes.startIndex
        let value = UInt16(bytes[start]) | (UInt16(bytes[start + 1]) << 8)
        return endian == .little ? value : value.byteSwapped
    }

    func uint32(at offset: Int) throws -> UInt32 {
        let bytes = try checkedBytes(at: offset, count: 4)
        let start = bytes.startIndex
        let value = UInt32(bytes[start]) | (UInt32(bytes[start + 1]) << 8)
            | (UInt32(bytes[start + 2]) << 16) | (UInt32(bytes[start + 3]) << 24)
        return endian == .little ? value : value.byteSwapped
    }

    func uint64(at offset: Int) throws -> UInt64 {
        let bytes = try checkedBytes(at: offset, count: 8)
        var value: UInt64 = 0
        for (shift, byte) in bytes.enumerated() { value |= UInt64(byte) << UInt64(shift * 8) }
        return endian == .little ? value : value.byteSwapped
    }

    private func checkedBytes(at offset: Int, count: Int) throws -> Data.SubSequence {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
            throw ScanError.invalidFile("A header field is truncated.")
        }
        return data[offset..<(offset + count)]
    }
}

private enum NIfTIDataType {
    case uint8, int8, int16, uint16, int32, uint32, int64, uint64, float32, float64

    init(code: Int) throws {
        switch code {
        case 2: self = .uint8
        case 4: self = .int16
        case 8: self = .int32
        case 16: self = .float32
        case 64: self = .float64
        case 256: self = .int8
        case 512: self = .uint16
        case 768: self = .uint32
        case 1024: self = .int64
        case 1280: self = .uint64
        default: throw ScanError.unsupported("NIfTI datatype code \(code) is not implemented.")
        }
    }

    var byteCount: Int {
        switch self {
        case .uint8, .int8: 1
        case .int16, .uint16: 2
        case .int32, .uint32, .float32: 4
        case .int64, .uint64, .float64: 8
        }
    }

    var displayName: String {
        switch self {
        case .uint8: "8-bit unsigned integer"
        case .int8: "8-bit signed integer"
        case .int16: "16-bit signed integer"
        case .uint16: "16-bit unsigned integer"
        case .int32: "32-bit signed integer"
        case .uint32: "32-bit unsigned integer"
        case .int64: "64-bit signed integer"
        case .uint64: "64-bit unsigned integer"
        case .float32: "32-bit floating point"
        case .float64: "64-bit floating point"
        }
    }

    func value(reader: DataReader, at offset: Int) throws -> Double {
        switch self {
        case .uint8: Double(reader.data[offset])
        case .int8: Double(Int8(bitPattern: reader.data[offset]))
        case .int16: Double(try reader.int16(at: offset))
        case .uint16: Double(try reader.uint16(at: offset))
        case .int32: Double(try reader.int32(at: offset))
        case .uint32: Double(try reader.uint32(at: offset))
        case .int64: Double(try reader.int64(at: offset))
        case .uint64: Double(try reader.uint64(at: offset))
        case .float32: Double(try reader.float32(at: offset))
        case .float64: try reader.float64(at: offset)
        }
    }
}

private extension SIMD4 where Scalar == Double {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
}
