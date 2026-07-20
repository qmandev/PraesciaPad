import Foundation
import Observation
import simd

@MainActor
@Observable
final class CaseStore {
    enum State {
        case empty
        case loading(String)
        case loaded(ProcessedScan)
        case failed(String)
    }

    var state: State = .empty
    var selectedRegionID: UInt8?
    var visibleRegionIDs: Set<UInt8> = [1, 2, 3]
    var measurementPointsMM: [SIMD3<Double>] = []

    var scan: ProcessedScan? {
        guard case .loaded(let scan) = state else { return nil }
        return scan
    }

    func open(_ url: URL) {
        state = .loading("Reading and validating scan…")
        selectedRegionID = nil
        measurementPointsMM.removeAll(keepingCapacity: false)
        visibleRegionIDs = [1, 2, 3]

        Task {
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    return try ScanPipeline.process(data)
                }.value
                state = .loaded(result)
                selectedRegionID = result.regions.first?.id
            } catch {
                state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func close() {
        state = .empty
        selectedRegionID = nil
        visibleRegionIDs.removeAll(keepingCapacity: false)
        measurementPointsMM.removeAll(keepingCapacity: false)
    }

    func toggleVisibility(_ id: UInt8) {
        if visibleRegionIDs.contains(id) { visibleRegionIDs.remove(id) } else { visibleRegionIDs.insert(id) }
    }

    func addMeasurementPoint(_ point: SIMD3<Double>) {
        if measurementPointsMM.count == 2 { measurementPointsMM.removeAll(keepingCapacity: true) }
        measurementPointsMM.append(point)
    }

    func undoMeasurementPoint() { if !measurementPointsMM.isEmpty { measurementPointsMM.removeLast() } }
    func clearMeasurement() { measurementPointsMM.removeAll(keepingCapacity: true) }

    var distanceMM: Double? {
        guard measurementPointsMM.count == 2 else { return nil }
        return PhysicalMath.distanceMM(measurementPointsMM[0], measurementPointsMM[1])
    }
}
