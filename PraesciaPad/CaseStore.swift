import Foundation
import Observation
import simd

@MainActor
@Observable
final class CaseStore {
    typealias ScanLoader = @Sendable (URL) async throws -> ProcessedScan

    enum State {
        case empty
        case loading(String)
        case loaded(ProcessedScan)
        case failed(String)
    }

    var state: State = .empty
    var selectedRegionID: UInt8?
    var visibleRegionIDs: Set<UInt8> = [1, 2, 3]
    var measurementPointsRASMM: [SIMD3<Double>] = []

    @ObservationIgnored private let scanLoader: ScanLoader
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var requestGeneration: UInt64 = 0

    init(scanLoader: ScanLoader? = nil) {
        self.scanLoader = scanLoader ?? { url in try await Self.loadScan(from: url) }
    }

    var scan: ProcessedScan? {
        guard case .loaded(let scan) = state else { return nil }
        return scan
    }

    func open(_ url: URL) {
        let generation = invalidatePendingLoad()
        state = .loading("Reading and validating scan…")
        selectedRegionID = nil
        measurementPointsRASMM.removeAll(keepingCapacity: false)
        visibleRegionIDs = [1, 2, 3]

        let loader = scanLoader
        loadTask = Task { [weak self] in
            do {
                let result = try await loader(url)
                try Task.checkCancellation()
                guard let self, self.requestGeneration == generation else { return }
                self.state = .loaded(result)
                self.selectedRegionID = result.regions.first?.id
                self.loadTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.requestGeneration == generation else { return }
                self.state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                self.loadTask = nil
            }
        }
    }

    func close() {
        invalidatePendingLoad()
        state = .empty
        selectedRegionID = nil
        visibleRegionIDs.removeAll(keepingCapacity: false)
        measurementPointsRASMM.removeAll(keepingCapacity: false)
    }

    func toggleVisibility(_ id: UInt8) {
        if visibleRegionIDs.contains(id) { visibleRegionIDs.remove(id) } else { visibleRegionIDs.insert(id) }
    }

    func addMeasurementPoint(rasMM point: SIMD3<Double>) {
        if measurementPointsRASMM.count == 2 { measurementPointsRASMM.removeAll(keepingCapacity: true) }
        measurementPointsRASMM.append(point)
    }

    func undoMeasurementPoint() { if !measurementPointsRASMM.isEmpty { measurementPointsRASMM.removeLast() } }
    func clearMeasurement() { measurementPointsRASMM.removeAll(keepingCapacity: true) }

    var distanceMM: Double? {
        guard measurementPointsRASMM.count == 2 else { return nil }
        return PhysicalMath.distanceMM(measurementPointsRASMM[0], measurementPointsRASMM[1])
    }

    @discardableResult
    private func invalidatePendingLoad() -> UInt64 {
        requestGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        return requestGeneration
    }

    nonisolated private static func loadScan(from url: URL) async throws -> ProcessedScan {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard resourceValues.isRegularFile != false else {
                throw ScanError.invalidFile("The selected item is not a regular file.")
            }
            guard let fileSize = resourceValues.fileSize else {
                throw ScanError.invalidFile("Its file size could not be determined safely.")
            }
            try ScanResourceBudget.validateSourceFileSize(fileSize)
            try Task.checkCancellation()
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            try Task.checkCancellation()
            return try ScanPipeline.process(data)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
