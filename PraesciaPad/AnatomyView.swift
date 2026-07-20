import RealityKit
import SwiftUI
import UIKit

struct AnatomyView: View {
    let scan: ProcessedScan
    let store: CaseStore

    @State private var root = Entity()
    @State private var yaw: Float = 0
    @State private var pitch: Float = 0
    @State private var zoom: Float = 1
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1
    @State private var measuring = false
    @State private var sceneError: String?
    @State private var sceneIsLoading = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [Color(red: 0.025, green: 0.075, blue: 0.085), .praesciaInk], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            RealityView { content in
                do {
                    try await populateRoot()
                    content.add(root)

                    let camera = PerspectiveCamera()
                    camera.position = [0, 0, 0.48]
                    camera.look(at: .zero, from: camera.position, relativeTo: nil)
                    content.add(camera)

                    let light = DirectionalLight()
                    light.light.intensity = 1_800
                    light.look(at: .zero, from: [0.2, 0.3, 0.4], relativeTo: nil)
                    content.add(light)
                    sceneIsLoading = false
                } catch {
                    sceneIsLoading = false
                    sceneError = error.localizedDescription
                }
            } update: { _ in
                let displayedYaw = yaw + Float(dragTranslation.width) * 0.006
                let displayedPitch = pitch + Float(dragTranslation.height) * 0.006
                let displayedZoom = min(2.8, max(0.55, zoom * Float(magnification)))
                root.orientation = simd_quatf(angle: displayedYaw, axis: [0, 1, 0]) * simd_quatf(angle: displayedPitch, axis: [1, 0, 0])
                root.scale = SIMD3(repeating: 0.001 * displayedZoom)
                for region in scan.regions {
                    guard let entity = root.findEntity(named: "region-\(region.id)") as? ModelEntity else { continue }
                    entity.isEnabled = store.visibleRegionIDs.contains(region.id)
                    entity.model?.materials = [material(for: region, selected: store.selectedRegionID == region.id)]
                }
                updateMarkers()
            }
            .accessibilityIdentifier("anatomy-view")
            .gesture(rotationGesture)
            .simultaneousGesture(zoomGesture)
            .simultaneousGesture(tapGesture)

            controls
                .padding(22)

            if sceneIsLoading {
                ProgressView("Preparing 3D scene…")
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("scene-loading")
            }

            if let sceneError {
                Text(sceneError)
                    .font(.callout)
                    .padding(12)
                    .background(.red, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .trailing, spacing: 12) {
            HStack(spacing: 8) {
                Button(measuring ? "Measuring" : "Measure", systemImage: measuring ? "ruler.fill" : "ruler") {
                    measuring.toggle()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("measure-toggle")
                Button("Reset view", systemImage: "arrow.counterclockwise") {
                    yaw = 0; pitch = 0; zoom = 1
                }
                .buttonStyle(.bordered)
            }
            if measuring {
                VStack(alignment: .leading, spacing: 8) {
                    Text(measurementText)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .accessibilityIdentifier("measurement-value")
                    Text("Straight-line distance between two surface points. It is not a path over the surface or a validated clinical measurement.")
                        .font(.caption).foregroundStyle(.secondary).frame(width: 310, alignment: .leading)
                    HStack {
                        Button("Undo", systemImage: "arrow.uturn.backward") { store.undoMeasurementPoint() }
                            .disabled(store.measurementPointsMM.isEmpty)
                            .accessibilityIdentifier("measurement-undo")
                        Button("Clear", systemImage: "trash") { store.clearMeasurement() }
                            .disabled(store.measurementPointsMM.isEmpty)
                            .accessibilityIdentifier("measurement-clear")
                    }
                    .font(.caption)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            Text("Drag to rotate · Pinch to zoom · Tap to select")
                .font(.caption).foregroundStyle(.white.opacity(0.62))
        }
        .foregroundStyle(.white)
    }

    private var measurementText: String {
        if let distance = store.distanceMM { return String(format: "%.1f mm", distance) }
        return "Tap point \(store.measurementPointsMM.count + 1) of 2"
    }

    private var rotationGesture: some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in state = value.translation }
            .onEnded { value in
                yaw += Float(value.translation.width) * 0.006
                pitch += Float(value.translation.height) * 0.006
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($magnification) { value, state, _ in state = value.magnification }
            .onEnded { value in zoom = min(2.8, max(0.55, zoom * Float(value.magnification))) }
    }

    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                guard let regionID = regionID(for: value.entity) else { return }
                if measuring {
                    guard let hit = value.hitTest(point: value.location, in: .local).first else { return }
                    let localPoint = root.convert(position: hit.position, from: nil)
                    store.addMeasurementPoint(SIMD3(Double(localPoint.x), Double(localPoint.y), Double(localPoint.z)))
                } else {
                    store.selectedRegionID = regionID
                }
            }
    }

    private func populateRoot() async throws {
        root.name = "scan-root"
        for meshData in scan.meshes {
            guard let region = scan.regions.first(where: { $0.id == meshData.id }), !meshData.positionsMM.isEmpty else { continue }
            var descriptor = MeshDescriptor(name: "band-\(meshData.id)")
            descriptor.positions = MeshBuffers.Positions(meshData.positionsMM)
            descriptor.primitives = .triangles(meshData.triangleIndices)
            let mesh = try await MeshResource(from: [descriptor])
            let entity = ModelEntity(mesh: mesh, materials: [material(for: region, selected: false)])
            entity.name = "region-\(region.id)"
            entity.components.set(InputTargetComponent())
            entity.generateCollisionShapes(recursive: false)
            root.addChild(entity)
        }
        for index in 0..<2 {
            let marker = ModelEntity(
                mesh: .generateSphere(radius: 3.2),
                materials: [SimpleMaterial(color: .white, isMetallic: true)]
            )
            marker.name = "measure-marker-\(index)"
            marker.isEnabled = false
            root.addChild(marker)
        }
    }

    private func updateMarkers() {
        for index in 0..<2 {
            guard let marker = root.findEntity(named: "measure-marker-\(index)") else { continue }
            guard store.measurementPointsMM.indices.contains(index) else {
                marker.isEnabled = false
                continue
            }
            let point = store.measurementPointsMM[index]
            marker.position = SIMD3(Float(point.x), Float(point.y), Float(point.z))
            marker.isEnabled = true
        }
    }

    private func regionID(for entity: Entity) -> UInt8? {
        var candidate: Entity? = entity
        while let current = candidate, current !== root {
            if current.name.hasPrefix("region-"), let id = UInt8(current.name.dropFirst("region-".count)) { return id }
            candidate = current.parent
        }
        return nil
    }

    private func material(for region: Region, selected: Bool) -> SimpleMaterial {
        let color = UIColor(
            red: CGFloat(region.color.x),
            green: CGFloat(region.color.y),
            blue: CGFloat(region.color.z),
            alpha: selected ? 0.96 : 0.72
        )
        return SimpleMaterial(color: color, roughness: selected ? 0.32 : 0.68, isMetallic: false)
    }
}
